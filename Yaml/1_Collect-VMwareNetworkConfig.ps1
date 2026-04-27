<#
.SYNOPSIS
    Pre-migration data collector. Connects to vCenter via PowerCLI and gathers
    network configuration for each target VM.
.DESCRIPTION
    For each VM in the provided list:
      - Identifies Front and Back network adapters by portgroup name pattern
      - Runs Invoke-VMScript inside the guest to collect IP, subnet, gateway, DNS
      - Calls the user-supplied route collection function (stub below)
      - Outputs migration_servers.csv and migration_routes.csv

    Prerequisites:
      - VMware.PowerCLI module installed on the management server
      - vCenter credentials with guest operations rights (for Invoke-VMScript)
      - Guest credentials with admin rights (for Invoke-VMScript)
      - Input: .\data\vm_input_list.txt  — one FQDN per line

    Usage:
      .\1_Collect-VMwareNetworkConfig.ps1 `
          -vCenter     "vcenter.corp.contoso.com" `
          -FrontPGPattern "Front*" `
          -BackPGPattern  "Back*"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $vCenter,
    [Parameter(Mandatory)] [string] $FrontPGPattern,
    [Parameter(Mandatory)] [string] $BackPGPattern,
    [string] $VMListPath    = ".\data\vm_input_list.txt",
    [string] $ServerCSVPath = ".\data\migration_servers.csv",
    [string] $RouteCSVPath  = ".\data\migration_routes.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Connect to vCenter ---
Write-Host "Connecting to vCenter: $vCenter"
$vCenterCred = Get-Credential -Message "vCenter credentials"
Connect-VIServer -Server $vCenter -Credential $vCenterCred -ErrorAction Stop | Out-Null

# Guest credentials (used for Invoke-VMScript)
$guestCred = Get-Credential -Message "Guest OS local admin credentials (used for Invoke-VMScript)"

# Script block executed inside the VM guest to collect IP/DNS configuration
$guestNetScript = @'
    $results = @{}
    Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        $alias = $_.InterfaceAlias
        $ip    = Get-NetIPAddress    -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $gw    = Get-NetRoute        -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
        $dns   = Get-DnsClientServerAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $results[$alias] = @{
            IP      = $ip.IPAddress
            Prefix  = $ip.PrefixLength
            Gateway = $gw.NextHop
            DNS     = $dns.ServerAddresses
        }
    }
    return ($results | ConvertTo-Json -Depth 5)
'@

# --- Load VM list ---
if (-not (Test-Path $VMListPath)) {
    throw "VM input list not found: $VMListPath"
}
$fqdnList = Get-Content $VMListPath | Where-Object { $_ -match '\S' }
Write-Host "Processing $($fqdnList.Count) VMs..."

$serverRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$routeRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($fqdn in $fqdnList) {
    $serverName = $fqdn.Split('.')[0]
    Write-Host "  [$serverName] Collecting..." -NoNewline

    try {
        $vm = Get-VM -Name $serverName -ErrorAction Stop
    }
    catch {
        Write-Warning "  [$serverName] VM not found in vCenter — skipping."
        continue
    }

    # --- Identify Front and Back NICs by portgroup name ---
    $nics     = Get-NetworkAdapter -VM $vm
    $frontNIC = $nics | Where-Object { $_.NetworkName -like $FrontPGPattern } | Select-Object -First 1
    $backNIC  = $nics | Where-Object { $_.NetworkName -like $BackPGPattern  } | Select-Object -First 1

    if (-not $frontNIC -or -not $backNIC) {
        Write-Warning "  [$serverName] Could not identify Front/Back NICs (matched: Front=$($frontNIC.NetworkName), Back=$($backNIC.NetworkName)) — skipping."
        continue
    }

    # --- Extract VLAN IDs from portgroup ---
    $frontPG   = Get-VDPortgroup -Name $frontNIC.NetworkName -ErrorAction SilentlyContinue
    $backPG    = Get-VDPortgroup -Name $backNIC.NetworkName  -ErrorAction SilentlyContinue
    $frontVLAN = if ($frontPG) { $frontPG.VlanConfiguration.VlanId } else { 0 }
    $backVLAN  = if ($backPG)  { $backPG.VlanConfiguration.VlanId  } else { 0 }

    # --- Collect guest network config via Invoke-VMScript ---
    try {
        $scriptOutput = Invoke-VMScript -VM $vm -GuestCredential $guestCred -ScriptText $guestNetScript -ScriptType Powershell -ErrorAction Stop
        $guestNet     = $scriptOutput.ScriptOutput | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "  [$serverName] Invoke-VMScript failed: $($_.Exception.Message) — skipping."
        continue
    }

    # Match adapter alias to front/back by IP range or adapter index if needed
    # Simplification: assume adapter aliases inside guest match portgroup context
    # Adjust the keys below if your guest alias names differ
    $frontAlias = $guestNet.PSObject.Properties.Name | Select-Object -First 1
    $backAlias  = $guestNet.PSObject.Properties.Name | Select-Object -Last 1

    $frontCfg = $guestNet.$frontAlias
    $backCfg  = $guestNet.$backAlias

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
        FQDN            = $fqdn
        HyperVHost      = ''
        FrontNIC_vSwitch = $frontNIC.NetworkName
        FrontNIC_VLAN   = $frontVLAN
        FrontNIC_IP     = $frontCfg.IP
        FrontNIC_Prefix = $frontCfg.Prefix
        FrontNIC_GW     = $frontCfg.Gateway
        FrontNIC_DNS1   = $frontCfg.DNS[0]
        FrontNIC_DNS2   = if ($frontCfg.DNS.Count -gt 1) { $frontCfg.DNS[1] } else { '' }
        BackNIC_vSwitch = $backNIC.NetworkName
        BackNIC_VLAN    = $backVLAN
        BackNIC_IP      = $backCfg.IP
        BackNIC_Prefix  = $backCfg.Prefix
        BackNIC_GW      = $backCfg.Gateway
        Status          = 'Pending'
        Notes           = ''
    })

    Write-Host " done."
}

Disconnect-VIServer -Server $vCenter -Confirm:$false

# --- Export ---
$serverRows | Export-Csv -Path $ServerCSVPath -NoTypeInformation -Force
$routeRows  | Export-Csv -Path $RouteCSVPath  -NoTypeInformation -Force

Write-Host "`nExported:"
Write-Host "  Servers : $ServerCSVPath ($($serverRows.Count) rows)"
Write-Host "  Routes  : $RouteCSVPath ($($routeRows.Count) rows)"
