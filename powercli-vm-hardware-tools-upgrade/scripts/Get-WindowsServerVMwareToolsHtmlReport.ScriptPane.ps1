<#
.SYNOPSIS
    Creates an interactive VMware Tools HTML dashboard for Windows Server VMs.

.NOTES
    Paste-ready script-pane version. No param block is required.

    Run Connect-VIServer before running this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==========================================================
# EDITABLE SETTINGS
# ==========================================================

$OutputPath = "C:\Temp\VMwareTools-WindowsServer-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"

# Minimum VMware Tools major version. The vCenter internal Tools version is
# decoded into major, minor, and patch components before this is evaluated.
$MinimumToolsMajorVersion = 13

# Automatically open the HTML report when finished.
$OpenReport = $true

# ==========================================================
# END SETTINGS
# ==========================================================

function ConvertFrom-ToolsInternalVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$RawVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or $RawVersion -eq '0') {
        return $null
    }

    $numericVersion = [uint32]0

    if (-not [uint32]::TryParse($RawVersion, [ref]$numericVersion) -or
        $numericVersion -eq 0 -or
        $numericVersion -eq [int]::MaxValue) {

        return $null
    }

    # VMware encodes x.y.z as (x * 1024) + (y * 32) + z.
    $major = [int]($numericVersion -shr 10)
    $minor = [int](($numericVersion -shr 5) -band 0x1f)
    $patch = [int]($numericVersion -band 0x1f)

    if ($major -lt 1 -or $major -gt 99) {
        return $null
    }

    return [pscustomobject]@{
        InternalVersion = $numericVersion
        Major           = $major
        Minor           = $minor
        Patch           = $patch
        VersionString   = "$major.$minor.$patch"
    }
}

function ConvertTo-ToolsDisplayVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$RawVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or $RawVersion -eq '0') {
        return 'Unknown'
    }

    if ($RawVersion -eq [string][int]::MaxValue) {
        return "Unmanaged ($RawVersion)"
    }

    $versionInfo = ConvertFrom-ToolsInternalVersion -RawVersion $RawVersion

    if ($null -eq $versionInfo) {
        return "Internal version $RawVersion"
    }

    return "$($versionInfo.VersionString) ($RawVersion)"
}

function Get-ToolsCategory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$VersionStatus,

        [AllowNull()]
        [string]$RunningStatus,

        [AllowNull()]
        [string]$RawVersion,

        [AllowNull()]
        [object]$VersionInfo,

        [int]$MinimumMajorVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or
        $RawVersion -eq '0' -or
        $VersionStatus -eq 'guestToolsNotInstalled') {

        return 'Not Installed'
    }

    if ($RunningStatus -ne 'guestToolsRunning') {
        return 'Not Running'
    }

    if ($null -ne $VersionInfo -and $VersionInfo.Major -lt $MinimumMajorVersion) {
        return 'Below Minimum'
    }

    switch ($VersionStatus) {
        'guestToolsCurrent'      { return 'Current' }
        'guestToolsUnmanaged'    { return 'Unmanaged' }
        'guestToolsNeedUpgrade'  { return 'Outdated' }
        'guestToolsSupportedOld' { return 'Supported Old' }
        'guestToolsSupportedNew' { return 'Newer Than Host' }
        'guestToolsTooOld'       { return 'Too Old' }
        'guestToolsTooNew'       { return 'Too New' }
        'guestToolsBlacklisted'  { return 'Blacklisted' }
        default                  { return 'Unknown' }
    }
}

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

function ConvertTo-HtmlText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Value
    )

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    throw 'VMware PowerCLI is not installed. Install the VMware.VimAutomation.Core module first.'
}

$connectedServers = @($global:DefaultVIServers | Where-Object { $_.IsConnected })

if ($connectedServers.Count -eq 0) {
    throw 'No active vCenter connection was found. Run Connect-VIServer first.'
}

Write-Host 'Retrieving VM inventory from vCenter...' -ForegroundColor Cyan

$vmViews = Get-View -ViewType VirtualMachine -Property @(
    'Name',
    'Config.Template',
    'Config.GuestFullName',
    'Config.GuestId',
    'Config.Version',
    'Config.Tools.ToolsUpgradePolicy',
    'Config.ScheduledHardwareUpgradeInfo',
    'Guest.GuestFullName',
    'Guest.HostName',
    'Guest.IpAddress',
    'Guest.ToolsVersion',
    'Guest.ToolsVersionStatus2',
    'Guest.ToolsRunningStatus',
    'Guest.ToolsInstallType',
    'Runtime.PowerState',
    'Runtime.Host'
)

$windowsServerVMs = @(
    $vmViews | Where-Object {
        (-not $_.Config.Template) -and (Test-IsWindowsServerVMView -VMView $_)
    }
)

$hostCache = @{}
$clusterCache = @{}

$reportData = foreach ($vmView in $windowsServerVMs) {
    $hostName = 'Unknown'
    $clusterName = 'Unknown'

    if ($null -ne $vmView.Runtime.Host) {
        $hostKey = $vmView.Runtime.Host.Value

        if (-not $hostCache.ContainsKey($hostKey)) {
            try {
                $hostCache[$hostKey] = Get-View -Id $vmView.Runtime.Host -Property Name, Parent
            }
            catch {
                $hostCache[$hostKey] = $null
            }
        }

        $hostView = $hostCache[$hostKey]

        if ($null -ne $hostView) {
            $hostName = $hostView.Name

            if ($null -ne $hostView.Parent) {
                $parentKey = $hostView.Parent.Value

                if (-not $clusterCache.ContainsKey($parentKey)) {
                    try {
                        $parentView = Get-View -Id $hostView.Parent -Property Name
                        $clusterCache[$parentKey] = $parentView.Name
                    }
                    catch {
                        $clusterCache[$parentKey] = 'Unknown'
                    }
                }

                $clusterName = $clusterCache[$parentKey]
            }
        }
    }

    $rawToolsVersion = [string]$vmView.Guest.ToolsVersion
    $toolsStatus = [string]$vmView.Guest.ToolsVersionStatus2
    $runningStatus = [string]$vmView.Guest.ToolsRunningStatus
    $toolsVersionInfo = ConvertFrom-ToolsInternalVersion -RawVersion $rawToolsVersion

    $category = Get-ToolsCategory `
        -VersionStatus $toolsStatus `
        -RunningStatus $runningStatus `
        -RawVersion $rawToolsVersion `
        -VersionInfo $toolsVersionInfo `
        -MinimumMajorVersion $MinimumToolsMajorVersion

    $scheduledUpgrade = $vmView.Config.ScheduledHardwareUpgradeInfo

    $ipAddress = if ($vmView.Guest.IpAddress) {
        @($vmView.Guest.IpAddress) -join ', '
    }
    else {
        ''
    }

    $reportedOS = if (-not [string]::IsNullOrWhiteSpace($vmView.Guest.GuestFullName)) {
        $vmView.Guest.GuestFullName
    }
    else {
        $vmView.Config.GuestFullName
    }

    [pscustomobject]@{
        VMName               = [string]$vmView.Name
        DNSName              = [string]$vmView.Guest.HostName
        IPAddress            = [string]$ipAddress
        OperatingSystem      = [string]$reportedOS
        PowerState           = [string]$vmView.Runtime.PowerState
        Cluster              = [string]$clusterName
        ESXiHost             = [string]$hostName
        HardwareVersion      = [string]$vmView.Config.Version
        ToolsRawVersion      = [string]$rawToolsVersion
        ToolsSemanticVersion = if ($null -ne $toolsVersionInfo) {
            [string]$toolsVersionInfo.VersionString
        }
        else {
            ''
        }
        ToolsDisplayVersion  = ConvertTo-ToolsDisplayVersion -RawVersion $rawToolsVersion
        ToolsCategory        = [string]$category
        ToolsVersionStatus   = [string]$toolsStatus
        ToolsRunningStatus   = [string]$runningStatus
        ToolsInstallType     = [string]$vmView.Guest.ToolsInstallType
        ToolsUpgradePolicy   = [string]$vmView.Config.Tools.ToolsUpgradePolicy
        MeetsMinimumTools    = (
            $null -ne $toolsVersionInfo -and
            $toolsVersionInfo.Major -ge $MinimumToolsMajorVersion
        )
        ScheduledHWUpgrade   = if ($null -ne $scheduledUpgrade) {
            [string]$scheduledUpgrade.UpgradePolicy
        }
        else {
            'None'
        }
        ScheduledHWTarget    = if ($null -ne $scheduledUpgrade) {
            [string]$scheduledUpgrade.VersionKey
        }
        else {
            ''
        }
    }
}

$reportData = @($reportData | Sort-Object VMName)

$summary = [ordered]@{
    Total           = $reportData.Count
    BelowMinimum    = @($reportData | Where-Object MeetsMinimumTools -eq $false).Count
    NotRunning      = @($reportData | Where-Object ToolsCategory -eq 'Not Running').Count
    NotInstalled    = @($reportData | Where-Object ToolsCategory -eq 'Not Installed').Count
    PoweredOff      = @($reportData | Where-Object PowerState -ne 'poweredOn').Count
    HardwareAt21    = @($reportData | Where-Object HardwareVersion -eq 'vmx-21').Count
    PolicyAlways    = @($reportData | Where-Object ScheduledHWUpgrade -eq 'always').Count
    HardwareBelow21 = @($reportData | Where-Object {
        $_.HardwareVersion -match '^vmx-(\d+)$' -and
        [int]$Matches[1] -lt 21
    }).Count
}

$hardwareAt21Percent = if ($summary['Total'] -gt 0) {
    [int][math]::Round(($summary['HardwareAt21'] / $summary['Total']) * 100)
}
else {
    0
}

$policyAlwaysPercent = if ($summary['Total'] -gt 0) {
    [int][math]::Round(($summary['PolicyAlways'] / $summary['Total']) * 100)
}
else {
    0
}

$jsonData = ConvertTo-Json -InputObject @($reportData) -Depth 6 -Compress
$jsonData = $jsonData -replace '</', '<\/'

$generatedDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$reportTitle = 'Windows Server VMware Tools Dashboard'

$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>__REPORT_TITLE__</title>
<style>
    :root {
        color-scheme: dark;
        --background: #0d1117;
        --panel: #161b22;
        --panel-raised: #1c2128;
        --input: #0f141b;
        --header: #20262f;
        --text: #e6edf3;
        --muted: #9da7b3;
        --border: #30363d;
        --border-strong: #46505c;
        --blue: #58a6ff;
        --green: #3fb950;
        --amber: #d29922;
        --red: #f85149;
        --orange: #f0883e;
        --violet: #a371f7;
        --gray: #8b949e;
        --cyan: #39c5cf;
        --row-hover: #1f2630;
        --chart-track: #30363d;
    }

    * {
        box-sizing: border-box;
        scrollbar-color: #58616d var(--panel);
        scrollbar-width: thin;
    }

    *::-webkit-scrollbar {
        width: 12px;
        height: 12px;
    }

    *::-webkit-scrollbar-track {
        background: var(--panel);
    }

    *::-webkit-scrollbar-thumb {
        background: #58616d;
        border: 3px solid var(--panel);
        border-radius: 8px;
    }

    body {
        margin: 0;
        background: var(--background);
        color: var(--text);
        font-family: "Segoe UI", Arial, sans-serif;
        font-size: 14px;
    }

    [hidden] {
        display: none !important;
    }

    .page {
        width: 100%;
        margin: 0 auto;
        padding: 22px 22px 40px;
    }

    .header {
        margin-bottom: 16px;
    }

    h1 {
        margin: 0 0 6px;
        font-size: 26px;
        font-weight: 700;
        letter-spacing: 0;
    }

    .subtitle {
        color: var(--muted);
    }

    .overview-grid {
        display: grid;
        grid-template-columns: minmax(0, 1.65fr) minmax(370px, 0.85fr);
        gap: 12px;
        margin-bottom: 16px;
    }

    .dashboard {
        display: grid;
        grid-template-columns: repeat(3, minmax(150px, 1fr));
        gap: 10px;
    }

    .card,
    .coverage-item {
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 8px;
        color: var(--text);
        cursor: pointer;
        user-select: none;
        transition: background 0.12s ease, border-color 0.12s ease, box-shadow 0.12s ease;
    }

    .card {
        min-height: 94px;
        padding: 14px;
    }

    .card:hover,
    .coverage-item:hover {
        background: var(--panel-raised);
        border-color: var(--border-strong);
    }

    .card.active,
    .coverage-item.active {
        border-color: var(--blue);
        box-shadow: 0 0 0 3px rgba(88, 166, 255, 0.18);
    }

    .card-label {
        color: var(--muted);
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0;
    }

    .card-value {
        margin-top: 7px;
        font-size: 28px;
        font-weight: 750;
    }

    .blue .card-value { color: var(--blue); }
    .green .card-value { color: var(--green); }
    .amber .card-value { color: var(--amber); }
    .red .card-value { color: var(--red); }
    .orange .card-value { color: var(--orange); }
    .violet .card-value { color: var(--violet); }
    .gray .card-value { color: var(--gray); }

    .coverage-panel {
        display: grid;
        grid-template-columns: 1fr;
        gap: 10px;
    }

    .coverage-item {
        display: grid;
        grid-template-columns: 74px minmax(0, 1fr);
        align-items: center;
        gap: 14px;
        min-height: 89px;
        padding: 9px 14px;
        text-align: left;
        font: inherit;
    }

    .donut {
        --accent: var(--blue);
        --percent: 0;
        position: relative;
        display: grid;
        place-items: center;
        width: 68px;
        aspect-ratio: 1;
        border-radius: 50%;
        background: conic-gradient(
            var(--accent) calc(var(--percent) * 1%),
            var(--chart-track) 0
        );
    }

    .donut::after {
        content: "";
        position: absolute;
        inset: 9px;
        border-radius: 50%;
        background: var(--panel);
    }

    .coverage-item:hover .donut::after {
        background: var(--panel-raised);
    }

    .donut-value {
        position: relative;
        z-index: 1;
        font-size: 15px;
        font-weight: 750;
    }

    .coverage-title {
        display: block;
        font-size: 14px;
        font-weight: 700;
    }

    .coverage-count {
        display: block;
        margin-top: 4px;
        color: var(--muted);
        font-size: 12px;
    }

    .toolbar {
        position: relative;
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 9px;
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 8px 8px 0 0;
        padding: 11px;
    }

    input[type="text"],
    select,
    button:not(.coverage-item):not(.bar-row) {
        border: 1px solid var(--border-strong);
        border-radius: 6px;
        background: var(--input);
        color: var(--text);
        padding: 8px 10px;
        font: inherit;
        min-height: 38px;
    }

    input[type="text"] {
        min-width: 300px;
        flex: 1 1 340px;
    }

    input::placeholder {
        color: #7d8794;
    }

    select {
        min-width: 145px;
    }

    button {
        cursor: pointer;
        font-weight: 650;
    }

    button:not(.coverage-item):not(.bar-row):hover {
        background: #252c35;
    }

    button:focus-visible,
    input:focus-visible,
    select:focus-visible {
        outline: 2px solid var(--blue);
        outline-offset: 2px;
    }

    .column-control,
    .menu-control {
        position: relative;
    }

    .columns-button {
        display: inline-flex;
        align-items: center;
        gap: 8px;
    }

    .columns-icon {
        display: inline-grid;
        grid-template-columns: repeat(3, 3px);
        gap: 2px;
        width: 13px;
        height: 14px;
    }

    .columns-icon::before,
    .columns-icon::after,
    .columns-icon span {
        content: "";
        display: block;
        border-radius: 2px;
        background: currentColor;
    }

    .column-menu {
        position: absolute;
        top: calc(100% + 7px);
        right: 0;
        z-index: 30;
        width: 310px;
        max-height: min(66vh, 570px);
        overflow: auto;
        background: var(--panel-raised);
        border: 1px solid var(--border-strong);
        border-radius: 8px;
        box-shadow: 0 16px 38px rgba(0, 0, 0, 0.42);
    }

    .column-menu-title {
        padding: 12px 13px 9px;
        color: var(--muted);
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
    }

    .column-options {
        display: grid;
        grid-template-columns: 1fr 1fr;
        gap: 2px 8px;
        padding: 0 9px 10px;
    }

    .column-option {
        display: flex;
        align-items: center;
        gap: 8px;
        min-width: 0;
        padding: 7px 5px;
        border-radius: 5px;
        color: var(--text);
        cursor: pointer;
    }

    .column-option:hover {
        background: #252c35;
    }

    .column-option span {
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .column-option input {
        width: 16px;
        height: 16px;
        margin: 0;
        accent-color: var(--blue);
    }

    .column-menu-actions {
        display: flex;
        gap: 8px;
        padding: 10px;
        border-top: 1px solid var(--border);
    }

    .column-menu-actions button {
        flex: 1;
    }

    .action-menu {
        position: absolute;
        top: calc(100% + 7px);
        right: 0;
        z-index: 35;
        width: 300px;
        overflow: hidden;
        background: var(--panel-raised);
        border: 1px solid var(--border-strong);
        border-radius: 8px;
        box-shadow: 0 16px 38px rgba(0, 0, 0, 0.42);
    }

    .action-menu-section {
        padding: 10px;
    }

    .action-menu-section + .action-menu-section {
        border-top: 1px solid var(--border);
    }

    .action-menu-title {
        margin-bottom: 8px;
        color: var(--muted);
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
    }

    .action-menu input[type="text"] {
        width: 100%;
        min-width: 0;
        margin-bottom: 8px;
    }

    .menu-command,
    .saved-view-row {
        display: flex;
        width: 100%;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
    }

    .menu-command {
        margin-top: 5px;
        text-align: left;
    }

    .saved-views-list {
        display: grid;
        gap: 5px;
        max-height: 240px;
        overflow: auto;
    }

    .saved-view-row button:first-child {
        flex: 1;
        min-width: 0;
        overflow: hidden;
        text-align: left;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .saved-view-delete {
        width: 38px;
        flex: 0 0 38px;
        padding: 7px;
        color: var(--red);
        font-size: 18px;
        line-height: 1;
    }

    .empty-state {
        padding: 8px 2px;
        color: var(--muted);
        font-size: 12px;
    }

    .insights-panel {
        margin-bottom: 16px;
        overflow: hidden;
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 8px;
    }

    .insights-header {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 10px;
        padding: 11px 12px;
        border-bottom: 1px solid var(--border);
    }

    .insights-title {
        margin: 0;
        font-size: 15px;
        font-weight: 700;
    }

    .insights-tabs {
        display: inline-flex;
        gap: 2px;
        padding: 3px;
        background: var(--input);
        border: 1px solid var(--border);
        border-radius: 7px;
    }

    .insights-tabs button {
        min-height: 30px;
        padding: 5px 9px;
        border-color: transparent;
        background: transparent;
        color: var(--muted);
    }

    .insights-tabs button.active {
        background: var(--header);
        border-color: var(--border-strong);
        color: var(--text);
    }

    .insights-scope {
        margin-left: auto;
        color: var(--muted);
        font-size: 12px;
    }

    .bar-chart {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));
        gap: 8px 18px;
        min-height: 82px;
        padding: 12px;
    }

    .bar-row {
        display: grid;
        grid-template-columns: minmax(115px, 0.9fr) minmax(130px, 1.7fr) 44px;
        align-items: center;
        gap: 9px;
        width: 100%;
        min-width: 0;
        min-height: 32px;
        padding: 4px 6px;
        border: 1px solid transparent;
        border-radius: 6px;
        background: transparent;
        color: var(--text);
        text-align: left;
    }

    .bar-row:hover,
    .bar-row.active {
        background: var(--panel-raised);
        border-color: var(--border-strong);
    }

    .bar-row.active {
        border-color: var(--blue);
    }

    .bar-label {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .bar-track {
        height: 10px;
        overflow: hidden;
        background: var(--chart-track);
        border-radius: 5px;
    }

    .bar-fill {
        display: block;
        min-width: 3px;
        height: 100%;
        background: var(--cyan);
        border-radius: inherit;
    }

    .bar-count {
        color: var(--muted);
        font-variant-numeric: tabular-nums;
        text-align: right;
    }

    .result-count {
        color: var(--muted);
        margin-left: auto;
        white-space: nowrap;
    }

    .table-container {
        min-height: 330px;
        max-height: 68vh;
        overflow: auto;
        background: var(--panel);
        border: 1px solid var(--border);
        border-top: 0;
        border-radius: 0 0 8px 8px;
    }

    table {
        width: 100%;
        min-width: 100%;
        table-layout: fixed;
        border-collapse: collapse;
        white-space: nowrap;
    }

    th {
        position: sticky;
        top: 0;
        z-index: 3;
        overflow: hidden;
        padding: 10px 19px 10px 10px;
        background: var(--header);
        border-right: 1px solid var(--border);
        border-bottom: 1px solid var(--border-strong);
        color: #dce5ef;
        text-align: left;
        text-overflow: ellipsis;
        cursor: pointer;
        font-weight: 700;
    }

    th:last-child {
        border-right: 0;
    }

    .th-label {
        overflow: hidden;
        text-overflow: ellipsis;
    }

    .sort-indicator {
        margin-left: 5px;
        color: var(--blue);
        font-size: 10px;
    }

    .column-resizer {
        position: absolute;
        top: 0;
        right: -3px;
        bottom: 0;
        z-index: 5;
        width: 9px;
        cursor: col-resize;
        touch-action: none;
    }

    .column-resizer::after {
        content: "";
        position: absolute;
        top: 25%;
        bottom: 25%;
        left: 4px;
        width: 1px;
        background: var(--border-strong);
    }

    .column-resizer:hover::after,
    body.resizing-column .column-resizer::after {
        background: var(--blue);
    }

    body.resizing-column {
        cursor: col-resize;
        user-select: none;
    }

    td {
        overflow: hidden;
        padding: 8px 10px;
        border-right: 1px solid #252b33;
        border-bottom: 1px solid #252b33;
        color: #d7dee7;
        text-overflow: ellipsis;
        vertical-align: middle;
    }

    td:last-child {
        border-right: 0;
    }

    tbody tr:nth-child(even) {
        background: #141920;
    }

    tbody tr:hover {
        background: var(--row-hover);
    }

    #reportTable tbody tr {
        cursor: pointer;
    }

    #reportTable tbody tr:focus-visible {
        outline: 2px solid var(--blue);
        outline-offset: -2px;
    }

    .badge {
        display: inline-block;
        min-width: 86px;
        max-width: 100%;
        overflow: hidden;
        padding: 4px 8px;
        border-radius: 999px;
        font-size: 12px;
        font-weight: 700;
        text-align: center;
        text-overflow: ellipsis;
        vertical-align: middle;
    }

    .status-current {
        color: #78d98b;
        background: #173d25;
    }

    .status-outdated,
    .status-supported-old,
    .status-below-minimum {
        color: #f4b86a;
        background: #4a2c16;
    }

    .status-not-running {
        color: #e7c55b;
        background: #453916;
    }

    .status-not-installed,
    .status-too-old,
    .status-blacklisted {
        color: #ff8b84;
        background: #4b2023;
    }

    .status-unmanaged,
    .status-unknown {
        color: #c2cad4;
        background: #343b44;
    }

    .status-newer-than-host,
    .status-too-new {
        color: #c5a8ff;
        background: #35265a;
    }

    .yes {
        color: #78d98b;
        font-weight: 700;
    }

    .no {
        color: #ff8b84;
        font-weight: 700;
    }

    .scrollbar-dock {
        position: fixed;
        bottom: 0;
        z-index: 50;
        display: none;
        height: 19px;
        overflow-x: scroll;
        overflow-y: hidden;
        background: var(--panel-raised);
        border: 1px solid var(--border-strong);
        border-bottom: 0;
        border-radius: 6px 6px 0 0;
        box-shadow: 0 -5px 18px rgba(0, 0, 0, 0.28);
    }

    .scrollbar-dock.visible {
        display: block;
    }

    .scrollbar-track {
        height: 1px;
    }

    .overlay {
        position: fixed;
        inset: 0;
        z-index: 80;
        background: rgba(0, 0, 0, 0.66);
    }

    .detail-drawer {
        position: fixed;
        top: 0;
        right: 0;
        bottom: 0;
        z-index: 90;
        width: min(520px, 94vw);
        overflow: auto;
        background: var(--panel);
        border-left: 1px solid var(--border-strong);
        box-shadow: -18px 0 44px rgba(0, 0, 0, 0.45);
    }

    .drawer-header,
    .modal-header {
        position: sticky;
        top: 0;
        z-index: 2;
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 14px 16px;
        background: var(--header);
        border-bottom: 1px solid var(--border-strong);
    }

    .drawer-title,
    .modal-title {
        min-width: 0;
        margin: 0;
        overflow: hidden;
        font-size: 18px;
        text-overflow: ellipsis;
        white-space: nowrap;
    }

    .close-button {
        width: 38px;
        margin-left: auto;
        padding: 6px;
        font-size: 22px;
        line-height: 1;
    }

    .drawer-body {
        padding: 14px 16px 28px;
    }

    .detail-section {
        padding: 12px 0;
        border-bottom: 1px solid var(--border);
    }

    .detail-section h3 {
        margin: 0 0 10px;
        color: var(--muted);
        font-size: 12px;
        text-transform: uppercase;
    }

    .detail-grid {
        display: grid;
        grid-template-columns: minmax(120px, 0.7fr) minmax(0, 1.3fr);
        gap: 8px 14px;
    }

    .detail-label {
        color: var(--muted);
    }

    .detail-value {
        min-width: 0;
        overflow-wrap: anywhere;
    }

    .modal-shell {
        position: fixed;
        inset: 5vh 4vw;
        z-index: 90;
        display: flex;
        max-width: 1500px;
        margin: auto;
        flex-direction: column;
        overflow: hidden;
        background: var(--panel);
        border: 1px solid var(--border-strong);
        border-radius: 8px;
        box-shadow: 0 24px 70px rgba(0, 0, 0, 0.58);
    }

    .comparison-summary {
        display: grid;
        grid-template-columns: repeat(4, minmax(110px, 1fr));
        gap: 8px;
        padding: 12px;
        border-bottom: 1px solid var(--border);
    }

    .comparison-metric {
        padding: 10px;
        background: var(--panel-raised);
        border: 1px solid var(--border);
        border-radius: 6px;
    }

    .comparison-metric span {
        display: block;
        color: var(--muted);
        font-size: 12px;
    }

    .comparison-metric strong {
        display: block;
        margin-top: 4px;
        font-size: 21px;
    }

    .comparison-table-wrap {
        flex: 1;
        overflow: auto;
    }

    .comparison-table {
        min-width: 840px;
        table-layout: auto;
    }

    .comparison-table th {
        cursor: default;
    }

    .comparison-table td {
        white-space: normal;
    }

    body.has-overlay {
        overflow: hidden;
    }

    .footer {
        color: var(--muted);
        padding: 14px 2px 4px;
        font-size: 12px;
    }

    @media (max-width: 1200px) {
        .overview-grid {
            grid-template-columns: 1fr;
        }

        .coverage-panel {
            grid-template-columns: 1fr 1fr;
        }
    }

    @media (max-width: 760px) {
        .page {
            padding: 12px 12px 36px;
        }

        .dashboard {
            grid-template-columns: repeat(2, minmax(130px, 1fr));
        }

        .coverage-panel {
            grid-template-columns: 1fr;
        }

        input[type="text"] {
            min-width: 100%;
        }

        .column-menu,
        .action-menu {
            position: fixed;
            top: auto;
            right: 12px;
            bottom: 24px;
            left: 12px;
            z-index: 70;
            width: auto;
            max-height: 70vh;
        }

        .bar-chart {
            grid-template-columns: 1fr;
        }

        .bar-row {
            grid-template-columns: minmax(90px, 0.9fr) minmax(90px, 1.2fr) 40px;
        }

        .insights-scope {
            width: 100%;
            margin-left: 0;
        }

        .comparison-summary {
            grid-template-columns: 1fr 1fr;
        }

        .result-count {
            width: 100%;
            margin-left: 0;
        }

        .table-container {
            max-height: 62vh;
        }
    }

    @media print {
        :root {
            color-scheme: light;
            --background: #ffffff;
            --panel: #ffffff;
            --panel-raised: #ffffff;
            --header: #e9edf2;
            --text: #111827;
            --muted: #4b5563;
            --border: #c7cdd4;
            --border-strong: #9ca3af;
        }

        body {
            background: #ffffff;
            color: #111827;
            font-size: 10px;
        }

        .page {
            padding: 0;
        }

        .toolbar,
        .scrollbar-dock,
        .overlay,
        .detail-drawer,
        .modal-shell,
        .footer {
            display: none !important;
        }

        .overview-grid,
        .insights-panel {
            break-inside: avoid;
        }

        .card,
        .coverage-item,
        .comparison-metric {
            color: #111827;
            box-shadow: none;
        }

        .table-container {
            min-height: 0;
            max-height: none;
            overflow: visible;
            border-top: 1px solid var(--border);
        }

        table {
            width: 100% !important;
        }

        th {
            position: static;
            background: #e9edf2;
            color: #111827;
        }

        td {
            color: #111827;
        }

        .column-resizer {
            display: none;
        }
    }
</style>
</head>
<body>
<div class="page">
    <div class="header">
        <h1>__REPORT_TITLE__</h1>
        <div class="subtitle">
            Generated __GENERATED_DATE__ | Minimum VMware Tools generation: __MINIMUM_TOOLS_MAJOR__.0
        </div>
    </div>

    <div class="overview-grid">
        <div class="dashboard">
            <div class="card blue active" data-filter="all" tabindex="0" role="button">
                <div class="card-label">Total Servers</div>
                <div class="card-value">__SUMMARY_TOTAL__</div>
            </div>

            <div class="card red" data-filter="belowminimum" tabindex="0" role="button">
                <div class="card-label">Below __MINIMUM_TOOLS_MAJOR__.0</div>
                <div class="card-value">__SUMMARY_BELOW_MINIMUM__</div>
            </div>

            <div class="card amber" data-filter="notrunning" tabindex="0" role="button">
                <div class="card-label">Tools Not Running</div>
                <div class="card-value">__SUMMARY_NOT_RUNNING__</div>
            </div>

            <div class="card red" data-filter="notinstalled" tabindex="0" role="button">
                <div class="card-label">Not Installed</div>
                <div class="card-value">__SUMMARY_NOT_INSTALLED__</div>
            </div>

            <div class="card gray" data-filter="poweredoff" tabindex="0" role="button">
                <div class="card-label">Powered Off</div>
                <div class="card-value">__SUMMARY_POWERED_OFF__</div>
            </div>

            <div class="card violet" data-filter="hardwarebelow21" tabindex="0" role="button">
                <div class="card-label">Hardware Below 21</div>
                <div class="card-value">__SUMMARY_HARDWARE_BELOW_21__</div>
            </div>
        </div>

        <div class="coverage-panel">
            <button class="coverage-item" type="button" data-filter="hardware21">
                <span class="donut" style="--percent: __HARDWARE_AT_21_PERCENT__; --accent: var(--green);">
                    <span class="donut-value">__HARDWARE_AT_21_PERCENT__%</span>
                </span>
                <span>
                    <span class="coverage-title">VM hardware 21</span>
                    <span class="coverage-count">__SUMMARY_HARDWARE_AT_21__ of __SUMMARY_TOTAL__ servers</span>
                </span>
            </button>

            <button class="coverage-item" type="button" data-filter="policyalways">
                <span class="donut" style="--percent: __POLICY_ALWAYS_PERCENT__; --accent: var(--cyan);">
                    <span class="donut-value">__POLICY_ALWAYS_PERCENT__%</span>
                </span>
                <span>
                    <span class="coverage-title">HW upgrade policy: always</span>
                    <span class="coverage-count">__SUMMARY_POLICY_ALWAYS__ of __SUMMARY_TOTAL__ servers</span>
                </span>
            </button>
        </div>
    </div>

    <section class="insights-panel" aria-labelledby="insightsTitle">
        <div class="insights-header">
            <h2 class="insights-title" id="insightsTitle">Inventory breakdown</h2>
            <div class="insights-tabs" role="tablist" aria-label="Inventory grouping">
                <button class="active" type="button" role="tab" aria-selected="true" data-insight-key="Cluster">Cluster</button>
                <button type="button" role="tab" aria-selected="false" data-insight-key="OperatingSystem">Operating system</button>
                <button type="button" role="tab" aria-selected="false" data-insight-key="ToolsSemanticVersion">Tools version</button>
            </div>
            <span class="insights-scope" id="insightsScope"></span>
        </div>
        <div class="bar-chart" id="insightsChart"></div>
    </section>

    <div class="toolbar">
        <input id="searchBox" type="text" placeholder="Search VM, OS, cluster, ESXi host, IP, Tools version...">

        <select id="clusterFilter">
            <option value="">All clusters</option>
        </select>

        <select id="powerFilter">
            <option value="">All power states</option>
            <option value="poweredOn">Powered on</option>
            <option value="poweredOff">Powered off</option>
            <option value="suspended">Suspended</option>
        </select>

        <button id="clearButton" type="button">Clear</button>

        <div class="menu-control" id="viewsControl">
            <button id="viewsButton" type="button" aria-expanded="false" aria-controls="viewsMenu">Views</button>
            <div class="action-menu" id="viewsMenu" hidden>
                <div class="action-menu-section">
                    <div class="action-menu-title">Save current view</div>
                    <input id="savedViewName" type="text" maxlength="60" placeholder="View name">
                    <button class="menu-command" id="saveViewButton" type="button">Save view</button>
                </div>
                <div class="action-menu-section">
                    <div class="action-menu-title">Saved views</div>
                    <div class="saved-views-list" id="savedViewsList"></div>
                </div>
            </div>
        </div>

        <div class="menu-control" id="exportControl">
            <button id="exportButton" type="button" aria-expanded="false" aria-controls="exportMenu">Export</button>
            <div class="action-menu" id="exportMenu" hidden>
                <div class="action-menu-section">
                    <button class="menu-command" id="visibleCsvButton" type="button">Visible columns CSV</button>
                    <button class="menu-command" id="fullCsvButton" type="button">Full filtered CSV</button>
                    <button class="menu-command" id="snapshotButton" type="button">Inventory snapshot JSON</button>
                </div>
            </div>
        </div>

        <button id="compareButton" type="button">Compare</button>
        <input id="compareFileInput" type="file" accept=".json,.html,.htm,application/json,text/html" hidden>
        <button id="printButton" type="button">Print</button>

        <div class="column-control" id="columnControl">
            <button class="columns-button" id="columnsButton" type="button" aria-expanded="false" aria-controls="columnsMenu">
                <span class="columns-icon" aria-hidden="true"><span></span></span>
                <span id="columnsButtonLabel">Columns</span>
            </button>

            <div class="column-menu" id="columnsMenu" hidden>
                <div class="column-menu-title">Visible columns</div>
                <div class="column-options" id="columnOptions"></div>
                <div class="column-menu-actions">
                    <button id="showAllColumnsButton" type="button">Show all</button>
                    <button id="resetColumnsButton" type="button">Reset</button>
                </div>
            </div>
        </div>

        <span class="result-count" id="resultCount"></span>
    </div>

    <div class="table-container" id="tableContainer">
        <table id="reportTable">
            <colgroup id="tableColumns"></colgroup>
            <thead>
                <tr id="tableHeaderRow"></tr>
            </thead>
            <tbody></tbody>
        </table>
    </div>

    <div class="scrollbar-dock" id="scrollbarDock" aria-hidden="true">
        <div class="scrollbar-track" id="scrollbarTrack"></div>
    </div>

    <div class="footer">
        Tools version is reported from vCenter. Validate critical systems independently before using the report as an upgrade approval source.
    </div>
</div>

<div class="overlay" id="drawerOverlay" hidden></div>
<aside class="detail-drawer" id="detailDrawer" aria-labelledby="detailTitle" hidden>
    <div class="drawer-header">
        <h2 class="drawer-title" id="detailTitle">VM details</h2>
        <button class="close-button" id="closeDetailButton" type="button" aria-label="Close details">&times;</button>
    </div>
    <div class="drawer-body" id="detailBody"></div>
</aside>

<div class="overlay" id="comparisonOverlay" hidden></div>
<section class="modal-shell" id="comparisonModal" aria-labelledby="comparisonTitle" hidden>
    <div class="modal-header">
        <h2 class="modal-title" id="comparisonTitle">Inventory comparison</h2>
        <button class="close-button" id="closeComparisonButton" type="button" aria-label="Close comparison">&times;</button>
    </div>
    <div class="comparison-summary" id="comparisonSummary"></div>
    <div class="comparison-table-wrap">
        <table class="comparison-table">
            <thead>
                <tr>
                    <th>VM Name</th>
                    <th>Change</th>
                    <th>Field</th>
                    <th>Previous</th>
                    <th>Current</th>
                </tr>
            </thead>
            <tbody id="comparisonBody"></tbody>
        </table>
    </div>
</section>

<script id="reportSnapshotData" type="application/json">__JSON_DATA__</script>
<script>
const reportData = JSON.parse(document.getElementById("reportSnapshotData").textContent);
const reportGeneratedAt = "__GENERATED_DATE__";
const reportMinimumToolsMajor = __MINIMUM_TOOLS_MAJOR__;

let activeCardFilter = "all";
let sortColumn = "VMName";
let sortAscending = true;
let synchronizingScroll = false;
let activeInsightKey = "Cluster";
let activeGroupFilter = null;

const columnPreferenceKey = "vmware-tools-dashboard-columns-v2";
const savedViewsKey = "vmware-tools-dashboard-saved-views-v1";
const columnDefinitions = [
    { key: "VMName", label: "VM Name", defaultWidth: 170, minWidth: 110, defaultVisible: true },
    { key: "DNSName", label: "DNS Name", defaultWidth: 190, minWidth: 120, defaultVisible: false },
    { key: "OperatingSystem", label: "Operating System", defaultWidth: 240, minWidth: 150, defaultVisible: true },
    { key: "PowerState", label: "Power", defaultWidth: 110, minWidth: 85, defaultVisible: true },
    { key: "Cluster", label: "Cluster", defaultWidth: 170, minWidth: 110, defaultVisible: true },
    { key: "ESXiHost", label: "ESXi Host", defaultWidth: 190, minWidth: 120, defaultVisible: false },
    { key: "HardwareVersion", label: "HW Version", defaultWidth: 115, minWidth: 90, defaultVisible: true },
    { key: "ToolsDisplayVersion", label: "Tools Version", defaultWidth: 180, minWidth: 120, defaultVisible: true },
    { key: "ToolsCategory", label: "Tools State", defaultWidth: 140, minWidth: 110, defaultVisible: true },
    { key: "ToolsRunningStatus", label: "Running State", defaultWidth: 175, minWidth: 120, defaultVisible: true },
    { key: "ToolsInstallType", label: "Install Type", defaultWidth: 125, minWidth: 95, defaultVisible: false },
    { key: "ToolsUpgradePolicy", label: "Tools Policy", defaultWidth: 135, minWidth: 100, defaultVisible: false },
    { key: "MeetsMinimumTools", label: "Meets Minimum", defaultWidth: 135, minWidth: 105, defaultVisible: true },
    { key: "ScheduledHWUpgrade", label: "HW Upgrade Policy", defaultWidth: 150, minWidth: 115, defaultVisible: true },
    { key: "ScheduledHWTarget", label: "HW Target", defaultWidth: 110, minWidth: 85, defaultVisible: false },
    { key: "IPAddress", label: "IP Address", defaultWidth: 220, minWidth: 130, defaultVisible: false }
].map(column => ({
    ...column,
    width: column.defaultWidth,
    visible: column.defaultVisible
}));

const reportTable = document.getElementById("reportTable");
const tableBody = document.querySelector("#reportTable tbody");
const tableColumns = document.getElementById("tableColumns");
const tableHeaderRow = document.getElementById("tableHeaderRow");
const tableContainer = document.getElementById("tableContainer");
const scrollbarDock = document.getElementById("scrollbarDock");
const scrollbarTrack = document.getElementById("scrollbarTrack");
const searchBox = document.getElementById("searchBox");
const clusterFilter = document.getElementById("clusterFilter");
const powerFilter = document.getElementById("powerFilter");
const resultCount = document.getElementById("resultCount");
const columnControl = document.getElementById("columnControl");
const columnsButton = document.getElementById("columnsButton");
const columnsButtonLabel = document.getElementById("columnsButtonLabel");
const columnsMenu = document.getElementById("columnsMenu");
const columnOptions = document.getElementById("columnOptions");
const insightsChart = document.getElementById("insightsChart");
const insightsScope = document.getElementById("insightsScope");
const viewsControl = document.getElementById("viewsControl");
const viewsButton = document.getElementById("viewsButton");
const viewsMenu = document.getElementById("viewsMenu");
const savedViewName = document.getElementById("savedViewName");
const savedViewsList = document.getElementById("savedViewsList");
const exportControl = document.getElementById("exportControl");
const exportButton = document.getElementById("exportButton");
const exportMenu = document.getElementById("exportMenu");
const compareFileInput = document.getElementById("compareFileInput");
const detailDrawer = document.getElementById("detailDrawer");
const drawerOverlay = document.getElementById("drawerOverlay");
const detailTitle = document.getElementById("detailTitle");
const detailBody = document.getElementById("detailBody");
const comparisonModal = document.getElementById("comparisonModal");
const comparisonOverlay = document.getElementById("comparisonOverlay");
const comparisonSummary = document.getElementById("comparisonSummary");
const comparisonBody = document.getElementById("comparisonBody");

function htmlEncode(value) {
    return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#039;");
}

function classNameFromStatus(value) {
    return "status-" + String(value ?? "unknown").toLowerCase().replaceAll(" ", "-");
}

function downloadTextFile(fileName, content, contentType) {
    const blob = new Blob([content], { type: contentType });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");

    link.href = url;
    link.download = fileName;
    document.body.appendChild(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 0);
}

function closeMenus(exceptMenu = null) {
    for (const [menu, button] of [
        [columnsMenu, columnsButton],
        [viewsMenu, viewsButton],
        [exportMenu, exportButton]
    ]) {
        if (menu !== exceptMenu) {
            menu.hidden = true;
            button.setAttribute("aria-expanded", "false");
        }
    }
}

function toggleMenu(menu, button) {
    const shouldOpen = menu.hidden;
    closeMenus(menu);
    menu.hidden = !shouldOpen;
    button.setAttribute("aria-expanded", String(shouldOpen));
}

function setDashboardFilter(filterName) {
    activeCardFilter = filterName || "all";
    document.querySelectorAll("[data-filter]").forEach(item => {
        item.classList.toggle("active", item.dataset.filter === activeCardFilter);
    });
}

function populateClusterFilter() {
    const clusters = [...new Set(reportData.map(item => item.Cluster).filter(Boolean))].sort();

    for (const cluster of clusters) {
        const option = document.createElement("option");
        option.value = cluster;
        option.textContent = cluster;
        clusterFilter.appendChild(option);
    }
}

function getVisibleColumns() {
    return columnDefinitions.filter(column => column.visible);
}

function loadColumnPreferences() {
    try {
        const saved = JSON.parse(localStorage.getItem(columnPreferenceKey));

        if (!saved || typeof saved !== "object") {
            return;
        }

        for (const column of columnDefinitions) {
            const preference = saved[column.key];

            if (!preference) {
                continue;
            }

            if (typeof preference.visible === "boolean") {
                column.visible = preference.visible;
            }

            if (Number.isFinite(preference.width)) {
                column.width = Math.max(column.minWidth, preference.width);
            }
        }

        if (getVisibleColumns().length === 0) {
            columnDefinitions[0].visible = true;
        }
    }
    catch {
        // Some file:// browser configurations disable local storage.
    }
}

function saveColumnPreferences() {
    try {
        const preferences = Object.fromEntries(
            columnDefinitions.map(column => [
                column.key,
                { visible: column.visible, width: column.width }
            ])
        );

        localStorage.setItem(columnPreferenceKey, JSON.stringify(preferences));
    }
    catch {
        // The report remains fully functional without saved preferences.
    }
}

function loadSavedViews() {
    try {
        const value = JSON.parse(localStorage.getItem(savedViewsKey));
        return Array.isArray(value) ? value : [];
    }
    catch {
        return [];
    }
}

function storeSavedViews(views) {
    try {
        localStorage.setItem(savedViewsKey, JSON.stringify(views));
        return true;
    }
    catch {
        return false;
    }
}

function captureViewState() {
    return {
        search: searchBox.value,
        cluster: clusterFilter.value,
        power: powerFilter.value,
        cardFilter: activeCardFilter,
        insightKey: activeInsightKey,
        groupFilter: activeGroupFilter,
        sortColumn,
        sortAscending,
        columns: Object.fromEntries(columnDefinitions.map(column => [
            column.key,
            { visible: column.visible, width: column.width }
        ]))
    };
}

function applyViewState(state) {
    if (!state || typeof state !== "object") {
        return;
    }

    searchBox.value = state.search || "";
    clusterFilter.value = [...clusterFilter.options].some(option => option.value === state.cluster)
        ? state.cluster
        : "";
    powerFilter.value = [...powerFilter.options].some(option => option.value === state.power)
        ? state.power
        : "";
    sortColumn = columnDefinitions.some(column => column.key === state.sortColumn)
        ? state.sortColumn
        : "VMName";
    sortAscending = state.sortAscending !== false;
    activeInsightKey = ["Cluster", "OperatingSystem", "ToolsSemanticVersion"].includes(state.insightKey)
        ? state.insightKey
        : "Cluster";
    activeGroupFilter = state.groupFilter && state.groupFilter.key && state.groupFilter.value
        ? state.groupFilter
        : null;
    setDashboardFilter(state.cardFilter);

    if (state.columns && typeof state.columns === "object") {
        columnDefinitions.forEach(column => {
            const savedColumn = state.columns[column.key];

            if (savedColumn && typeof savedColumn.visible === "boolean") {
                column.visible = savedColumn.visible;
            }

            if (savedColumn && Number.isFinite(savedColumn.width)) {
                column.width = Math.max(column.minWidth, savedColumn.width);
            }
        });
    }

    if (getVisibleColumns().length === 0) {
        columnDefinitions[0].visible = true;
    }

    document.querySelectorAll("[data-insight-key]").forEach(tab => {
        const isActive = tab.dataset.insightKey === activeInsightKey;
        tab.classList.toggle("active", isActive);
        tab.setAttribute("aria-selected", String(isActive));
    });

    saveColumnPreferences();
    buildTableColumns();
}

function renderSavedViews() {
    const views = loadSavedViews();

    if (views.length === 0) {
        savedViewsList.innerHTML = '<div class="empty-state">No saved views</div>';
        return;
    }

    savedViewsList.innerHTML = views.map(view => `
        <div class="saved-view-row">
            <button type="button" data-view-id="${htmlEncode(view.id)}" title="${htmlEncode(view.name)}">${htmlEncode(view.name)}</button>
            <button class="saved-view-delete" type="button" data-delete-view-id="${htmlEncode(view.id)}" aria-label="Delete ${htmlEncode(view.name)}">&times;</button>
        </div>
    `).join("");

    savedViewsList.querySelectorAll("[data-view-id]").forEach(button => {
        button.addEventListener("click", () => {
            const selected = loadSavedViews().find(view => view.id === button.dataset.viewId);

            if (selected) {
                applyViewState(selected.state);
                closeMenus();
            }
        });
    });

    savedViewsList.querySelectorAll("[data-delete-view-id]").forEach(button => {
        button.addEventListener("click", () => {
            const updated = loadSavedViews().filter(view => view.id !== button.dataset.deleteViewId);
            storeSavedViews(updated);
            renderSavedViews();
        });
    });
}

function saveCurrentView() {
    const name = savedViewName.value.trim();

    if (!name) {
        savedViewName.focus();
        return;
    }

    const views = loadSavedViews();
    const existing = views.find(view => view.name.toLowerCase() === name.toLowerCase());
    const savedView = {
        id: existing ? existing.id : `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        name,
        state: captureViewState()
    };
    const updated = existing
        ? views.map(view => view.id === existing.id ? savedView : view)
        : [...views, savedView];

    if (!storeSavedViews(updated)) {
        alert("This browser did not allow the report to save views locally.");
        return;
    }

    savedViewName.value = "";
    renderSavedViews();
}

function updateColumnMenu() {
    const visibleCount = getVisibleColumns().length;
    columnsButtonLabel.textContent = `Columns (${visibleCount}/${columnDefinitions.length})`;

    columnOptions.innerHTML = columnDefinitions.map(column => `
        <label class="column-option" title="${htmlEncode(column.label)}">
            <input type="checkbox" data-column="${column.key}" ${column.visible ? "checked" : ""}>
            <span>${htmlEncode(column.label)}</span>
        </label>
    `).join("");

    columnOptions.querySelectorAll('input[type="checkbox"]').forEach(checkbox => {
        checkbox.addEventListener("change", () => {
            const column = columnDefinitions.find(item => item.key === checkbox.dataset.column);

            if (!column) {
                return;
            }

            if (!checkbox.checked && getVisibleColumns().length === 1) {
                checkbox.checked = true;
                return;
            }

            column.visible = checkbox.checked;
            saveColumnPreferences();
            buildTableColumns();
        });
    });
}

function refreshTableWidth() {
    const visibleWidth = getVisibleColumns().reduce((total, column) => total + column.width, 0);
    reportTable.style.width = `${Math.max(visibleWidth, tableContainer.clientWidth)}px`;
}

function updateSortIndicators() {
    tableHeaderRow.querySelectorAll("th[data-column]").forEach(header => {
        const indicator = header.querySelector(".sort-indicator");
        const isSorted = header.dataset.column === sortColumn;

        header.setAttribute(
            "aria-sort",
            isSorted ? (sortAscending ? "ascending" : "descending") : "none"
        );

        indicator.innerHTML = isSorted
            ? (sortAscending ? "&#9650;" : "&#9660;")
            : "";
    });
}

function wireHeaderInteractions() {
    tableHeaderRow.querySelectorAll("th[data-column]").forEach(header => {
        header.addEventListener("click", event => {
            if (event.target.closest(".column-resizer")) {
                return;
            }

            const selectedColumn = header.dataset.column;

            if (sortColumn === selectedColumn) {
                sortAscending = !sortAscending;
            }
            else {
                sortColumn = selectedColumn;
                sortAscending = true;
            }

            updateSortIndicators();
            renderTable();
        });

        const resizer = header.querySelector(".column-resizer");

        resizer.addEventListener("pointerdown", event => {
            event.preventDefault();
            event.stopPropagation();

            const column = columnDefinitions.find(item => item.key === header.dataset.column);

            if (!column) {
                return;
            }

            const startX = event.clientX;
            const startWidth = column.width;
            document.body.classList.add("resizing-column");

            const handleMove = moveEvent => {
                column.width = Math.max(column.minWidth, startWidth + moveEvent.clientX - startX);
                const col = tableColumns.querySelector(`col[data-column="${column.key}"]`);

                if (col) {
                    col.style.width = `${column.width}px`;
                }

                refreshTableWidth();
                updateScrollbarDock();
            };

            const handleUp = () => {
                document.body.classList.remove("resizing-column");
                window.removeEventListener("pointermove", handleMove);
                window.removeEventListener("pointerup", handleUp);
                saveColumnPreferences();
            };

            window.addEventListener("pointermove", handleMove);
            window.addEventListener("pointerup", handleUp);
        });

        resizer.addEventListener("dblclick", event => {
            event.preventDefault();
            event.stopPropagation();

            const column = columnDefinitions.find(item => item.key === header.dataset.column);

            if (column) {
                column.width = column.defaultWidth;
                saveColumnPreferences();
                buildTableColumns();
            }
        });
    });
}

function buildTableColumns() {
    const visibleColumns = getVisibleColumns();

    tableColumns.innerHTML = visibleColumns.map(column =>
        `<col data-column="${column.key}" style="width: ${column.width}px;">`
    ).join("");

    tableHeaderRow.innerHTML = visibleColumns.map(column => `
        <th data-column="${column.key}" title="${htmlEncode(column.label)}" aria-sort="none">
            <span class="th-label">${htmlEncode(column.label)}</span>
            <span class="sort-indicator" aria-hidden="true"></span>
            <span class="column-resizer" title="Resize ${htmlEncode(column.label)}" aria-hidden="true"></span>
        </th>
    `).join("");

    updateColumnMenu();
    wireHeaderInteractions();
    updateSortIndicators();
    refreshTableWidth();
    renderTable();
}

function matchesCardFilter(item) {
    switch (activeCardFilter) {
        case "belowminimum":
            return item.MeetsMinimumTools !== true;

        case "notrunning":
            return item.ToolsCategory === "Not Running";

        case "notinstalled":
            return item.ToolsCategory === "Not Installed";

        case "poweredoff":
            return item.PowerState !== "poweredOn";

        case "hardwarebelow21": {
            const match = String(item.HardwareVersion).match(/^vmx-(\d+)$/);
            return match && Number(match[1]) < 21;
        }

        case "hardware21":
            return item.HardwareVersion === "vmx-21";

        case "policyalways":
            return String(item.ScheduledHWUpgrade).toLowerCase() === "always";

        default:
            return true;
    }
}

function getBaseFilteredData() {
    const searchText = searchBox.value.trim().toLowerCase();
    const selectedCluster = clusterFilter.value;
    const selectedPower = powerFilter.value;

    return reportData
        .filter(item => matchesCardFilter(item))
        .filter(item => !selectedCluster || item.Cluster === selectedCluster)
        .filter(item => !selectedPower || item.PowerState === selectedPower)
        .filter(item => {
            if (!searchText) {
                return true;
            }

            return Object.values(item).some(value =>
                String(value ?? "").toLowerCase().includes(searchText)
            );
        });
}

function getFilteredData() {
    return getBaseFilteredData()
        .filter(item => !activeGroupFilter ||
            String(item[activeGroupFilter.key] || "Unknown") === activeGroupFilter.value)
        .sort((a, b) => {
            const left = a[sortColumn] ?? "";
            const right = b[sortColumn] ?? "";

            return String(left).localeCompare(
                String(right),
                undefined,
                { numeric: true, sensitivity: "base" }
            ) * (sortAscending ? 1 : -1);
        });
}

function renderInsights() {
    const data = getBaseFilteredData();
    const counts = new Map();

    data.forEach(item => {
        const value = String(item[activeInsightKey] || "Unknown");
        counts.set(value, (counts.get(value) || 0) + 1);
    });

    const sorted = [...counts.entries()].sort((left, right) =>
        right[1] - left[1] || left[0].localeCompare(right[0], undefined, { numeric: true })
    );
    const displayed = sorted.slice(0, 12);
    const remainingCount = sorted.slice(12).reduce((total, item) => total + item[1], 0);
    const maximum = Math.max(1, ...displayed.map(item => item[1]));

    if (remainingCount > 0) {
        displayed.push(["Other", remainingCount]);
    }

    insightsScope.textContent = activeGroupFilter
        ? `${data.length.toLocaleString()} servers | selected: ${activeGroupFilter.value}`
        : `${data.length.toLocaleString()} servers in current filter`;

    if (displayed.length === 0) {
        insightsChart.innerHTML = '<div class="empty-state">No data in the current filter</div>';
        return;
    }

    insightsChart.innerHTML = displayed.map(([label, count]) => {
        const isOther = label === "Other" && remainingCount > 0;
        const isActive = !isOther && activeGroupFilter &&
            activeGroupFilter.key === activeInsightKey && activeGroupFilter.value === label;
        const width = Math.max(2, Math.round((count / maximum) * 100));

        return `
            <button class="bar-row ${isActive ? "active" : ""}" type="button"
                    data-group-value="${isOther ? "" : htmlEncode(label)}"
                    ${isOther ? "disabled" : ""} title="${htmlEncode(label)}: ${count}">
                <span class="bar-label">${htmlEncode(label)}</span>
                <span class="bar-track"><span class="bar-fill" style="width: ${width}%"></span></span>
                <span class="bar-count">${count.toLocaleString()}</span>
            </button>
        `;
    }).join("");

    insightsChart.querySelectorAll("[data-group-value]:not([disabled])").forEach(button => {
        button.addEventListener("click", () => {
            const sameFilter = activeGroupFilter &&
                activeGroupFilter.key === activeInsightKey &&
                activeGroupFilter.value === button.dataset.groupValue;
            activeGroupFilter = sameFilter
                ? null
                : { key: activeInsightKey, value: button.dataset.groupValue };
            renderTable();
        });
    });
}

function getDisplayValue(item, columnKey) {
    if (columnKey === "MeetsMinimumTools") {
        return item.MeetsMinimumTools ? "Yes" : "No";
    }

    return item[columnKey] ?? "";
}

function renderCell(item, column) {
    const displayValue = getDisplayValue(item, column.key);
    let content = htmlEncode(displayValue);
    let title = htmlEncode(displayValue);

    switch (column.key) {
        case "VMName":
            content = `<strong>${htmlEncode(item.VMName)}</strong>`;
            break;

        case "ToolsDisplayVersion":
            title = `Raw value: ${htmlEncode(item.ToolsRawVersion)}`;
            break;

        case "ToolsCategory":
            content = `<span class="badge ${classNameFromStatus(item.ToolsCategory)}">${htmlEncode(item.ToolsCategory)}</span>`;
            break;

        case "MeetsMinimumTools":
            content = `<span class="${item.MeetsMinimumTools ? "yes" : "no"}">${item.MeetsMinimumTools ? "Yes" : "No"}</span>`;
            break;
    }

    return `<td data-column="${column.key}" title="${title}">${content}</td>`;
}

function renderTable() {
    const filteredData = getFilteredData();
    const visibleColumns = getVisibleColumns();

    tableBody.innerHTML = filteredData.map(item => `
        <tr tabindex="0" data-vm-name="${htmlEncode(item.VMName)}" aria-label="View details for ${htmlEncode(item.VMName)}">
            ${visibleColumns.map(column => renderCell(item, column)).join("")}
        </tr>
    `).join("");

    resultCount.textContent =
        `${filteredData.length.toLocaleString()} of ${reportData.length.toLocaleString()} servers`;

    renderInsights();
    requestAnimationFrame(updateScrollbarDock);
}

function exportCsv(columns, fileName) {
    const data = getFilteredData();

    if (data.length === 0) {
        alert("There are no rows to export.");
        return;
    }

    const escapeCsv = value => '"' + String(value ?? "").replaceAll('"', '""') + '"';
    const csv = [
        columns.map(column => escapeCsv(column.label)).join(","),
        ...data.map(row => columns.map(column => escapeCsv(getDisplayValue(row, column.key))).join(","))
    ].join("\r\n");

    downloadTextFile(fileName, csv, "text/csv;charset=utf-8;");
}

function exportVisibleCsv() {
    exportCsv(getVisibleColumns(), "VMwareTools-Visible-Filtered.csv");
}

function exportFullCsv() {
    const sample = getFilteredData()[0];

    if (!sample) {
        alert("There are no rows to export.");
        return;
    }

    const columns = Object.keys(sample).map(key => ({ key, label: key }));
    exportCsv(columns, "VMwareTools-Full-Filtered.csv");
}

function exportSnapshot() {
    const snapshot = {
        schema: "NCSTA.VMwareToolsDashboardSnapshot/1",
        generatedAt: reportGeneratedAt,
        minimumToolsMajorVersion: reportMinimumToolsMajor,
        rowCount: reportData.length,
        rows: reportData
    };

    const stamp = reportGeneratedAt.replaceAll(/[^0-9]/g, "").slice(0, 14) || "snapshot";
    downloadTextFile(
        `VMwareTools-Snapshot-${stamp}.json`,
        JSON.stringify(snapshot, null, 2),
        "application/json;charset=utf-8;"
    );
}

function detailRows(item, keys) {
    return keys.map(([key, label]) => `
        <div class="detail-label">${htmlEncode(label)}</div>
        <div class="detail-value">${htmlEncode(getDisplayValue(item, key) || "Not reported")}</div>
    `).join("");
}

function detailSection(title, item, keys) {
    return `
        <section class="detail-section">
            <h3>${htmlEncode(title)}</h3>
            <div class="detail-grid">${detailRows(item, keys)}</div>
        </section>
    `;
}

function updateOverlayState() {
    document.body.classList.toggle(
        "has-overlay",
        !detailDrawer.hidden || !comparisonModal.hidden
    );
}

function openVmDetails(item) {
    if (!item) {
        return;
    }

    detailTitle.textContent = item.VMName || "VM details";
    detailBody.innerHTML = [
        detailSection("Identity", item, [
            ["VMName", "VM name"],
            ["DNSName", "DNS name"],
            ["IPAddress", "IP address"],
            ["OperatingSystem", "Operating system"]
        ]),
        detailSection("Virtualization", item, [
            ["PowerState", "Power state"],
            ["Cluster", "Cluster"],
            ["ESXiHost", "ESXi host"],
            ["HardwareVersion", "Hardware version"]
        ]),
        detailSection("VMware Tools", item, [
            ["ToolsDisplayVersion", "Tools version"],
            ["ToolsRawVersion", "Internal version"],
            ["ToolsCategory", "Tools state"],
            ["ToolsVersionStatus", "Version status"],
            ["ToolsRunningStatus", "Running status"],
            ["ToolsInstallType", "Install type"],
            ["ToolsUpgradePolicy", "Upgrade policy"],
            ["MeetsMinimumTools", "Meets minimum"]
        ]),
        detailSection("Scheduled hardware upgrade", item, [
            ["ScheduledHWUpgrade", "Upgrade policy"],
            ["ScheduledHWTarget", "Target version"]
        ])
    ].join("");

    drawerOverlay.hidden = false;
    detailDrawer.hidden = false;
    updateOverlayState();
    document.getElementById("closeDetailButton").focus();
}

function closeVmDetails() {
    drawerOverlay.hidden = true;
    detailDrawer.hidden = true;
    updateOverlayState();
}

function normalizeSnapshotRows(payload) {
    if (Array.isArray(payload)) {
        return payload;
    }

    if (payload && Array.isArray(payload.rows)) {
        return payload.rows;
    }

    if (payload && Array.isArray(payload.reportData)) {
        return payload.reportData;
    }

    throw new Error("The selected file does not contain a VMware Tools report inventory.");
}

function parseSnapshotText(text, fileName) {
    if (/\.html?$/i.test(fileName) || /^\s*<!doctype html/i.test(text)) {
        const documentFromFile = new DOMParser().parseFromString(text, "text/html");
        const embedded = documentFromFile.getElementById("reportSnapshotData");

        if (embedded) {
            return normalizeSnapshotRows(JSON.parse(embedded.textContent));
        }

        const legacyMatch = text.match(/const\s+reportData\s*=\s*(\[[\s\S]*?\]);/);

        if (legacyMatch) {
            return normalizeSnapshotRows(JSON.parse(legacyMatch[1]));
        }

        throw new Error("No embedded inventory was found in the selected HTML report.");
    }

    return normalizeSnapshotRows(JSON.parse(text));
}

function comparableValue(item, key) {
    if (!item) {
        return "";
    }

    if (key === "ToolsSemanticVersion") {
        return String(item.ToolsSemanticVersion || item.ToolsDisplayVersion || item.ToolsRawVersion || "");
    }

    return String(item[key] ?? "");
}

function compareInventories(previousRows) {
    const previous = new Map(previousRows.map(item => [String(item.VMName || "").toLowerCase(), item]));
    const current = new Map(reportData.map(item => [String(item.VMName || "").toLowerCase(), item]));
    const fields = [
        ["ToolsSemanticVersion", "Tools version"],
        ["ToolsCategory", "Tools state"],
        ["ToolsRunningStatus", "Tools running status"],
        ["HardwareVersion", "Hardware version"],
        ["ScheduledHWUpgrade", "HW upgrade policy"],
        ["ScheduledHWTarget", "HW upgrade target"]
    ];
    const changes = [];
    const changedVms = new Set();
    let added = 0;
    let removed = 0;

    for (const [key, currentItem] of current) {
        const previousItem = previous.get(key);

        if (!previousItem) {
            added++;
            changes.push({ vm: currentItem.VMName, type: "Added", field: "Inventory", before: "", after: "Present" });
            continue;
        }

        for (const [field, label] of fields) {
            const before = comparableValue(previousItem, field);
            const after = comparableValue(currentItem, field);

            if (before !== after) {
                changedVms.add(key);
                changes.push({ vm: currentItem.VMName, type: "Changed", field: label, before, after });
            }
        }
    }

    for (const [key, previousItem] of previous) {
        if (!current.has(key)) {
            removed++;
            changes.push({ vm: previousItem.VMName, type: "Removed", field: "Inventory", before: "Present", after: "" });
        }
    }

    changes.sort((left, right) =>
        left.vm.localeCompare(right.vm, undefined, { numeric: true }) || left.field.localeCompare(right.field)
    );

    renderComparison({
        previousCount: previousRows.length,
        currentCount: reportData.length,
        added,
        removed,
        changedVmCount: changedVms.size,
        changes
    });
}

function renderComparison(result) {
    comparisonSummary.innerHTML = [
        ["Previous servers", result.previousCount],
        ["Current servers", result.currentCount],
        ["Added / removed", `${result.added} / ${result.removed}`],
        ["Changed servers", result.changedVmCount]
    ].map(([label, value]) => `
        <div class="comparison-metric"><span>${htmlEncode(label)}</span><strong>${htmlEncode(value)}</strong></div>
    `).join("");

    comparisonBody.innerHTML = result.changes.length > 0
        ? result.changes.map(change => `
            <tr>
                <td><strong>${htmlEncode(change.vm)}</strong></td>
                <td>${htmlEncode(change.type)}</td>
                <td>${htmlEncode(change.field)}</td>
                <td>${htmlEncode(change.before || "-")}</td>
                <td>${htmlEncode(change.after || "-")}</td>
            </tr>
        `).join("")
        : '<tr><td colspan="5">No tracked inventory changes were found.</td></tr>';

    comparisonOverlay.hidden = false;
    comparisonModal.hidden = false;
    updateOverlayState();
    document.getElementById("closeComparisonButton").focus();
}

function closeComparison() {
    comparisonOverlay.hidden = true;
    comparisonModal.hidden = true;
    updateOverlayState();
}

async function importComparisonFile(file) {
    try {
        const previousRows = parseSnapshotText(await file.text(), file.name);
        compareInventories(previousRows);
    }
    catch (error) {
        alert(`Unable to compare the selected report: ${error.message}`);
    }
    finally {
        compareFileInput.value = "";
    }
}

function activateDashboardFilter(control) {
    setDashboardFilter(control.dataset.filter);
    renderTable();
}

document.querySelectorAll("[data-filter]").forEach(control => {
    control.addEventListener("click", () => activateDashboardFilter(control));

    if (control.getAttribute("role") === "button") {
        control.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                activateDashboardFilter(control);
            }
        });
    }
});

columnsButton.addEventListener("click", () => {
    toggleMenu(columnsMenu, columnsButton);
});

viewsButton.addEventListener("click", () => {
    renderSavedViews();
    toggleMenu(viewsMenu, viewsButton);
});

exportButton.addEventListener("click", () => toggleMenu(exportMenu, exportButton));

document.getElementById("saveViewButton").addEventListener("click", saveCurrentView);
savedViewName.addEventListener("keydown", event => {
    if (event.key === "Enter") {
        saveCurrentView();
    }
});

document.getElementById("showAllColumnsButton").addEventListener("click", () => {
    columnDefinitions.forEach(column => { column.visible = true; });
    saveColumnPreferences();
    buildTableColumns();
});

document.getElementById("resetColumnsButton").addEventListener("click", () => {
    columnDefinitions.forEach(column => {
        column.visible = column.defaultVisible;
        column.width = column.defaultWidth;
    });

    saveColumnPreferences();
    buildTableColumns();
});

document.addEventListener("click", event => {
    if (!columnControl.contains(event.target) &&
        !viewsControl.contains(event.target) &&
        !exportControl.contains(event.target)) {
        closeMenus();
    }
});

document.addEventListener("keydown", event => {
    if (event.key !== "Escape") {
        return;
    }

    if (!comparisonModal.hidden) {
        closeComparison();
    }
    else if (!detailDrawer.hidden) {
        closeVmDetails();
    }
    else {
        closeMenus();
    }
});

document.querySelectorAll("[data-insight-key]").forEach(tab => {
    tab.addEventListener("click", () => {
        activeInsightKey = tab.dataset.insightKey;
        activeGroupFilter = null;

        document.querySelectorAll("[data-insight-key]").forEach(item => {
            const isActive = item === tab;
            item.classList.toggle("active", isActive);
            item.setAttribute("aria-selected", String(isActive));
        });

        renderTable();
    });
});

function openDetailsFromRow(row) {
    const item = reportData.find(candidate => candidate.VMName === row.dataset.vmName);
    openVmDetails(item);
}

tableBody.addEventListener("click", event => {
    const row = event.target.closest("tr[data-vm-name]");

    if (row) {
        openDetailsFromRow(row);
    }
});

tableBody.addEventListener("keydown", event => {
    if (event.key === "Enter" || event.key === " ") {
        const row = event.target.closest("tr[data-vm-name]");

        if (row) {
            event.preventDefault();
            openDetailsFromRow(row);
        }
    }
});

document.getElementById("closeDetailButton").addEventListener("click", closeVmDetails);
drawerOverlay.addEventListener("click", closeVmDetails);
document.getElementById("closeComparisonButton").addEventListener("click", closeComparison);
comparisonOverlay.addEventListener("click", closeComparison);

function updateScrollbarDock() {
    refreshTableWidth();

    const rect = tableContainer.getBoundingClientRect();
    const viewportLeft = Math.max(0, rect.left);
    const viewportRight = Math.min(window.innerWidth, rect.right);
    const visibleWidth = Math.max(0, viewportRight - viewportLeft);
    const tableIsVisible = rect.top < window.innerHeight && rect.bottom > 0;
    const hasHorizontalOverflow = reportTable.scrollWidth > tableContainer.clientWidth + 1;

    scrollbarTrack.style.width = `${reportTable.scrollWidth}px`;
    scrollbarDock.style.left = `${viewportLeft}px`;
    scrollbarDock.style.width = `${visibleWidth}px`;
    scrollbarDock.classList.toggle(
        "visible",
        tableIsVisible && hasHorizontalOverflow && visibleWidth > 60
    );
}

tableContainer.addEventListener("scroll", () => {
    if (synchronizingScroll) {
        return;
    }

    synchronizingScroll = true;
    scrollbarDock.scrollLeft = tableContainer.scrollLeft;

    requestAnimationFrame(() => {
        synchronizingScroll = false;
    });
});

scrollbarDock.addEventListener("scroll", () => {
    if (synchronizingScroll) {
        return;
    }

    synchronizingScroll = true;
    tableContainer.scrollLeft = scrollbarDock.scrollLeft;

    requestAnimationFrame(() => {
        synchronizingScroll = false;
    });
});

window.addEventListener("scroll", updateScrollbarDock, { passive: true });
window.addEventListener("resize", updateScrollbarDock);

searchBox.addEventListener("input", renderTable);
clusterFilter.addEventListener("change", renderTable);
powerFilter.addEventListener("change", renderTable);

document.getElementById("clearButton").addEventListener("click", () => {
    searchBox.value = "";
    clusterFilter.value = "";
    powerFilter.value = "";
    activeGroupFilter = null;
    setDashboardFilter("all");

    renderTable();
});

document.getElementById("visibleCsvButton").addEventListener("click", () => {
    exportVisibleCsv();
    closeMenus();
});
document.getElementById("fullCsvButton").addEventListener("click", () => {
    exportFullCsv();
    closeMenus();
});
document.getElementById("snapshotButton").addEventListener("click", () => {
    exportSnapshot();
    closeMenus();
});
document.getElementById("compareButton").addEventListener("click", () => compareFileInput.click());
compareFileInput.addEventListener("change", () => {
    if (compareFileInput.files && compareFileInput.files[0]) {
        importComparisonFile(compareFileInput.files[0]);
    }
});
document.getElementById("printButton").addEventListener("click", () => window.print());

loadColumnPreferences();
populateClusterFilter();
renderSavedViews();
buildTableColumns();
</script>
</body>
</html>
'@

$html = $htmlTemplate
$html = $html.Replace('__REPORT_TITLE__', (ConvertTo-HtmlText -Value $reportTitle))
$html = $html.Replace('__GENERATED_DATE__', (ConvertTo-HtmlText -Value $generatedDate))
$html = $html.Replace('__MINIMUM_TOOLS_MAJOR__', [string]$MinimumToolsMajorVersion)
$html = $html.Replace('__SUMMARY_TOTAL__', [string]$summary['Total'])
$html = $html.Replace('__SUMMARY_BELOW_MINIMUM__', [string]$summary['BelowMinimum'])
$html = $html.Replace('__SUMMARY_NOT_RUNNING__', [string]$summary['NotRunning'])
$html = $html.Replace('__SUMMARY_NOT_INSTALLED__', [string]$summary['NotInstalled'])
$html = $html.Replace('__SUMMARY_POWERED_OFF__', [string]$summary['PoweredOff'])
$html = $html.Replace('__SUMMARY_HARDWARE_AT_21__', [string]$summary['HardwareAt21'])
$html = $html.Replace('__HARDWARE_AT_21_PERCENT__', [string]$hardwareAt21Percent)
$html = $html.Replace('__SUMMARY_POLICY_ALWAYS__', [string]$summary['PolicyAlways'])
$html = $html.Replace('__POLICY_ALWAYS_PERCENT__', [string]$policyAlwaysPercent)
$html = $html.Replace('__SUMMARY_HARDWARE_BELOW_21__', [string]$summary['HardwareBelow21'])
$html = $html.Replace('__JSON_DATA__', $jsonData)

$outputDirectory = Split-Path -Path $OutputPath -Parent

if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and
    -not (Test-Path -LiteralPath $outputDirectory)) {

    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$html | Set-Content -LiteralPath $OutputPath -Encoding UTF8

$resolvedOutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

Write-Host ''
Write-Host 'VMware Tools report completed.' -ForegroundColor Green
Write-Host "Windows Server VMs: $($summary['Total'])"
Write-Host "Report: $resolvedOutputPath"

if ($OpenReport -eq $true) {
    Start-Process $resolvedOutputPath
}
