<#
.SYNOPSIS
    Post-migration orchestrator. Runs from the management server after Commvault
    has restored VMs to Hyper-V.
.DESCRIPTION
    For each server in migration_servers.csv with Status = "Pending":
      1. Queries SCVMM to find the Hyper-V host the VM landed on
      2. Remotes into that Hyper-V host and calls Set-HyperVVMConfig
           - Removes old vNICs, adds Front + Back with correct vSwitch/VLAN
           - Enables Secure Boot and Guest Services
           - Returns assigned MAC addresses
      3. Remotes into the Hyper-V host which:
           - Queries LAPS locally (no credential serialization across hops)
           - Uses PowerShell Direct to inject Set-GuestNetworking into the guest
           - Configures IPs, DNS, and custom routes inside the guest (no network needed)
      4. Updates Status in the CSV after each step for resume-on-failure support

    Prerequisites:
      - SCVMM console / SCVMM PowerShell module installed on management server
      - RSAT-AD-PowerShell installed on each Hyper-V host (for LAPS query)
      - Running account must have LAPS read rights (ms-Mcs-AdmPwd) in all target domains
      - Management server must have network access to all Hyper-V hosts
      - Hyper-V hosts must allow PS Remoting from management server
      - Set-HyperVVMConfig.ps1, Set-GuestNetworking.ps1, Get-LapsPassword.ps1 in .\lib\

    Usage:
      .\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com"
      .\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com" -FQDN "server01.corp.contoso.com"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $SCVMMServer,
    [string] $FQDN,                                         # Process a single server; omit to process all Pending
    [string] $ServerCSVPath = ".\data\migration_servers.csv",
    [string] $RouteCSVPath  = ".\data\migration_routes.csv",
    [string] $LibPath       = ".\lib"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Load all lib scripts as strings for remote injection.
# Nothing is dot-sourced locally — all execution happens on the Hyper-V host or inside the guest.
$hvConfigScript = Get-Content "$LibPath\Set-HyperVVMConfig.ps1" -Raw
$guestNetScript = Get-Content "$LibPath\Set-GuestNetworking.ps1" -Raw
$lapsScript     = Get-Content "$LibPath\Get-LapsPassword.ps1"    -Raw

# --- Connect to SCVMM ---
Write-Host "Connecting to SCVMM: $SCVMMServer"
Import-Module VirtualMachineManager -ErrorAction Stop
$scvmm = Get-SCVMMServer -ComputerName $SCVMMServer -ErrorAction Stop

# --- Load CSVs ---
$servers = Import-Csv -Path $ServerCSVPath
$routes  = Import-Csv -Path $RouteCSVPath

if ($FQDN) {
    $servers = $servers | Where-Object { $_.FQDN -eq $FQDN }
    if (-not $servers) { throw "FQDN '$FQDN' not found in $ServerCSVPath" }
}

$pending = $servers | Where-Object { $_.Status -eq 'Pending' }
Write-Host "Found $($pending.Count) server(s) to process."

function Update-ServerStatus {
    param([string]$TargetFQDN, [string]$NewStatus, [string]$Note = '')
    $allRows = Import-Csv -Path $ServerCSVPath
    $row = $allRows | Where-Object { $_.FQDN -eq $TargetFQDN }
    $row.Status = $NewStatus
    if ($Note) { $row.Notes = $Note }
    $allRows | Export-Csv -Path $ServerCSVPath -NoTypeInformation -Force
}

foreach ($server in $pending) {
    $fqdn       = $server.FQDN
    $serverName = $fqdn.Split('.')[0]

    Write-Host "`n=== $fqdn ===" -ForegroundColor Cyan

    # -----------------------------------------------------------------------
    # STEP 1 — Find Hyper-V host via SCVMM
    # -----------------------------------------------------------------------
    Write-Host "  [1/3] Locating VM in SCVMM..."
    try {
        $scVM = Get-SCVirtualMachine -VMMServer $scvmm -Name $serverName -ErrorAction Stop
        if (-not $scVM) { throw "VM '$serverName' not found in SCVMM." }

        $hvHost = $scVM.VMHost.Name
        Write-Host "        Host: $hvHost"

        # Write host back to CSV for reference
        $server.HyperVHost = $hvHost
        (Import-Csv $ServerCSVPath) | ForEach-Object {
            if ($_.FQDN -eq $fqdn) { $_.HyperVHost = $hvHost }
            $_
        } | Export-Csv $ServerCSVPath -NoTypeInformation -Force
    }
    catch {
        Write-Warning "  [$serverName] SCVMM lookup failed: $_"
        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'Failed' -Note "SCVMM: $_"
        continue
    }

    # -----------------------------------------------------------------------
    # STEP 2 — Configure Hyper-V VM hardware (NICs, SecureBoot, GuestServices)
    # -----------------------------------------------------------------------
    Write-Host "  [2/3] Configuring Hyper-V VM hardware on $hvHost..."
    try {
        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'InProgress'

        $macAddresses = Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($script, $vmName, $nic1Switch, $nic1VLAN, $nic2Switch, $nic2VLAN)
            . ([ScriptBlock]::Create($script))
            Set-HyperVVMConfig `
                -VMName     $vmName `
                -NIC1Switch $nic1Switch `
                -NIC1VLAN   $nic1VLAN `
                -NIC2Switch $nic2Switch `
                -NIC2VLAN   $nic2VLAN `
                -Verbose
        } -ArgumentList $hvConfigScript, $serverName, `
            $server.NIC1_vSwitch, [int]$server.NIC1_VLAN, `
            $server.NIC2_vSwitch, [int]$server.NIC2_VLAN

        $nic1MAC = $macAddresses.NIC1MAC
        $nic2MAC = $macAddresses.NIC2MAC
        Write-Host "        NIC1 MAC: $nic1MAC  |  NIC2 MAC: $nic2MAC"
        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'NICsAdded'
    }
    catch {
        Write-Warning "  [$serverName] HV hardware config failed: $_"
        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'Failed' -Note "HVConfig: $_"
        continue
    }

    # -----------------------------------------------------------------------
    # STEP 3 — Configure guest networking via PowerShell Direct
    #           LAPS is queried on the Hyper-V host to avoid credential
    #           serialization across the remoting hop.
    # -----------------------------------------------------------------------
    Write-Host "  [3/3] Configuring guest networking via PowerShell Direct..."
    try {
        # Build NIC config hashtables — no credentials here, just data
        $nic1Cfg = @{
            MAC     = $nic1MAC
            IP      = $server.NIC1_IP
            Prefix  = [int]$server.NIC1_Prefix
            Gateway = $server.NIC1_GW
            DNS     = @($server.NIC1_DNS1, $server.NIC1_DNS2) | Where-Object { $_ }
        }
        $nic2Cfg = @{
            MAC     = $nic2MAC
            IP      = $server.NIC2_IP
            Prefix  = [int]$server.NIC2_Prefix
            Gateway = $server.NIC2_GW
            DNS     = @($server.NIC2_DNS1, $server.NIC2_DNS2) | Where-Object { $_ }
        }

        # Build routes array for this server
        $serverRoutes = $routes |
            Where-Object { $_.FQDN -eq $fqdn } |
            ForEach-Object {
                @{
                    Destination  = $_.Destination
                    PrefixLength = [int]$_.PrefixLength
                    NextHop      = $_.NextHop
                }
            }

        # Remote into the Hyper-V host. The host queries LAPS itself so the
        # PSCredential is created locally — no deserialization issue for PSdirect.
        Invoke-Command -ComputerName $hvHost -ScriptBlock {
            param($lapsScriptSrc, $guestScriptSrc, $targetFqdn, $vmName, $nic1Cfg, $nic2Cfg, $routesCfg)

            # Load LAPS function into this remote session and query locally
            . ([ScriptBlock]::Create($lapsScriptSrc))
            $credential = Get-LapsPassword -FQDN $targetFqdn

            # Build the guest script block
            $guestBlock = [ScriptBlock]::Create($guestScriptSrc)

            # PowerShell Direct — VMBus, credential is a native PSCredential here
            Invoke-Command -VMName      $vmName `
                           -Credential  $credential `
                           -ScriptBlock $guestBlock `
                           -ArgumentList $nic1Cfg, $nic2Cfg, $routesCfg

        } -ArgumentList $lapsScript, $guestNetScript, $fqdn, $serverName, $nic1Cfg, $nic2Cfg, @($serverRoutes)

        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'Complete'
        Write-Host "  [$serverName] Complete." -ForegroundColor Green
    }
    catch {
        Write-Warning "  [$serverName] Guest networking failed: $_"
        Update-ServerStatus -TargetFQDN $fqdn -NewStatus 'Failed' -Note "GuestNet: $_"
    }
}

Write-Host "`nDone. Review $ServerCSVPath for final status."
