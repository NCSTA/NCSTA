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
    [string] $VMListPath    = ".\data\vm_input_list.txt",
    [string] $ServerCSVPath = ".\data\migration_servers.csv",
    [string] $RouteCSVPath  = ".\data\migration_routes.csv",
    [string] $LibPath       = ".\lib"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$LibPath\Get-LapsPassword.ps1"

# --- Connect to vCenter ---
Write-Host "Connecting to vCenter: $vCenter"
$vCenterCred = Get-Credential -Message "vCenter credentials"
Connect-VIServer -Server $vCenter -Credential $vCenterCred -ErrorAction Stop | Out-Null

# Script block executed inside the VM guest to collect all NIC IP/DNS config.
# Returns JSON: { "AdapterAlias": { IP, Prefix, Gateway, DNS[] }, ... }
$guestNetScript = @'
    $results = @{}
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        $alias = $_.InterfaceAlias
        $ip    = Get-NetIPAddress         -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gw    = Get-NetRoute             -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        $dns   = Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ip) {
            $results[$alias] = @{
                IP      = $ip.IPAddress
                Prefix  = [int]$ip.PrefixLength
                Gateway = if ($gw) { $gw.NextHop } else { '' }
                DNS     = if ($dns.ServerAddresses) { @($dns.ServerAddresses) } else { @() }
            }
        }
    }
    return ($results | ConvertTo-Json -Depth 5 -Compress)
'@

# Returns the network address for a given IP and prefix length.
# Used to match a guest adapter IP against a portgroup name like "192.168.1.0".
function Get-NetworkAddress {
    param([string]$IP, [int]$Prefix)
    $ipInt  = [System.BitConverter]::ToUInt32(([System.Net.IPAddress]::Parse($IP).GetAddressBytes() | Select-Object -Last 4), 0)
    # Build mask — shift on UInt32 to avoid sign issues
    if ($Prefix -eq 0) { $mask = 0 }
    else { $mask = [uint32](0xFFFFFFFF -shl (32 - $Prefix)) }
    $netInt = $ipInt -band $mask
    $bytes  = [System.BitConverter]::GetBytes([uint32]$netInt) | Select-Object -Last 4
    return ($bytes[3..0] -join '.')
}

# --- Load VM list ---
if (-not (Test-Path $VMListPath)) { throw "VM input list not found: $VMListPath" }
$fqdnList = Get-Content $VMListPath | Where-Object { $_ -match '\S' }
Write-Host "Processing $($fqdnList.Count) VMs..."

$serverRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$routeRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($fqdn in $fqdnList) {
    $serverName = $fqdn.Split('.')[0]
    Write-Host "  [$serverName] Collecting..." -NoNewline

    # --- Get VM from vCenter ---
    try {
        $vm = Get-VM -Name $serverName -ErrorAction Stop
    }
    catch {
        Write-Warning "  [$serverName] VM not found in vCenter — skipping."
        continue
    }

    # --- Get all vNICs in adapter order ---
    $nics = @(Get-NetworkAdapter -VM $vm | Sort-Object -Property Name)
    if ($nics.Count -lt 2) {
        Write-Warning "  [$serverName] Expected at least 2 NICs, found $($nics.Count) — skipping."
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
        Write-Warning "  [$serverName] LAPS failed: $($_.Exception.Message) — skipping."
        continue
    }

    # --- Collect guest IP config via Invoke-VMScript ---
    try {
        $scriptResult = Invoke-VMScript -VM $vm -GuestCredential $guestCred `
            -ScriptText $guestNetScript -ScriptType Powershell -ErrorAction Stop
        $guestNet = $scriptResult.ScriptOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "  [$serverName] Invoke-VMScript failed: $($_.Exception.Message) — skipping."
        continue
    }

    # --- Match each VMware NIC to its guest adapter by IP-in-subnet ---
    # Portgroup name IS the subnet address (e.g. "192.168.1.0").
    # For each vNIC, find the guest adapter whose IP falls in the same subnet.
    $nicConfigs = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($nic in $nics) {
        $portgroupName = $nic.NetworkName   # e.g. "192.168.1.0"
        $matchedCfg    = $null

        foreach ($prop in $guestNet.PSObject.Properties) {
            $adapterCfg = $prop.Value
            if (-not $adapterCfg.IP) { continue }

            # Derive the network address of the guest adapter IP using its prefix
            $guestNetAddr = Get-NetworkAddress -IP $adapterCfg.IP -Prefix ([int]$adapterCfg.Prefix)

            if ($guestNetAddr -eq $portgroupName) {
                $matchedCfg = $adapterCfg
                break
            }
        }

        if (-not $matchedCfg) {
            Write-Warning "  [$serverName] No guest adapter matched portgroup '$portgroupName' — IP config will be empty for this NIC."
            $matchedCfg = @{ IP = ''; Prefix = 0; Gateway = ''; DNS = @() }
        }

        $nicConfigs.Add(@{
            vSwitch = $nic.NetworkName
            VLAN    = $vlanMap[$nic.NetworkName]
            IP      = $matchedCfg.IP
            Prefix  = $matchedCfg.Prefix
            Gateway = $matchedCfg.Gateway
            DNS     = @($matchedCfg.DNS)
        })
    }

    $nic1 = $nicConfigs[0]
    $nic2 = $nicConfigs[1]

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
        FQDN          = $fqdn
        HyperVHost    = ''
        NIC1_vSwitch  = $nic1.vSwitch
        NIC1_VLAN     = $nic1.VLAN
        NIC1_IP       = $nic1.IP
        NIC1_Prefix   = $nic1.Prefix
        NIC1_GW       = $nic1.Gateway
        NIC1_DNS1     = if ($nic1.DNS.Count -gt 0) { $nic1.DNS[0] } else { '' }
        NIC1_DNS2     = if ($nic1.DNS.Count -gt 1) { $nic1.DNS[1] } else { '' }
        NIC2_vSwitch  = $nic2.vSwitch
        NIC2_VLAN     = $nic2.VLAN
        NIC2_IP       = $nic2.IP
        NIC2_Prefix   = $nic2.Prefix
        NIC2_GW       = $nic2.Gateway
        NIC2_DNS1     = if ($nic2.DNS.Count -gt 0) { $nic2.DNS[0] } else { '' }
        NIC2_DNS2     = if ($nic2.DNS.Count -gt 1) { $nic2.DNS[1] } else { '' }
        Status        = 'Pending'
        Notes         = ''
    })

    Write-Host " done."
}

Disconnect-VIServer -Server $vCenter -Confirm:$false

$serverRows | Export-Csv -Path $ServerCSVPath -NoTypeInformation -Force
$routeRows  | Export-Csv -Path $RouteCSVPath  -NoTypeInformation -Force

Write-Host "`nExported:"
Write-Host "  Servers : $ServerCSVPath ($($serverRows.Count) rows)"
Write-Host "  Routes  : $RouteCSVPath ($($routeRows.Count) rows)"
