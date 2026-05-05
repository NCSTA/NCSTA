# Windows Server VM Location HTML Report
#
# ISE-friendly usage:
# - If saved .ps1 files are blocked by execution policy, open PowerShell ISE.
# - Paste this entire script into the Script Pane.
# - Update the CONFIGURE THESE VALUES section.
# - Press F5, or highlight the full script and press F8.
#
# This script only performs read-only PowerCLI inventory queries. It does not
# modify vCenter, clusters, hosts, VMs, or licensing objects.

# --- CONFIGURE THESE VALUES ---
$outputDir = "C:\Temp"             # where HTML report will be saved
$vCenters  = @(                    # one or more vCenter servers
    "your_vcenter_server"
)
# --- END CONFIG ---

$reportScope = "ClusterWide"       # fixed behavior: all clusters and all hosts in all configured vCenters

# Optional: ignore self-signed certs
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null

# Connect
$serverConnections = foreach ($vCenter in $vCenters) {
    Connect-VIServer -Server $vCenter
}

function ConvertTo-HtmlEncoded {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-WholeNumber {
    param([object]$Value)

    if ($null -eq $Value) {
        return '0'
    }

    '{0:N0}' -f [double]$Value
}

function Test-IsWindowsServerVM {
    param([Parameter(Mandatory)][object]$VM)

    if ($VM.ExtensionData.Config.Template -eq $true) {
        return $false
    }

    $guestId       = [string]$VM.GuestId
    $configGuestId = [string]$VM.ExtensionData.Config.GuestId
    $guestFullName = [string]$VM.ExtensionData.Config.GuestFullName
    $toolsGuestOs  = [string]$VM.Guest.OSFullName
    $osText        = "$guestId $configGuestId $guestFullName $toolsGuestOs"

    # GuestId values often contain "srv" while display names usually contain "Server".
    return ($osText -match 'windows') -and ($osText -match 'server|srv')
}

function Get-HostCpuSummary {
    param([Parameter(Mandatory)][object]$VMHost)

    $cpuInfo = $VMHost.ExtensionData.Hardware.CpuInfo
    $sockets = [int]$cpuInfo.NumCpuPackages
    $cores   = [int]$cpuInfo.NumCpuCores

    $coresPerSocket = 0
    if ($sockets -gt 0) {
        $coresPerSocket = [math]::Round(($cores / $sockets), 2)
    }

    [pscustomobject]@{
        Sockets        = $sockets
        CoresPerSocket = $coresPerSocket
        TotalCores     = $cores
    }
}

function New-VMRowsHtml {
    param([object[]]$VMs)

    if (-not $VMs -or $VMs.Count -eq 0) {
        return '<div class="empty-state">No Windows Server VMs are currently running on this host.</div>'
    }

    $rows = foreach ($vm in ($VMs | Sort-Object Name)) {
        $vmName     = ConvertTo-HtmlEncoded $vm.Name
        $powerState = ConvertTo-HtmlEncoded $vm.PowerState
        $guestOs    = ConvertTo-HtmlEncoded $vm.GuestOS
        $cpuCount   = Format-WholeNumber $vm.VCpu
        $memoryGb   = '{0:N1}' -f [double]$vm.MemoryGB

        @"
                        <tr>
                            <td>$vmName</td>
                            <td>$powerState</td>
                            <td class="number">$cpuCount</td>
                            <td class="number">$memoryGb</td>
                            <td>$guestOs</td>
                        </tr>
"@
    }

    @"
                <div class="vm-scroll">
                    <table>
                        <thead>
                            <tr>
                                <th>VM</th>
                                <th>Power</th>
                                <th>vCPU</th>
                                <th>Memory GB</th>
                                <th>Detected OS</th>
                            </tr>
                        </thead>
                        <tbody>
$($rows -join "`n")
                        </tbody>
                    </table>
                </div>
"@
}

function New-HostSummaryHtml {
    param([Parameter(Mandatory)][object[]]$HostRows)

    if (-not $HostRows -or $HostRows.Count -eq 0) {
        return '<div class="empty-state">No hosts were found in the connected vCenters.</div>'
    }

    $rows = foreach ($hostRow in ($HostRows | Sort-Object vCenter, Cluster, Hostname)) {
        $vCenter        = ConvertTo-HtmlEncoded $hostRow.vCenter
        $cluster        = ConvertTo-HtmlEncoded $hostRow.Cluster
        $hostname       = ConvertTo-HtmlEncoded $hostRow.Hostname
        $cpuSockets     = Format-WholeNumber $hostRow.CpuSockets
        $coresPerSocket = Format-WholeNumber $hostRow.CoresPerSocket
        $totalCores     = Format-WholeNumber $hostRow.TotalCores
        $windowsVMs     = Format-WholeNumber $hostRow.WindowsVMs
        $rowClass       = if ($hostRow.WindowsVMs -gt 0) { 'has-windows' } else { 'no-windows' }

        @"
                        <tr class="$rowClass">
                            <td>$vCenter</td>
                            <td>$cluster</td>
                            <td>$hostname</td>
                            <td class="number">$cpuSockets</td>
                            <td class="number">$coresPerSocket</td>
                            <td class="number">$totalCores</td>
                            <td class="number strong">$windowsVMs</td>
                        </tr>
"@
    }

    @"
            <div class="table-scroll host-summary-scroll">
                <table>
                    <thead>
                        <tr>
                            <th>vCenter</th>
                            <th>Cluster</th>
                            <th>Hostname</th>
                            <th>CPU Sockets</th>
                            <th>Cores per Socket</th>
                            <th>Total Cores</th>
                            <th>Windows VMs</th>
                        </tr>
                    </thead>
                    <tbody>
$($rows -join "`n")
                    </tbody>
                </table>
            </div>
"@
}

function New-HostHtml {
    param(
        [Parameter(Mandatory)][object]$HostRow,
        [object[]]$VMs
    )

    $hostName       = ConvertTo-HtmlEncoded $HostRow.Hostname
    $hostCpu        = Format-WholeNumber $HostRow.TotalCores
    $hostSockets    = Format-WholeNumber $HostRow.CpuSockets
    $coresPerSocket = Format-WholeNumber $HostRow.CoresPerSocket
    $vmCount        = Format-WholeNumber $HostRow.WindowsVMs
    $vmRows         = New-VMRowsHtml -VMs $VMs
    $hostClass      = if ($HostRow.WindowsVMs -gt 0) { 'host-card has-windows' } else { 'host-card no-windows' }

    @"
            <details class="$hostClass" open>
                <summary>
                    <span class="summary-title">$hostName</span>
                    <span class="summary-stats">
                        <span>$hostCpu CPU cores</span>
                        <span>$hostSockets sockets</span>
                        <span>$coresPerSocket cores/socket</span>
                        <span>$vmCount Windows Server VMs</span>
                    </span>
                </summary>
                <div class="vm-panel">
$vmRows
                </div>
            </details>
"@
}

function New-ClusterHtml {
    param(
        [Parameter(Mandatory)][object]$ClusterRow,
        [object[]]$HostRows,
        [object[]]$VMInfo
    )

    $clusterDisplayName = ConvertTo-HtmlEncoded $ClusterRow.Cluster
    $vCenterDisplayName = ConvertTo-HtmlEncoded $ClusterRow.vCenter
    $clusterCores       = Format-WholeNumber $ClusterRow.TotalCores
    $hostCount          = Format-WholeNumber $ClusterRow.Hosts
    $vmCount            = Format-WholeNumber $ClusterRow.WindowsVMs
    $clusterClass       = if ($ClusterRow.WindowsVMs -gt 0) { 'cluster-card has-windows' } else { 'cluster-card no-windows' }

    $hostHtml = foreach ($hostRow in ($HostRows | Sort-Object Hostname)) {
        $hostVMs = @($VMInfo | Where-Object { $_.vCenter -eq $hostRow.vCenter -and $_.HostName -eq $hostRow.Hostname })
        New-HostHtml -HostRow $hostRow -VMs $hostVMs
    }

    if (-not $hostHtml) {
        $hostHtml = '<div class="empty-state">No hosts were found in this cluster.</div>'
    }

    @"
        <details class="$clusterClass" open>
            <summary>
                <span class="summary-title">$clusterDisplayName</span>
                <span class="summary-stats">
                    <span>vCenter: $vCenterDisplayName</span>
                    <span>$clusterCores CPU cores</span>
                    <span>$hostCount hosts</span>
                    <span>$vmCount Windows Server VMs</span>
                </span>
            </summary>
            <div class="host-list">
$($hostHtml -join "`n")
            </div>
        </details>
"@
}

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$clusterRows = @()
$hostRows = @()
$winVMInfo = @()

# Build report data per vCenter. These are read-only inventory queries.
foreach ($serverConnection in $serverConnections) {
    $currentVCenter = $serverConnection.Name

    $allClusters = @(Get-Cluster -Server $serverConnection)
    $allHosts    = @(Get-VMHost -Server $serverConnection)
    $allVMs      = @(Get-VM -Server $serverConnection)

    # Find Windows Server VMs.
    $winVMs = @($allVMs | Where-Object { Test-IsWindowsServerVM -VM $_ })

    # Map Windows Server VMs to cluster and host.
    $currentWinVMInfo = foreach ($vm in $winVMs) {
        $cluster = Get-Cluster -VM $vm -ErrorAction SilentlyContinue
        $hostObj = $vm.VMHost

        $clusterName = $null
        if ($cluster) {
            $clusterName = $cluster.Name
        }

        $guestOs = $vm.Guest.OSFullName
        if (-not $guestOs) {
            $guestOs = $vm.ExtensionData.Config.GuestFullName
        }
        if (-not $guestOs) {
            $guestOs = $vm.GuestId
        }

        [pscustomobject]@{
            vCenter    = $currentVCenter
            Name       = $vm.Name
            Cluster    = $clusterName
            HostName   = $hostObj.Name
            PowerState = $vm.PowerState
            VCpu       = $vm.NumCpu
            MemoryGB   = [math]::Round($vm.MemoryGB, 1)
            GuestOS    = $guestOs
        }
    }

    # Host report data. ClusterWide means every host, regardless of Windows VM count.
    $currentHostRows = foreach ($h in ($allHosts | Sort-Object Name)) {
        $clusterName = (Get-Cluster -VMHost $h -ErrorAction SilentlyContinue).Name
        if (-not $clusterName) {
            $clusterName = '(No Cluster)'
        }

        $cpu = Get-HostCpuSummary -VMHost $h

        [pscustomobject]@{
            vCenter        = $currentVCenter
            Scope          = $reportScope
            Cluster        = $clusterName
            Hostname       = $h.Name
            CpuSockets     = $cpu.Sockets
            CoresPerSocket = $cpu.CoresPerSocket
            TotalCores     = $cpu.TotalCores
            WindowsVMs     = @($currentWinVMInfo | Where-Object { $_.HostName -eq $h.Name }).Count
        }
    }

    $clusterNames = @($allClusters | Select-Object -ExpandProperty Name)
    $standaloneClusterNeeded = @($currentHostRows | Where-Object { $_.Cluster -eq '(No Cluster)' }).Count -gt 0
    if ($standaloneClusterNeeded) {
        $clusterNames += '(No Cluster)'
    }

    $currentClusterRows = foreach ($clusterName in ($clusterNames | Sort-Object -Unique)) {
        $clusterHostRows = @($currentHostRows | Where-Object { $_.Cluster -eq $clusterName })

        [pscustomobject]@{
            vCenter    = $currentVCenter
            Scope      = $reportScope
            Cluster    = $clusterName
            Hosts      = $clusterHostRows.Count
            TotalCores = ($clusterHostRows | Measure-Object -Property TotalCores -Sum).Sum
            WindowsVMs = ($clusterHostRows | Measure-Object -Property WindowsVMs -Sum).Sum
        }
    }

    $clusterRows += @($currentClusterRows)
    $hostRows += @($currentHostRows)
    $winVMInfo += @($currentWinVMInfo)
}

$hostSummaryHtml = New-HostSummaryHtml -HostRows $hostRows

$clusterHtml = foreach ($clusterRow in ($clusterRows | Sort-Object vCenter, Cluster)) {
    $clusterHostRows = @(
        $hostRows |
            Where-Object { $_.vCenter -eq $clusterRow.vCenter -and $_.Cluster -eq $clusterRow.Cluster }
    )
    New-ClusterHtml -ClusterRow $clusterRow -HostRows $clusterHostRows -VMInfo $winVMInfo
}

$reportGenerated = Get-Date
$ts              = $reportGenerated.ToString('yyyyMMdd-HHmmss')
$htmlPath        = Join-Path $outputDir ("Windows_Server_VM_Location_Report_$ts.html")
$totalVCenters   = Format-WholeNumber $serverConnections.Count
$totalClusters   = Format-WholeNumber $clusterRows.Count
$totalHosts      = Format-WholeNumber $hostRows.Count
$totalCores      = Format-WholeNumber (($hostRows | Measure-Object -Property TotalCores -Sum).Sum)
$totalVMs        = Format-WholeNumber $winVMInfo.Count
$encodedVCenters = ConvertTo-HtmlEncoded (($serverConnections | Select-Object -ExpandProperty Name) -join ', ')
$encodedScope    = ConvertTo-HtmlEncoded $reportScope
$encodedDate     = ConvertTo-HtmlEncoded ($reportGenerated.ToString('yyyy-MM-dd HH:mm:ss zzz'))

if (-not $clusterHtml) {
    $clusterHtml = '<div class="empty-state page-empty">No clusters or hosts were found in the connected vCenters.</div>'
}

$html = @"
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Windows Server VM Location Report</title>
    <style>
        :root {
            --bg: #090d14;
            --panel: #101722;
            --panel-soft: #151f2c;
            --panel-raised: #182435;
            --ink: #eef4fb;
            --muted: #9daabc;
            --line: #293648;
            --line-strong: #3d4f66;
            --accent: #66d9e8;
            --accent-soft: #133440;
            --good: #67e8a5;
            --good-soft: #102b23;
            --warn: #f7c948;
            --warn-soft: #31270f;
            --risk: #ff8f70;
            --risk-soft: #351c18;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            background:
                radial-gradient(circle at 20% 0%, rgba(102, 217, 232, .12), transparent 28rem),
                linear-gradient(180deg, #0d1420 0%, var(--bg) 34rem);
            color: var(--ink);
            font-family: "Segoe UI", Arial, sans-serif;
            font-size: 14px;
            line-height: 1.45;
        }

        header {
            border-bottom: 1px solid var(--line);
            padding: 28px 32px 20px;
        }

        h1 {
            margin: 0 0 8px;
            font-size: 30px;
            font-weight: 650;
            letter-spacing: 0;
        }

        h2 {
            margin: 0 0 12px;
            font-size: 18px;
            font-weight: 650;
            letter-spacing: 0;
        }

        .subtitle {
            color: var(--muted);
            margin: 0;
        }

        main {
            max-width: 1600px;
            margin: 0 auto;
            padding: 24px 32px 44px;
        }

        .toolbar,
        .metric-grid,
        .note,
        .panel-section {
            margin-bottom: 18px;
        }

        .metric-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
            gap: 12px;
        }

        .metric,
        .panel-section,
        details {
            background: rgba(16, 23, 34, .94);
            border: 1px solid var(--line);
            box-shadow: 0 18px 40px rgba(0, 0, 0, .22);
        }

        .metric {
            border-radius: 8px;
            padding: 15px 16px;
        }

        .metric .label {
            color: var(--muted);
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .04em;
        }

        .metric .value {
            display: block;
            margin-top: 4px;
            font-size: 26px;
            font-weight: 700;
        }

        .panel-section {
            border-radius: 8px;
            padding: 16px;
        }

        .toolbar {
            display: flex;
            gap: 10px;
            align-items: center;
            flex-wrap: wrap;
        }

        button,
        input {
            border: 1px solid var(--line-strong);
            border-radius: 6px;
            background: #0f1722;
            color: var(--ink);
            font: inherit;
            min-height: 38px;
        }

        button {
            padding: 0 12px;
            cursor: pointer;
        }

        button:hover {
            background: var(--accent-soft);
            border-color: var(--accent);
        }

        input {
            flex: 1 1 360px;
            padding: 0 12px;
        }

        input::placeholder {
            color: #78869a;
        }

        .note {
            background: rgba(19, 52, 64, .74);
            border: 1px solid #285568;
            border-radius: 8px;
            padding: 12px 14px;
            color: #c8edf4;
        }

        details {
            border-radius: 8px;
        }

        details + details {
            margin-top: 12px;
        }

        summary {
            cursor: pointer;
            padding: 13px 16px;
            display: flex;
            gap: 14px;
            align-items: center;
            justify-content: space-between;
        }

        summary::marker {
            color: var(--accent);
        }

        .summary-title {
            font-weight: 650;
            min-width: 0;
            overflow-wrap: anywhere;
        }

        .summary-stats {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            justify-content: flex-end;
            color: var(--muted);
            font-size: 13px;
        }

        .summary-stats span {
            background: #0d1420;
            border: 1px solid var(--line);
            border-radius: 999px;
            padding: 2px 8px;
            white-space: nowrap;
        }

        .has-windows > summary .summary-stats span:last-child,
        tr.has-windows .strong {
            color: var(--warn);
        }

        .no-windows > summary .summary-stats span:last-child,
        tr.no-windows .strong {
            color: var(--good);
        }

        .cluster-card[open] > summary,
        .host-card[open] > summary {
            border-bottom: 1px solid var(--line);
        }

        .host-list {
            padding: 12px;
            background: rgba(7, 11, 17, .32);
        }

        .host-card {
            border-radius: 6px;
            box-shadow: none;
        }

        .vm-panel {
            padding: 12px;
        }

        .table-scroll,
        .vm-scroll {
            overflow: auto;
            border: 1px solid var(--line);
            border-radius: 6px;
            background: #0b1119;
        }

        .host-summary-scroll {
            max-height: 460px;
        }

        .vm-scroll {
            max-height: 320px;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 860px;
        }

        th,
        td {
            padding: 9px 10px;
            border-bottom: 1px solid var(--line);
            text-align: left;
            vertical-align: top;
        }

        th {
            position: sticky;
            top: 0;
            background: #142030;
            color: #dbe7f3;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .04em;
            z-index: 1;
        }

        td {
            color: #d5deea;
        }

        tr:nth-child(even) td {
            background: rgba(255, 255, 255, .018);
        }

        tr:hover td {
            background: rgba(102, 217, 232, .07);
        }

        tr:last-child td {
            border-bottom: 0;
        }

        .number {
            text-align: right;
            white-space: nowrap;
        }

        .strong {
            font-weight: 700;
        }

        .empty-state {
            color: var(--muted);
            background: #0b1119;
            border: 1px dashed var(--line-strong);
            border-radius: 6px;
            padding: 14px;
        }

        .page-empty {
            background: var(--panel);
        }

        .is-hidden {
            display: none;
        }

        @media (max-width: 760px) {
            header,
            main {
                padding-left: 16px;
                padding-right: 16px;
            }

            .metric-grid {
                grid-template-columns: 1fr;
            }

            summary {
                align-items: flex-start;
                flex-direction: column;
            }

            .summary-stats {
                justify-content: flex-start;
            }
        }
    </style>
</head>
<body>
    <header>
        <h1>Windows Server VM Location Report</h1>
        <p class="subtitle">vCenters: $encodedVCenters | Scope: $encodedScope | Generated: $encodedDate</p>
    </header>
    <main>
        <section class="metric-grid" aria-label="Report totals">
            <div class="metric"><span class="label">vCenters</span><span class="value">$totalVCenters</span></div>
            <div class="metric"><span class="label">Clusters</span><span class="value">$totalClusters</span></div>
            <div class="metric"><span class="label">Hosts</span><span class="value">$totalHosts</span></div>
            <div class="metric"><span class="label">CPU Cores</span><span class="value">$totalCores</span></div>
            <div class="metric"><span class="label">Windows Server VMs</span><span class="value">$totalVMs</span></div>
        </section>

        <section class="toolbar" aria-label="Report controls">
            <input id="filterBox" type="search" placeholder="Filter by vCenter, cluster, host, VM, power state, or OS">
            <button type="button" id="expandAll">Expand all</button>
            <button type="button" id="collapseAll">Collapse all</button>
            <button type="button" id="clearFilter">Clear filter</button>
        </section>

        <section class="note">
            This ClusterWide report includes every cluster and every host in each configured vCenter. Windows Server VM counts show where Microsoft Datacenter licensing exposure exists and where follow-up placement review may be needed.
        </section>

        <section class="panel-section" id="hostSummary" aria-label="Host summary">
            <h2>Host Summary</h2>
$hostSummaryHtml
        </section>

        <section id="reportTree" aria-label="Cluster and host detail">
$($clusterHtml -join "`n")
        </section>
    </main>

    <script>
        const reportTree = document.getElementById('reportTree');
        const hostSummary = document.getElementById('hostSummary');
        const filterBox = document.getElementById('filterBox');

        document.getElementById('expandAll').addEventListener('click', () => {
            reportTree.querySelectorAll('details').forEach((detail) => detail.open = true);
        });

        document.getElementById('collapseAll').addEventListener('click', () => {
            reportTree.querySelectorAll('details').forEach((detail) => detail.open = false);
        });

        document.getElementById('clearFilter').addEventListener('click', () => {
            filterBox.value = '';
            applyFilter('');
            filterBox.focus();
        });

        filterBox.addEventListener('input', (event) => applyFilter(event.target.value));

        function applyFilter(value) {
            const term = value.trim().toLowerCase();
            const clusters = [...reportTree.querySelectorAll('.cluster-card')];
            const hostSummaryRows = [...hostSummary.querySelectorAll('tbody tr')];

            hostSummaryRows.forEach((row) => {
                const matched = !term || row.textContent.toLowerCase().includes(term);
                row.classList.toggle('is-hidden', !matched);
            });

            clusters.forEach((cluster) => {
                let clusterMatched = !term || cluster.textContent.toLowerCase().includes(term);
                cluster.classList.toggle('is-hidden', !clusterMatched);

                if (term && clusterMatched) {
                    cluster.open = true;
                    const clusterSummary = cluster.children[0].textContent.toLowerCase();
                    const clusterSummaryMatched = clusterSummary.includes(term);
                    cluster.querySelectorAll('.host-card').forEach((host) => {
                        const hostMatched = clusterSummaryMatched || host.textContent.toLowerCase().includes(term);
                        host.classList.toggle('is-hidden', !hostMatched);
                        host.open = hostMatched;
                    });
                } else {
                    cluster.querySelectorAll('.host-card').forEach((host) => host.classList.remove('is-hidden'));
                }
            });
        }
    </script>
</body>
</html>
"@

$html | Set-Content -Path $htmlPath -Encoding UTF8

Write-Host ""
Write-Host " Windows Server VM location report: $htmlPath"
Write-Host ""
Write-Host "Notes:"
Write-Host " - This script performs read-only inventory queries only."
Write-Host " - Scope=ClusterWide includes every cluster and every host in all configured vCenters."
Write-Host " - Each cluster row includes the vCenter where that cluster was found."
Write-Host " - Host Summary mirrors the monthly review data: vCenter, cluster, host CPU, total cores, and Windows VM count."
