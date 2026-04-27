<#
.SYNOPSIS
    Pre-migration data collector. Connects to vCenter via PowerCLI and gathers
    network configuration for each target VM.
.DESCRIPTION
    For each VM in the provided list:
      - Enumerates all network adapters in VMware adapter order (NIC1, NIC2)
      - Portgroup names are the subnet address (e.g. "192.168.1.0") — used to
        match each VMware vNIC to its corresponding IP config inside the guest
      - Pulls LAPS credential per server (VMs still have network at collection time)
      - Calls the user-supplied route collection function (stub below)
      - Outputs migration_servers.csv and migration_routes.csv

    Prerequisites:
      - VMware.PowerCLI module installed on the management server
      - RSAT-AD-PowerShell on management server (for LAPS — VMs have network here)
      - vCenter credentials with guest operations rights (for Invoke-VMScript)
      - Input: .\data\vm_input_list.txt — one FQDN per line

    Usage:
      .\1_Collect-VMwareNetworkConfig.ps1 -vCenter "vcenter.corp.contoso.com"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $vCenter,
    [string] $VMListPath    = '.\data\vm_input_list.txt',
    [string] $ServerCSVPath = '.\data\migration_servers.csv',
    [string] $RouteCSVPath  = '.\data\migration_routes.csv',
    [string] $LibPath       = '.\lib'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$LibPath\Get-LapsPassword.ps1"

# --- Connect to vCenter ---
Write-Host "Connecting to vCenter: $vCenter"
$vCenterCred = Get-Credential -Message 'vCenter credentials'
Connect-VIServer -Server $vCenter -Credential $vCenterCred -ErrorAction Stop | Out-Null

# Script block run inside the guest via Invoke-VMScript.
# Filters out APIPA addresses and takes the first static IP per adapter.
# Returns JSON: { "AdapterAlias": { IP, Prefix, Gateway, DNS[] }, ... }
$guestNetScript = @'
    $results = @{}
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($adapter in $adapters) {
        $alias = $adapter.InterfaceAlias
        $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } |
              Select-Object -First 1
        if (-not $ip) { continue }
        $gw  = Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        $dns = Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gwAddr = if ($gw) { $gw.NextHop } else { '' }
        $dnsArr = if ($dns -and $dns.ServerAddresses) { @($dns.ServerAddresses) } else { @() }
        $results[$alias] = @{
            IP      = $ip.IPAddress
            Prefix  = [int]$ip.PrefixLength
            Gateway = $gwAddr
            DNS     = $dnsArr
        }
    }
    $results | ConvertTo-Json -Depth 5 -Compress
'@

# Derives the network address (e.g. "192.168.1.0") from an IP and prefix length.
# Used to match a guest adapter against a portgroup name which is the subnet address.
# Pure byte arithmetic — avoids BitConverter endian issues and integer overflow.
function Get-NetworkAddress {
    param([string]$IP, [int]$Prefix)
    $ipBytes      = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
    $networkBytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $bitsInByte = [Math]::Max(0, [Math]::Min(8, $Prefix - ($i * 8)))
        if ($bitsInByte -ge 8) {
            $mask = 255
        } elseif ($bitsInByte -le 0) {
            $mask = 0
        } else {
            $mask = [int](256 - [Math]::Pow(2, 8 - $bitsInByte))
        }
        $networkBytes[$i] = [byte]($ipBytes[$i] -band $mask)
    }
    return ($networkBytes -join '.')
}

# --- Load VM list ---
if (-not (Test-Path $VMListPath)) { throw "VM input list not found: $VMListPath" }
$fqdnList = Get-Content $VMListPath | Where-Object { $_ -match '\S' }
$vmCount  = $fqdnList.Count
Write-Host "Processing $vmCount VMs..."

$serverRows = New-Object 'System.Collections.Generic.List[PSCustomObject]'
$routeRows  = New-Object 'System.Collections.Generic.List[PSCustomObject]'

foreach ($fqdn in $fqdnList) {
    $serverName = $fqdn.Split('.')[0]
    Write-Host "  [$serverName] Collecting..." -NoNewline

    # --- Get VM from vCenter ---
    try {
        $vm = Get-VM -Name $serverName -ErrorAction Stop
    }
    catch {
        Write-Warning "[$serverName] VM not found in vCenter - skipping."
        continue
    }

    # --- Get all vNICs in adapter order ---
    $nics     = @(Get-NetworkAdapter -VM $vm | Sort-Object -Property Name)
    $nicCount = $nics.Count
    if ($nicCount -lt 2) {
        Write-Warning "[$serverName] Expected at least 2 NICs, found $nicCount - skipping."
        continue
    }

    # --- Pull VLAN IDs from distributed portgroups ---
    $vlanMap = @{}
    foreach ($nic in $nics) {
        $pg = Get-VDPortgroup -Name $nic.NetworkName -ErrorAction SilentlyContinue
        $vlanMap[$nic.NetworkName] = if ($pg) { $pg.VlanConfiguration.VlanId } else { 0 }
    }

    # --- Get LAPS credential for this server (VM still has network) ---
    try {
        $guestCred = Get-LapsPassword -FQDN $fqdn
    }
    catch {
        $lapsErr = $_.Exception.Message
        Write-Warning "[$serverName] LAPS failed: $lapsErr - skipping."
        continue
    }

    # --- Collect guest IP config via Invoke-VMScript ---
    try {
        $scriptResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred `
            -ScriptText $guestNetScript -ScriptType Powershell -ErrorAction Stop
        $guestNet = $scriptResult.ScriptOutput | ConvertFrom-Json
    }
    catch {
        $scriptErr = $_.Exception.Message
        Write-Warning "[$serverName] Invoke-VMScript failed: $scriptErr - skipping."
        continue
    }

    # --- Match each VMware NIC to its guest adapter by IP-in-subnet ---
    # Portgroup name IS the subnet address (e.g. "192.168.1.0").
    # Derive network address from each guest adapter IP+prefix and compare.
    $nicConfigs = New-Object 'System.Collections.Generic.List[hashtable]'

    foreach ($nic in $nics) {
        $portgroupName = $nic.NetworkName
        $matchedCfg    = $null

        foreach ($prop in $guestNet.PSObject.Properties) {
            $adapterCfg = $prop.Value
            if (-not $adapterCfg.IP) { continue }
            $guestNetAddr = Get-NetworkAddress -IP $adapterCfg.IP -Prefix ([int]$adapterCfg.Prefix)
            if ($guestNetAddr -eq $portgroupName) {
                $matchedCfg = $adapterCfg
                break
            }
        }

        if (-not $matchedCfg) {
            Write-Warning "[$serverName] No guest adapter matched portgroup '$portgroupName' - IP config will be empty."
            $matchedCfg = @{ IP = ''; Prefix = 0; Gateway = ''; DNS = @() }
        }

        $dnsArr = @($matchedCfg.DNS)
        $nicConfigs.Add(@{
            vSwitch = $nic.NetworkName
            VLAN    = $vlanMap[$nic.NetworkName]
            IP      = $matchedCfg.IP
            Prefix  = $matchedCfg.Prefix
            Gateway = $matchedCfg.Gateway
            DNS     = $dnsArr
        })
    }

    $nic1    = $nicConfigs[0]
    $nic2    = $nicConfigs[1]
    $nic1Dns = $nic1.DNS
    $nic2Dns = $nic2.DNS

    # --- Collect custom routes ---
    $customRoutes = @()
    <#
        USER-DEFINED ROUTE COLLECTION BLOCK
        ====================================
        Replace this comment with your custom function call.
        Populate $customRoutes as an array of objects with properties:
            Destination, PrefixLength, NextHop
        Example:
            $customRoutes = Get-MyCustomRoutes -VM $vm -GuestCredential $guestCred
    #>

    foreach ($route in $customRoutes) {
        $routeRows.Add([PSCustomObject]@{
            FQDN         = $fqdn
            Destination  = $route.Destination
            PrefixLength = $route.PrefixLength
            NextHop      = $route.NextHop
        })
    }

    # --- Build server row ---
    $serverRows.Add([PSCustomObject]@{
        FQDN         = $fqdn
        HyperVHost   = ''
        NIC1_vSwitch = $nic1.vSwitch
        NIC1_VLAN    = $nic1.VLAN
        NIC1_IP      = $nic1.IP
        NIC1_Prefix  = $nic1.Prefix
        NIC1_GW      = $nic1.Gateway
        NIC1_DNS1    = if ($nic1Dns.Count -gt 0) { $nic1Dns[0] } else { '' }
        NIC1_DNS2    = if ($nic1Dns.Count -gt 1) { $nic1Dns[1] } else { '' }
        NIC2_vSwitch = $nic2.vSwitch
        NIC2_VLAN    = $nic2.VLAN
        NIC2_IP      = $nic2.IP
        NIC2_Prefix  = $nic2.Prefix
        NIC2_GW      = $nic2.Gateway
        NIC2_DNS1    = if ($nic2Dns.Count -gt 0) { $nic2Dns[0] } else { '' }
        NIC2_DNS2    = if ($nic2Dns.Count -gt 1) { $nic2Dns[1] } else { '' }
        Status       = 'Pending'
        Notes        = ''
    })

    Write-Host ' done.'
}

Disconnect-VIServer -Server $vCenter -Confirm:$false

$serverRows | Export-Csv -Path $ServerCSVPath -NoTypeInformation -Force
$routeRows  | Export-Csv -Path $RouteCSVPath  -NoTypeInformation -Force

$serverCount = $serverRows.Count
$routeCount  = $routeRows.Count
Write-Host ''
Write-Host 'Exported:'
Write-Host "  Servers : $ServerCSVPath ($serverCount rows)"
Write-Host "  Routes  : $RouteCSVPath ($routeCount rows)"
