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

# Minimum VMware Tools major version. For vCenter numeric Tools versions,
# 13 maps to a threshold of 13000.
$MinimumToolsMajorVersion = 13

# Automatically open the HTML report when finished.
$OpenReport = $true

# ==========================================================
# END SETTINGS
# ==========================================================

function ConvertTo-ToolsDisplayVersion {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$RawVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or $RawVersion -eq '0') {
        return 'Unknown'
    }

    if ($RawVersion -match '^\d+$') {
        $numericVersion = [int]$RawVersion

        if ($numericVersion -ge 10000) {
            $major = [math]::Floor($numericVersion / 1000)
            $remainder = $numericVersion % 1000
            $minor = [math]::Floor($remainder / 100)

            return "$major.$minor generation ($RawVersion)"
        }
    }

    return $RawVersion
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

        [int]$MinimumVersionNumber
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or
        $RawVersion -eq '0' -or
        $VersionStatus -eq 'guestToolsNotInstalled') {

        return 'Not Installed'
    }

    if ($RunningStatus -ne 'guestToolsRunning') {
        return 'Not Running'
    }

    if ($RawVersion -match '^\d+$' -and [int]$RawVersion -lt $MinimumVersionNumber) {
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

$minimumToolsNumber = $MinimumToolsMajorVersion * 1000

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

    $category = Get-ToolsCategory `
        -VersionStatus $toolsStatus `
        -RunningStatus $runningStatus `
        -RawVersion $rawToolsVersion `
        -MinimumVersionNumber $minimumToolsNumber

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
        ToolsDisplayVersion  = ConvertTo-ToolsDisplayVersion -RawVersion $rawToolsVersion
        ToolsCategory        = [string]$category
        ToolsVersionStatus   = [string]$toolsStatus
        ToolsRunningStatus   = [string]$runningStatus
        ToolsInstallType     = [string]$vmView.Guest.ToolsInstallType
        ToolsUpgradePolicy   = [string]$vmView.Config.Tools.ToolsUpgradePolicy
        MeetsMinimumTools    = (
            $rawToolsVersion -match '^\d+$' -and
            [int]$rawToolsVersion -ge $minimumToolsNumber
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
    Current         = @($reportData | Where-Object ToolsCategory -eq 'Current').Count
    Outdated        = @($reportData | Where-Object {
        $_.ToolsCategory -in @('Outdated', 'Supported Old', 'Too Old')
    }).Count
    BelowMinimum    = @($reportData | Where-Object MeetsMinimumTools -eq $false).Count
    NotRunning      = @($reportData | Where-Object ToolsCategory -eq 'Not Running').Count
    NotInstalled    = @($reportData | Where-Object ToolsCategory -eq 'Not Installed').Count
    PoweredOff      = @($reportData | Where-Object PowerState -ne 'poweredOn').Count
    HardwareBelow21 = @($reportData | Where-Object {
        $_.HardwareVersion -match '^vmx-(\d+)$' -and
        [int]$Matches[1] -lt 21
    }).Count
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
        --background: #f5f7fb;
        --panel: #ffffff;
        --text: #172033;
        --muted: #61708a;
        --border: #d8e0ea;
        --blue: #1d5fd1;
        --green: #147a39;
        --amber: #a86800;
        --red: #c3262f;
        --orange: #d34d12;
        --violet: #6750c2;
        --gray: #596579;
        --row-hover: #f7fafc;
    }

    * {
        box-sizing: border-box;
    }

    body {
        margin: 0;
        background: var(--background);
        color: var(--text);
        font-family: "Segoe UI", Arial, sans-serif;
        font-size: 14px;
    }

    .page {
        max-width: 1800px;
        margin: 0 auto;
        padding: 24px;
    }

    .header {
        margin-bottom: 18px;
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

    .dashboard {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(172px, 1fr));
        gap: 12px;
        margin-bottom: 18px;
    }

    .card {
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 8px;
        padding: 14px;
        cursor: pointer;
        user-select: none;
        transition: box-shadow 0.12s ease, border-color 0.12s ease;
    }

    .card:hover {
        box-shadow: 0 7px 18px rgba(23, 32, 51, 0.08);
    }

    .card.active {
        border-color: var(--blue);
        box-shadow: 0 0 0 3px rgba(29, 95, 209, 0.16);
    }

    .card-label {
        color: var(--muted);
        font-size: 12px;
        font-weight: 700;
        text-transform: uppercase;
        letter-spacing: 0.4px;
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

    .toolbar {
        display: flex;
        flex-wrap: wrap;
        align-items: center;
        gap: 10px;
        background: var(--panel);
        border: 1px solid var(--border);
        border-radius: 8px 8px 0 0;
        padding: 12px;
    }

    input,
    select,
    button {
        border: 1px solid var(--border);
        border-radius: 6px;
        background: #fff;
        color: var(--text);
        padding: 8px 10px;
        font: inherit;
        min-height: 38px;
    }

    input {
        min-width: 280px;
        flex: 1;
    }

    button {
        cursor: pointer;
        font-weight: 650;
    }

    button:hover {
        background: #f0f4f8;
    }

    .result-count {
        color: var(--muted);
        margin-left: auto;
        white-space: nowrap;
    }

    .table-container {
        background: var(--panel);
        border: 1px solid var(--border);
        border-top: 0;
        border-radius: 0 0 8px 8px;
        overflow: auto;
        max-height: 70vh;
    }

    table {
        width: 100%;
        border-collapse: collapse;
        white-space: nowrap;
    }

    th {
        position: sticky;
        top: 0;
        z-index: 2;
        background: #eaf0f7;
        text-align: left;
        padding: 10px;
        border-bottom: 1px solid var(--border);
        cursor: pointer;
        font-weight: 700;
    }

    td {
        padding: 8px 10px;
        border-bottom: 1px solid #edf1f5;
        vertical-align: middle;
    }

    tbody tr:hover {
        background: var(--row-hover);
    }

    .badge {
        display: inline-block;
        min-width: 86px;
        text-align: center;
        padding: 4px 8px;
        border-radius: 999px;
        font-size: 12px;
        font-weight: 700;
    }

    .status-current {
        color: #0f5d29;
        background: #dcfce7;
    }

    .status-outdated,
    .status-supported-old,
    .status-below-minimum {
        color: #854200;
        background: #ffedd5;
    }

    .status-not-running {
        color: #7a4b00;
        background: #fef3c7;
    }

    .status-not-installed,
    .status-too-old,
    .status-blacklisted {
        color: #991b1b;
        background: #fee2e2;
    }

    .status-unmanaged,
    .status-unknown {
        color: #475569;
        background: #e2e8f0;
    }

    .status-newer-than-host,
    .status-too-new {
        color: #5532a8;
        background: #ede9fe;
    }

    .yes {
        color: var(--green);
        font-weight: 700;
    }

    .no {
        color: var(--red);
        font-weight: 700;
    }

    .footer {
        color: var(--muted);
        padding: 16px 2px 4px;
        font-size: 12px;
    }

    @media (max-width: 900px) {
        .page {
            padding: 12px;
        }

        input {
            min-width: 100%;
        }

        .result-count {
            margin-left: 0;
        }
    }
</style>
</head>
<body>
<div class="page">
    <div class="header">
        <h1>__REPORT_TITLE__</h1>
        <div class="subtitle">
            Generated __GENERATED_DATE__ | Minimum VMware Tools generation: __MINIMUM_TOOLS_MAJOR__.0 | Click a dashboard card to filter
        </div>
    </div>

    <div class="dashboard">
        <div class="card blue active" data-filter="all">
            <div class="card-label">Total Servers</div>
            <div class="card-value">__SUMMARY_TOTAL__</div>
        </div>

        <div class="card green" data-filter="current">
            <div class="card-label">Tools Current</div>
            <div class="card-value">__SUMMARY_CURRENT__</div>
        </div>

        <div class="card orange" data-filter="outdated">
            <div class="card-label">Tools Outdated</div>
            <div class="card-value">__SUMMARY_OUTDATED__</div>
        </div>

        <div class="card red" data-filter="belowminimum">
            <div class="card-label">Below __MINIMUM_TOOLS_MAJOR__.0</div>
            <div class="card-value">__SUMMARY_BELOW_MINIMUM__</div>
        </div>

        <div class="card amber" data-filter="notrunning">
            <div class="card-label">Tools Not Running</div>
            <div class="card-value">__SUMMARY_NOT_RUNNING__</div>
        </div>

        <div class="card red" data-filter="notinstalled">
            <div class="card-label">Not Installed</div>
            <div class="card-value">__SUMMARY_NOT_INSTALLED__</div>
        </div>

        <div class="card gray" data-filter="poweredoff">
            <div class="card-label">Powered Off</div>
            <div class="card-value">__SUMMARY_POWERED_OFF__</div>
        </div>

        <div class="card violet" data-filter="hardwarebelow21">
            <div class="card-label">Hardware Below 21</div>
            <div class="card-value">__SUMMARY_HARDWARE_BELOW_21__</div>
        </div>
    </div>

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

        <button id="clearButton" type="button">Clear filters</button>
        <button id="csvButton" type="button">Export filtered CSV</button>

        <span class="result-count" id="resultCount"></span>
    </div>

    <div class="table-container">
        <table id="reportTable">
            <thead>
                <tr>
                    <th data-column="VMName">VM Name</th>
                    <th data-column="DNSName">DNS Name</th>
                    <th data-column="OperatingSystem">Operating System</th>
                    <th data-column="PowerState">Power</th>
                    <th data-column="Cluster">Cluster</th>
                    <th data-column="ESXiHost">ESXi Host</th>
                    <th data-column="HardwareVersion">HW Version</th>
                    <th data-column="ToolsDisplayVersion">Tools Version</th>
                    <th data-column="ToolsCategory">Tools State</th>
                    <th data-column="ToolsRunningStatus">Running State</th>
                    <th data-column="ToolsInstallType">Install Type</th>
                    <th data-column="ToolsUpgradePolicy">Upgrade Policy</th>
                    <th data-column="MeetsMinimumTools">Meets Minimum</th>
                    <th data-column="ScheduledHWUpgrade">HW Upgrade Policy</th>
                    <th data-column="ScheduledHWTarget">HW Target</th>
                    <th data-column="IPAddress">IP Address</th>
                </tr>
            </thead>
            <tbody></tbody>
        </table>
    </div>

    <div class="footer">
        Tools version is reported from vCenter. Validate critical systems independently before using the report as an upgrade approval source.
    </div>
</div>

<script>
const reportData = __JSON_DATA__;

let activeCardFilter = "all";
let sortColumn = "VMName";
let sortAscending = true;

const tableBody = document.querySelector("#reportTable tbody");
const searchBox = document.getElementById("searchBox");
const clusterFilter = document.getElementById("clusterFilter");
const powerFilter = document.getElementById("powerFilter");
const resultCount = document.getElementById("resultCount");

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

function populateClusterFilter() {
    const clusters = [...new Set(reportData.map(item => item.Cluster).filter(Boolean))].sort();

    for (const cluster of clusters) {
        const option = document.createElement("option");
        option.value = cluster;
        option.textContent = cluster;
        clusterFilter.appendChild(option);
    }
}

function matchesCardFilter(item) {
    switch (activeCardFilter) {
        case "current":
            return item.ToolsCategory === "Current";

        case "outdated":
            return ["Outdated", "Supported Old", "Too Old"].includes(item.ToolsCategory);

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

        default:
            return true;
    }
}

function getFilteredData() {
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
        })
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

function renderTable() {
    const filteredData = getFilteredData();

    tableBody.innerHTML = filteredData.map(item => `
        <tr>
            <td><strong>${htmlEncode(item.VMName)}</strong></td>
            <td>${htmlEncode(item.DNSName)}</td>
            <td>${htmlEncode(item.OperatingSystem)}</td>
            <td>${htmlEncode(item.PowerState)}</td>
            <td>${htmlEncode(item.Cluster)}</td>
            <td>${htmlEncode(item.ESXiHost)}</td>
            <td>${htmlEncode(item.HardwareVersion)}</td>
            <td title="Raw value: ${htmlEncode(item.ToolsRawVersion)}">${htmlEncode(item.ToolsDisplayVersion)}</td>
            <td><span class="badge ${classNameFromStatus(item.ToolsCategory)}">${htmlEncode(item.ToolsCategory)}</span></td>
            <td>${htmlEncode(item.ToolsRunningStatus)}</td>
            <td>${htmlEncode(item.ToolsInstallType)}</td>
            <td>${htmlEncode(item.ToolsUpgradePolicy)}</td>
            <td class="${item.MeetsMinimumTools ? "yes" : "no"}">${item.MeetsMinimumTools ? "Yes" : "No"}</td>
            <td>${htmlEncode(item.ScheduledHWUpgrade)}</td>
            <td>${htmlEncode(item.ScheduledHWTarget)}</td>
            <td>${htmlEncode(item.IPAddress)}</td>
        </tr>
    `).join("");

    resultCount.textContent =
        `${filteredData.length.toLocaleString()} of ${reportData.length.toLocaleString()} servers`;
}

function exportFilteredCsv() {
    const data = getFilteredData();

    if (data.length === 0) {
        alert("There are no rows to export.");
        return;
    }

    const columns = Object.keys(data[0]);
    const escapeCsv = value => '"' + String(value ?? "").replaceAll('"', '""') + '"';
    const csv = [
        columns.map(escapeCsv).join(","),
        ...data.map(row => columns.map(column => escapeCsv(row[column])).join(","))
    ].join("\r\n");

    const blob = new Blob([csv], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");

    link.href = url;
    link.download = "VMwareTools-Filtered.csv";
    link.click();

    URL.revokeObjectURL(url);
}

document.querySelectorAll(".card").forEach(card => {
    card.addEventListener("click", () => {
        document.querySelectorAll(".card").forEach(item => item.classList.remove("active"));
        card.classList.add("active");
        activeCardFilter = card.dataset.filter;
        renderTable();
    });
});

document.querySelectorAll("th[data-column]").forEach(header => {
    header.addEventListener("click", () => {
        const selectedColumn = header.dataset.column;

        if (sortColumn === selectedColumn) {
            sortAscending = !sortAscending;
        }
        else {
            sortColumn = selectedColumn;
            sortAscending = true;
        }

        renderTable();
    });
});

searchBox.addEventListener("input", renderTable);
clusterFilter.addEventListener("change", renderTable);
powerFilter.addEventListener("change", renderTable);

document.getElementById("clearButton").addEventListener("click", () => {
    searchBox.value = "";
    clusterFilter.value = "";
    powerFilter.value = "";
    activeCardFilter = "all";

    document.querySelectorAll(".card").forEach(item => item.classList.remove("active"));
    document.querySelector('.card[data-filter="all"]').classList.add("active");

    renderTable();
});

document.getElementById("csvButton").addEventListener("click", exportFilteredCsv);

populateClusterFilter();
renderTable();
</script>
</body>
</html>
'@

$html = $htmlTemplate
$html = $html.Replace('__REPORT_TITLE__', (ConvertTo-HtmlText -Value $reportTitle))
$html = $html.Replace('__GENERATED_DATE__', (ConvertTo-HtmlText -Value $generatedDate))
$html = $html.Replace('__MINIMUM_TOOLS_MAJOR__', [string]$MinimumToolsMajorVersion)
$html = $html.Replace('__SUMMARY_TOTAL__', [string]$summary['Total'])
$html = $html.Replace('__SUMMARY_CURRENT__', [string]$summary['Current'])
$html = $html.Replace('__SUMMARY_OUTDATED__', [string]$summary['Outdated'])
$html = $html.Replace('__SUMMARY_BELOW_MINIMUM__', [string]$summary['BelowMinimum'])
$html = $html.Replace('__SUMMARY_NOT_RUNNING__', [string]$summary['NotRunning'])
$html = $html.Replace('__SUMMARY_NOT_INSTALLED__', [string]$summary['NotInstalled'])
$html = $html.Replace('__SUMMARY_POWERED_OFF__', [string]$summary['PoweredOff'])
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
