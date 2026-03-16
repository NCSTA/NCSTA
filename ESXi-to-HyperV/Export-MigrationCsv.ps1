#Requires -Version 5.1
<#
.SYNOPSIS
    Exports VMware VM data via PowerCLI into the CSV format required by Convert-EsxiToHyperV.ps1.
.DESCRIPTION
    Connects to vCenter/ESXi via PowerCLI and pulls VM configuration data
    (CPU, memory, NICs, port groups, VLANs) for the specified VMs.

    The export produces a CSV with VMware source fields pre-populated and
    SCVMM target fields (TargetSwitch, TargetVMNetwork) left for the user
    to fill in. A VLAN-to-network mapping can be provided to auto-populate
    the target columns.

    MODULE CONFLICT NOTE:
    This script uses module-qualified PowerCLI calls (VMware.VimAutomation.Core\*)
    to avoid conflicts with the Hyper-V module's identically named cmdlets.
.PARAMETER VIServer
    vCenter or ESXi host to connect to via PowerCLI.
.PARAMETER VMName
    One or more VM names to export. Accepts wildcards.
.PARAMETER Credential
    PSCredential for vCenter/ESXi authentication. If not provided, prompts interactively.
.PARAMETER TargetHost
    FQDN of the destination Hyper-V host. Applied to all exported VMs.
.PARAMETER StoragePath
    Cluster storage path on the target host (e.g., C:\ClusterStorage\Volume5).
.PARAMETER Generation
    VM generation for the converted VM. Defaults to 2.
.PARAMETER DelayedStartSec
    Delayed auto-start in seconds. Defaults to 120.
.PARAMETER NetworkMap
    Hashtable mapping VMware port group names to SCVMM target config.
    Format: @{ 'VMware Port Group' = @{ Switch = 'SCVMM Switch'; VMNetwork = 'SCVMM VM Network' } }
    Any NICs not matched are left blank for manual entry.
.PARAMETER OutputPath
    Path for the output CSV file. Defaults to .\configs\migration-export.csv.
.PARAMETER Append
    Append to an existing CSV instead of overwriting.
.EXAMPLE
    # Basic export — fill in target columns manually after
    .\Export-MigrationCsv.ps1 -VIServer vcenter.domain.com `
        -VMName "edcwwsod011v" `
        -TargetHost "medwhypp003.gwnsm.guidewell.net" `
        -StoragePath "C:\ClusterStorage\Volume5"
.EXAMPLE
    # Export with network mapping to auto-populate target columns
    $netMap = @{
        'VLAN_2071_Production' = @{ Switch = 'Production Switch'; VMNetwork = '172.18.71.x Network' }
        'VLAN_2746_NSM'        = @{ Switch = 'NSM Switch';        VMNetwork = '172.25.122.x Network' }
    }
    .\Export-MigrationCsv.ps1 -VIServer vcenter.domain.com `
        -VMName "edcwwsod*" `
        -TargetHost "medwhypp003.gwnsm.guidewell.net" `
        -StoragePath "C:\ClusterStorage\Volume5" `
        -NetworkMap $netMap
.EXAMPLE
    # Export multiple specific VMs
    .\Export-MigrationCsv.ps1 -VIServer vcenter.domain.com `
        -VMName "server01v","server02v","server03v" `
        -TargetHost "medwhypp003.gwnsm.guidewell.net" `
        -StoragePath "C:\ClusterStorage\Volume5"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$VIServer,

    [Parameter(Mandatory)]
    [string[]]$VMName,

    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory)]
    [string]$TargetHost,

    [Parameter(Mandatory)]
    [string]$StoragePath,

    [int]$Generation = 2,

    [int]$DelayedStartSec = 120,

    [hashtable]$NetworkMap,

    [string]$OutputPath,

    [switch]$Append
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent (Resolve-Path $MyInvocation.MyCommand.Path)

if (-not $OutputPath) {
    $OutputPath = Join-Path $scriptDir 'configs\migration-export.csv'
}
# Resolve to full path if relative path was provided
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path (Get-Location).Path $OutputPath
}

# ── Verify PowerCLI is available ──────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name 'VMware.VimAutomation.Core')) {
    throw "VMware.PowerCLI module is not installed. Install with: Install-Module VMware.PowerCLI -Scope CurrentUser"
}

# ── Connect to vCenter/ESXi ──────────────────────────────────────────────────
Write-Host "Connecting to vCenter/ESXi: $VIServer ..." -ForegroundColor Cyan
$connectParams = @{ Server = $VIServer; ErrorAction = 'Stop' }
if ($Credential) { $connectParams['Credential'] = $Credential }

$viConn = VMware.VimAutomation.Core\Connect-VIServer @connectParams
Write-Host "Connected to $($viConn.Name)." -ForegroundColor Green

try {
    # ── Resolve VMs ───────────────────────────────────────────────────────────
    $allVMs = @()
    foreach ($name in $VMName) {
        $found = VMware.VimAutomation.Core\Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $found) {
            Write-Warning "VM '$name' not found on '$VIServer'. Skipping."
            continue
        }
        $allVMs += $found
    }

    if ($allVMs.Count -eq 0) {
        Write-Host "No matching VMs found. Nothing to export." -ForegroundColor Yellow
        return
    }

    Write-Host "Found $($allVMs.Count) VM(s) to export." -ForegroundColor Cyan

    # ── Build CSV Rows ────────────────────────────────────────────────────────
    $rows = @()
    $unmappedPortGroups = @()

    foreach ($vm in $allVMs) {
        Write-Host "  Processing: $($vm.Name) on $($vm.VMHost.Name) ..." -ForegroundColor Gray

        # Get network adapters from VMware (wrap in array for single-NIC VMs)
        $vmAdapters = @(VMware.VimAutomation.Core\Get-NetworkAdapter -VM $vm)

        # Build the row with base VM properties
        $row = [ordered]@{
            VMName          = $vm.Name
            SourceHost      = $vm.VMHost.Name
            TargetHost      = $TargetHost
            StoragePath     = $StoragePath
            CPUCount        = $vm.NumCpu
            MemoryMB        = $vm.MemoryMB
            Generation      = $Generation
            DelayedStartSec = $DelayedStartSec
        }

        # Populate NIC1 through NIC4 columns
        for ($i = 0; $i -lt 4; $i++) {
            $nicNum = $i + 1

            if ($i -lt $vmAdapters.Count) {
                $adapter      = $vmAdapters[$i]
                $portGroupName = $adapter.NetworkName

                # Get VLAN ID from the port group
                $vlanId = ''
                try {
                    $pg = VMware.VimAutomation.Core\Get-VirtualPortGroup -VM $vm -Name $portGroupName -ErrorAction SilentlyContinue
                    if ($pg) { $vlanId = $pg.VLanId }
                }
                catch { }

                # Map to SCVMM target if NetworkMap provided
                $targetSwitch    = ''
                $targetVMNetwork = ''
                if ($NetworkMap -and $NetworkMap.ContainsKey($portGroupName)) {
                    $mapping         = $NetworkMap[$portGroupName]
                    $targetSwitch    = $mapping.Switch
                    $targetVMNetwork = $mapping.VMNetwork
                }
                elseif ($NetworkMap) {
                    # Track unmapped port groups for warning
                    if ($portGroupName -notin $unmappedPortGroups) {
                        $unmappedPortGroups += $portGroupName
                    }
                }

                $row["NIC${nicNum}_SourcePortGroup"] = $portGroupName
                $row["NIC${nicNum}_VLAN"]            = $vlanId
                $row["NIC${nicNum}_TargetSwitch"]    = $targetSwitch
                $row["NIC${nicNum}_TargetVMNetwork"] = $targetVMNetwork
            }
            else {
                $row["NIC${nicNum}_SourcePortGroup"] = ''
                $row["NIC${nicNum}_VLAN"]            = ''
                $row["NIC${nicNum}_TargetSwitch"]    = ''
                $row["NIC${nicNum}_TargetVMNetwork"] = ''
            }
        }

        if ($vmAdapters.Count -gt 4) {
            Write-Warning "VM '$($vm.Name)' has $($vmAdapters.Count) NICs but CSV supports max 4. Extra NICs will not be exported."
        }

        $rows += [PSCustomObject]$row
    }

    # ── Export CSV ────────────────────────────────────────────────────────────
    $outputDir = Split-Path $OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    if ($Append -and (Test-Path $OutputPath)) {
        $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Append
        Write-Host "Appended $($rows.Count) VM(s) to: $OutputPath" -ForegroundColor Green
    }
    else {
        $rows | Export-Csv -Path $OutputPath -NoTypeInformation
        Write-Host "Exported $($rows.Count) VM(s) to: $OutputPath" -ForegroundColor Green
    }

    # ── Display Summary ───────────────────────────────────────────────────────
    Write-Host ''
    Write-Host 'Exported VMs:' -ForegroundColor White
    $rows | Format-Table VMName, SourceHost, CPUCount, MemoryMB,
        @{L='NICs'; E={
            $count = 0
            for ($n = 1; $n -le 4; $n++) { if ($_."NIC${n}_SourcePortGroup") { $count++ } }
            $count
        }} -AutoSize

    Write-Host "Target Host:    $TargetHost" -ForegroundColor Gray
    Write-Host "Storage Path:   $StoragePath" -ForegroundColor Gray
    Write-Host "Generation:     $Generation" -ForegroundColor Gray
    Write-Host "Delayed Start:  ${DelayedStartSec}s" -ForegroundColor Gray

    # Warn about unmapped port groups
    if ($unmappedPortGroups.Count -gt 0) {
        Write-Host ''
        Write-Host 'WARNING: The following VMware port groups have no SCVMM mapping:' -ForegroundColor Yellow
        $unmappedPortGroups | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
        Write-Host 'Fill in the TargetSwitch and TargetVMNetwork columns in the CSV before running conversion.' -ForegroundColor Yellow
    }

    # Warn if no NetworkMap was provided at all
    if (-not $NetworkMap) {
        Write-Host ''
        Write-Host 'NOTE: No -NetworkMap provided. TargetSwitch and TargetVMNetwork columns are empty.' -ForegroundColor Yellow
        Write-Host 'Fill these in before running Convert-EsxiToHyperV.ps1, or re-run with -NetworkMap.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Next step - review the CSV, then run:' -ForegroundColor Cyan
    Write-Host "  .\Convert-EsxiToHyperV.ps1 -CsvPath `"$OutputPath`" -VMMServer `"<your-vmm-server>`"" -ForegroundColor Cyan
}
finally {
    # Disconnect from vCenter
    VMware.VimAutomation.Core\Disconnect-VIServer -Server $VIServer -Confirm:$false -ErrorAction SilentlyContinue
}
