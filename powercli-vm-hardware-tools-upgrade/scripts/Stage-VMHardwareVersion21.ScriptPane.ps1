<#
.SYNOPSIS
    Stages VM hardware version 21 for selected Windows Server VMs.

.NOTES
    Paste-ready script-pane version. No param block is required.

    Run Connect-VIServer before running this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==========================================================
# EDITABLE SETTINGS
# ==========================================================

# $false = preview only. No vCenter changes are made.
# $true  = actually schedule eligible VMs for the hardware upgrade.
$ApplyChanges = $false

# vSphere 8.0 Update 2 virtual hardware version 21.
$TargetHardwareVersion = 'vmx-21'

# Minimum accepted VMware Tools major version. For vCenter numeric Tools
# versions, 13 maps to a threshold of 13000.
$MinimumToolsMajorVersion = 13

# CSV audit output location.
$OutputDirectory = 'C:\Temp\VMHardwareUpgradeResults'

# Enter exact VM inventory names here.
$ServerNames = @(
    'SERVER01',
    'SERVER02',
    'SERVER03'
)

# ==========================================================
# END SETTINGS
# ==========================================================

$PreviewVMs                 = [System.Collections.Generic.List[object]]::new()
$ScheduledVMs               = [System.Collections.Generic.List[object]]::new()
$SkippedVMs                 = [System.Collections.Generic.List[object]]::new()
$SkippedOldToolsVMs         = [System.Collections.Generic.List[object]]::new()
$SkippedMissingToolsVMs     = [System.Collections.Generic.List[object]]::new()
$SkippedToolsNotRunningVMs  = [System.Collections.Generic.List[object]]::new()
$SkippedOtherVMs            = [System.Collections.Generic.List[object]]::new()
$FailedVMs                  = [System.Collections.Generic.List[object]]::new()
$NotFoundVMs                = [System.Collections.Generic.List[object]]::new()

function Test-IsWindowsServerVMView {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$VMView
    )

    $configuredOS = [string]$VMView.Config.GuestFullName
    $reportedOS = [string]$VMView.Guest.GuestFullName
    $guestId = [string]$VMView.Config.GuestId

    return (
        $configuredOS -match 'Windows Server' -or
        $reportedOS -match 'Windows Server' -or
        $guestId -match '(?i)windows.*(server|srv)'
    )
}

function Add-SkipResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateSet('OldTools', 'MissingTools', 'ToolsNotRunning', 'Other')]
        [string]$SkipCategory,

        [Parameter(Mandatory)]
        [string]$Reason,

        [AllowNull()]
        [object]$VMView,

        [AllowNull()]
        [string]$ToolsVersion,

        [AllowNull()]
        [string]$ToolsStatus,

        [AllowNull()]
        [string]$ToolsRunningStatus
    )

    $result = [pscustomobject]@{
        VMName             = $VMName
        Result             = 'Skipped'
        SkipCategory       = $SkipCategory
        Reason             = $Reason
        PowerState         = if ($null -ne $VMView) { [string]$VMView.Runtime.PowerState } else { '' }
        CurrentHardware    = if ($null -ne $VMView) { [string]$VMView.Config.Version } else { '' }
        TargetHardware     = $TargetHardwareVersion
        ToolsRawVersion    = $ToolsVersion
        ToolsVersionStatus = $ToolsStatus
        ToolsRunningStatus = $ToolsRunningStatus
        Timestamp          = Get-Date
    }

    $SkippedVMs.Add($result)

    switch ($SkipCategory) {
        'OldTools'        { $SkippedOldToolsVMs.Add($result) | Out-Null }
        'MissingTools'    { $SkippedMissingToolsVMs.Add($result) | Out-Null }
        'ToolsNotRunning' { $SkippedToolsNotRunningVMs.Add($result) | Out-Null }
        default           { $SkippedOtherVMs.Add($result) | Out-Null }
    }
}

function Export-ResultList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IEnumerable]$Items,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $itemArray = @($Items)

    if ($itemArray.Count -gt 0) {
        $itemArray | Export-Csv -LiteralPath $Path -NoTypeInformation
    }
}

function Add-ListItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Target,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.IEnumerable]$Source
    )

    foreach ($item in $Source) {
        $Target.Add($item) | Out-Null
    }
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw 'VMware PowerCLI is not installed. Install the VMware.VimAutomation.Core module first.'
}

$connectedServers = @($global:DefaultVIServers | Where-Object { $_.IsConnected })

if ($connectedServers.Count -eq 0) {
    throw 'No active vCenter connection was found. Run Connect-VIServer first.'
}

if ($ServerNames.Count -eq 0) {
    throw 'The $ServerNames array is empty.'
}

if ($TargetHardwareVersion -notmatch '^vmx-(\d+)$') {
    throw "The target hardware version '$TargetHardwareVersion' is invalid. Expected a value such as vmx-21."
}

$targetHardwareNumber = [int]$Matches[1]
$minimumToolsNumber = $MinimumToolsMajorVersion * 1000

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

Write-Host ''
Write-Host 'VM hardware upgrade staging' -ForegroundColor Cyan
Write-Host "Apply changes            : $ApplyChanges"
Write-Host "Target hardware version  : $TargetHardwareVersion"
Write-Host "Minimum Tools generation : $MinimumToolsMajorVersion.0"
Write-Host "Tools numeric threshold  : $minimumToolsNumber"
Write-Host "Requested VM count       : $($ServerNames.Count)"
Write-Host ''

foreach ($serverName in $ServerNames) {
    Write-Host "Processing $serverName..." -ForegroundColor Cyan

    try {
        $matchingVMs = @(
            Get-VM -Name $serverName -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $serverName }
        )

        if ($matchingVMs.Count -eq 0) {
            $NotFoundVMs.Add(
                [pscustomobject]@{
                    VMName    = $serverName
                    Result    = 'Not Found'
                    Reason    = 'No VM with this exact inventory name was found.'
                    Timestamp = Get-Date
                }
            ) | Out-Null

            Write-Warning "$serverName was not found."
            continue
        }

        if ($matchingVMs.Count -gt 1) {
            Add-SkipResult `
                -VMName $serverName `
                -SkipCategory 'Other' `
                -Reason "Multiple VMs named '$serverName' were found. Use a unique inventory name or connect to only one vCenter." `
                -VMView $null `
                -ToolsVersion '' `
                -ToolsStatus '' `
                -ToolsRunningStatus ''

            Write-Warning "Multiple VMs named $serverName were found."
            continue
        }

        $vmObject = $matchingVMs[0]

        $vmView = Get-View -Id $vmObject.Id -Property @(
            'Name',
            'Config.Template',
            'Config.GuestFullName',
            'Config.GuestId',
            'Config.Version',
            'Config.ScheduledHardwareUpgradeInfo',
            'Guest.GuestFullName',
            'Guest.ToolsVersion',
            'Guest.ToolsVersionStatus2',
            'Guest.ToolsRunningStatus',
            'Runtime.PowerState'
        )

        $toolsRawVersion = [string]$vmView.Guest.ToolsVersion
        $toolsStatus = [string]$vmView.Guest.ToolsVersionStatus2
        $toolsRunningStatus = [string]$vmView.Guest.ToolsRunningStatus

        if ($vmView.Config.Template) {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'Other' `
                -Reason 'The inventory object is a VM template.' `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            continue
        }

        if (-not (Test-IsWindowsServerVMView -VMView $vmView)) {
            $configuredOS = [string]$vmView.Config.GuestFullName
            $reportedOS = [string]$vmView.Guest.GuestFullName

            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'Other' `
                -Reason "The VM is not identified as Windows Server. Configured OS: '$configuredOS'; reported OS: '$reportedOS'." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            continue
        }

        if ($vmView.Config.Version -notmatch '^vmx-(\d+)$') {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'Other' `
                -Reason "Unable to parse current hardware version '$($vmView.Config.Version)'." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            continue
        }

        $currentHardwareNumber = [int]$Matches[1]

        if ($currentHardwareNumber -ge $targetHardwareNumber) {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'Other' `
                -Reason "VM is already at hardware version $($vmView.Config.Version), which meets or exceeds $TargetHardwareVersion." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            continue
        }

        if ([string]::IsNullOrWhiteSpace($toolsRawVersion) -or
            $toolsRawVersion -eq '0' -or
            $toolsStatus -eq 'guestToolsNotInstalled') {

            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'MissingTools' `
                -Reason 'VMware Tools is not installed or vCenter cannot determine its version.' `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            Write-Warning "$($vmView.Name) skipped because VMware Tools is missing or unknown."
            continue
        }

        if ($toolsRawVersion -notmatch '^\d+$') {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'MissingTools' `
                -Reason "VMware Tools version '$toolsRawVersion' is not numeric and cannot be safely compared with the Version $MinimumToolsMajorVersion threshold." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            Write-Warning "$($vmView.Name) skipped because VMware Tools version is not numeric."
            continue
        }

        if ([int]$toolsRawVersion -lt $minimumToolsNumber) {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'OldTools' `
                -Reason "VMware Tools numeric version $toolsRawVersion is below the required Version $MinimumToolsMajorVersion threshold of $minimumToolsNumber." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            Write-Warning "$($vmView.Name) skipped because VMware Tools is below Version $MinimumToolsMajorVersion."
            continue
        }

        if ($toolsRunningStatus -ne 'guestToolsRunning') {
            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'ToolsNotRunning' `
                -Reason "VMware Tools is not running. Current running status: '$toolsRunningStatus'." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            Write-Warning "$($vmView.Name) skipped because VMware Tools is not running."
            continue
        }

        $existingScheduledUpgrade = $vmView.Config.ScheduledHardwareUpgradeInfo

        if ($null -ne $existingScheduledUpgrade -and
            $existingScheduledUpgrade.UpgradePolicy -eq 'always' -and
            $existingScheduledUpgrade.VersionKey -eq $TargetHardwareVersion) {

            Add-SkipResult `
                -VMName $vmView.Name `
                -SkipCategory 'Other' `
                -Reason "Hardware upgrade to $TargetHardwareVersion is already scheduled." `
                -VMView $vmView `
                -ToolsVersion $toolsRawVersion `
                -ToolsStatus $toolsStatus `
                -ToolsRunningStatus $toolsRunningStatus

            continue
        }

        if ($ApplyChanges -eq $false) {
            $PreviewVMs.Add(
                [pscustomobject]@{
                    VMName             = $vmView.Name
                    Result             = 'Preview'
                    Reason             = 'VM is eligible. No change was made because ApplyChanges is false.'
                    PowerState         = [string]$vmView.Runtime.PowerState
                    CurrentHardware    = [string]$vmView.Config.Version
                    TargetHardware     = $TargetHardwareVersion
                    ToolsRawVersion    = $toolsRawVersion
                    ToolsVersionStatus = $toolsStatus
                    ToolsRunningStatus = $toolsRunningStatus
                    Timestamp          = Get-Date
                }
            ) | Out-Null

            Write-Host "$($vmView.Name): eligible for upgrade, preview only." -ForegroundColor Cyan
            continue
        }

        $configSpec = New-Object VMware.Vim.VirtualMachineConfigSpec

        $upgradeInfo = New-Object VMware.Vim.ScheduledHardwareUpgradeInfo
        $upgradeInfo.UpgradePolicy = 'always'
        $upgradeInfo.VersionKey = $TargetHardwareVersion

        $configSpec.ScheduledHardwareUpgradeInfo = $upgradeInfo

        $taskReference = $vmView.ReconfigVM_Task($configSpec)
        $task = Get-Task -Id "Task-$($taskReference.Value)" -ErrorAction Stop
        $task | Wait-Task -ErrorAction Stop | Out-Null

        $refreshedVM = Get-View -Id $vmObject.Id -Property @(
            'Config.Version',
            'Config.ScheduledHardwareUpgradeInfo',
            'Runtime.PowerState'
        )

        $scheduledInfo = $refreshedVM.Config.ScheduledHardwareUpgradeInfo

        if ($null -eq $scheduledInfo -or
            $scheduledInfo.UpgradePolicy -ne 'always' -or
            $scheduledInfo.VersionKey -ne $TargetHardwareVersion) {

            throw 'The reconfiguration task completed, but the scheduled hardware upgrade settings could not be verified.'
        }

        $ScheduledVMs.Add(
            [pscustomobject]@{
                VMName             = $vmView.Name
                Result             = 'Scheduled'
                Reason             = 'Hardware upgrade successfully scheduled.'
                PowerState         = [string]$refreshedVM.Runtime.PowerState
                CurrentHardware    = [string]$refreshedVM.Config.Version
                TargetHardware     = $TargetHardwareVersion
                ToolsRawVersion    = $toolsRawVersion
                ToolsVersionStatus = $toolsStatus
                ToolsRunningStatus = $toolsRunningStatus
                UpgradePolicy      = [string]$scheduledInfo.UpgradePolicy
                ScheduledVersion   = [string]$scheduledInfo.VersionKey
                TaskId             = $task.Id
                Timestamp          = Get-Date
            }
        ) | Out-Null

        Write-Host "$($vmView.Name): scheduled successfully." -ForegroundColor Green
    }
    catch {
        $FailedVMs.Add(
            [pscustomobject]@{
                VMName    = $serverName
                Result    = 'Failed'
                Reason    = $_.Exception.Message
                Timestamp = Get-Date
            }
        ) | Out-Null

        Write-Error "$serverName failed: $($_.Exception.Message)" -ErrorAction Continue
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$previewPath              = Join-Path $OutputDirectory "Preview-$timestamp.csv"
$scheduledPath            = Join-Path $OutputDirectory "Scheduled-$timestamp.csv"
$skippedAllPath           = Join-Path $OutputDirectory "Skipped-All-$timestamp.csv"
$skippedOldToolsPath      = Join-Path $OutputDirectory "Skipped-OldTools-$timestamp.csv"
$skippedMissingToolsPath  = Join-Path $OutputDirectory "Skipped-MissingTools-$timestamp.csv"
$skippedToolsNotRunPath   = Join-Path $OutputDirectory "Skipped-ToolsNotRunning-$timestamp.csv"
$skippedOtherPath         = Join-Path $OutputDirectory "Skipped-Other-$timestamp.csv"
$failedPath               = Join-Path $OutputDirectory "Failed-$timestamp.csv"
$notFoundPath             = Join-Path $OutputDirectory "NotFound-$timestamp.csv"
$combinedPath             = Join-Path $OutputDirectory "Combined-$timestamp.csv"

Export-ResultList -Items $PreviewVMs -Path $previewPath
Export-ResultList -Items $ScheduledVMs -Path $scheduledPath
Export-ResultList -Items $SkippedVMs -Path $skippedAllPath
Export-ResultList -Items $SkippedOldToolsVMs -Path $skippedOldToolsPath
Export-ResultList -Items $SkippedMissingToolsVMs -Path $skippedMissingToolsPath
Export-ResultList -Items $SkippedToolsNotRunningVMs -Path $skippedToolsNotRunPath
Export-ResultList -Items $SkippedOtherVMs -Path $skippedOtherPath
Export-ResultList -Items $FailedVMs -Path $failedPath
Export-ResultList -Items $NotFoundVMs -Path $notFoundPath

$combinedResults = [System.Collections.Generic.List[object]]::new()
Add-ListItems -Target $combinedResults -Source $PreviewVMs
Add-ListItems -Target $combinedResults -Source $ScheduledVMs
Add-ListItems -Target $combinedResults -Source $SkippedVMs
Add-ListItems -Target $combinedResults -Source $FailedVMs
Add-ListItems -Target $combinedResults -Source $NotFoundVMs

Export-ResultList -Items $combinedResults -Path $combinedPath

Write-Host ''
Write-Host 'Upgrade staging summary' -ForegroundColor Cyan
Write-Host "Preview              : $($PreviewVMs.Count)" -ForegroundColor Cyan
Write-Host "Scheduled            : $($ScheduledVMs.Count)" -ForegroundColor Green
Write-Host "Skipped all          : $($SkippedVMs.Count)" -ForegroundColor Yellow
Write-Host "Skipped old Tools    : $($SkippedOldToolsVMs.Count)" -ForegroundColor Yellow
Write-Host "Skipped missing Tools: $($SkippedMissingToolsVMs.Count)" -ForegroundColor Yellow
Write-Host "Skipped Tools stopped: $($SkippedToolsNotRunningVMs.Count)" -ForegroundColor Yellow
Write-Host "Skipped other        : $($SkippedOtherVMs.Count)" -ForegroundColor Yellow
Write-Host "Failed               : $($FailedVMs.Count)" -ForegroundColor Red
Write-Host "Not found            : $($NotFoundVMs.Count)" -ForegroundColor Yellow
Write-Host "Results              : $((Resolve-Path -LiteralPath $OutputDirectory).Path)"
Write-Host ''

if ($SkippedVMs.Count -gt 0) {
    Write-Host 'Skipped VMs:' -ForegroundColor Yellow

    $SkippedVMs |
        Select-Object VMName, SkipCategory, Reason, CurrentHardware,
            ToolsRawVersion, ToolsVersionStatus, ToolsRunningStatus |
        Format-Table -AutoSize
}

if ($PreviewVMs.Count -gt 0 -and $ApplyChanges -eq $false) {
    Write-Host ''
    Write-Host 'Preview mode completed. Set $ApplyChanges = $true and run again to schedule eligible VMs.' -ForegroundColor Cyan
}
