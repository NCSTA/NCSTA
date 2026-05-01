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
$scope     = "ClusterWide"         # "ClusterWide" (audit-safe) or "HostOnly"
$vCenters  = @(                    # one or more vCenter servers
    "your_vcenter_server"
)
# --- END CONFIG ---

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

    @"
            <details class="host-card">
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
        [Parameter(Mandatory)][string]$ClusterName,
        [Parameter(Mandatory)][string]$VCenterName,
        [Parameter(Mandatory)][object[]]$HostRows,
        [Parameter(Mandatory)][object[]]$VMInfo
    )

    $clusterDisplayName = ConvertTo-HtmlEncoded $ClusterName
    $vCenterDisplayName = ConvertTo-HtmlEncoded $VCenterName
    $clusterCores       = Format-WholeNumber (($HostRows | Measure-Object -Property TotalCores -Sum).Sum)
    $hostCount          = Format-WholeNumber $HostRows.Count
    $vmCount            = Format-WholeNumber (($HostRows | Measure-Object -Property WindowsVMs -Sum).Sum)

    $hostHtml = foreach ($hostRow in ($HostRows | Sort-Object Hostname)) {
        $hostVMs = @($VMInfo | Where-Object { $_.vCenter -eq $hostRow.vCenter -and $_.HostName -eq $hostRow.Hostname })
        New-HostHtml -HostRow $hostRow -VMs $hostVMs
    }

    @"
        <details class="cluster-card">
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

$hostRows = @()
$winVMInfo = @()

# Build report data per vCenter. These are read-only inventory queries.
foreach ($serverConnection in $serverConnections) {
    $currentVCenter = $serverConnection.Name

    $allHosts = @(Get-VMHost -Server $serverConnection)
    $allVMs   = @(Get-VM -Server $serverConnection)

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

    # Which hosts should be shown in the report?
    if ($scope -eq "HostOnly") {
        $hostNamesToReport = @($currentWinVMInfo.HostName | Where-Object { $_ } | Sort-Object -Unique)
        $hostsToReport = @($allHosts | Where-Object { $hostNamesToReport -contains $_.Name })
    } else {
        $clustersWithWindows = @($currentWinVMInfo.Cluster | Where-Object { $_ } | Sort-Object -Unique)
        $standaloneHostsWithWindows = @(
            $currentWinVMInfo |
                Where-Object { -not $_.Cluster } |
                Select-Object -ExpandProperty HostName -Unique
        )

        $clusterHosts = foreach ($clusterName in $clustersWithWindows) {
            Get-Cluster -Name $clusterName -Server $serverConnection | Get-VMHost
        }

        $standaloneHosts = @($allHosts | Where-Object { $standaloneHostsWithWindows -contains $_.Name })
        $hostsToReport = @($clusterHosts + $standaloneHosts)
    }

    $hostsToReport = @(
        $hostsToReport |
            Where-Object { $_ } |
            Group-Object Name |
            ForEach-Object { $_.Group[0] } |
            Sort-Object Name
    )

    # Host report data.
    $currentHostRows = foreach ($h in $hostsToReport) {
        $clusterName = (Get-Cluster -VMHost $h -ErrorAction SilentlyContinue).Name
        if (-not $clusterName) {
            $clusterName = '(No Cluster)'
        }

        $cpu = Get-HostCpuSummary -VMHost $h

        [pscustomobject]@{
            vCenter        = $currentVCenter
            Scope          = $scope
            Cluster        = $clusterName
            Hostname       = $h.Name
            CpuSockets     = $cpu.Sockets
            CoresPerSocket = $cpu.CoresPerSocket
            TotalCores     = $cpu.TotalCores
            WindowsVMs     = @($currentWinVMInfo | Where-Object { $_.HostName -eq $h.Name }).Count
        }
    }

    $winVMInfo += @($currentWinVMInfo)
    $hostRows += @($currentHostRows)
}

$clusterHtml = foreach ($clusterGroup in ($hostRows | Sort-Object vCenter, Cluster | Group-Object vCenter, Cluster)) {
    $firstHostRow = $clusterGroup.Group[0]
    New-ClusterHtml -ClusterName $firstHostRow.Cluster -VCenterName $firstHostRow.vCenter -HostRows @($clusterGroup.Group) -VMInfo $winVMInfo
}

$reportGenerated = Get-Date
$ts              = $reportGenerated.ToString('yyyyMMdd-HHmmss')
$htmlPath        = Join-Path $outputDir ("Windows_Server_VM_Location_Report_$ts.html")
$totalHosts      = Format-WholeNumber $hostRows.Count
$totalClusters   = Format-WholeNumber (($hostRows | Group-Object vCenter, Cluster).Count)
$totalCores      = Format-WholeNumber (($hostRows | Measure-Object -Property TotalCores -Sum).Sum)
$totalVMs        = Format-WholeNumber $winVMInfo.Count
$totalVCenters   = Format-WholeNumber $serverConnections.Count
$encodedVCenters = ConvertTo-HtmlEncoded (($serverConnections | Select-Object -ExpandProperty Name) -join ', ')
$encodedScope    = ConvertTo-HtmlEncoded $scope
$encodedDate     = ConvertTo-HtmlEncoded ($reportGenerated.ToString('yyyy-MM-dd HH:mm:ss zzz'))

if (-not $clusterHtml) {
    $clusterHtml = '<div class="empty-state page-empty">No Windows Server VMs were found for the selected scope.</div>'
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
            --bg: #f6f7f9;
            --panel: #ffffff;
            --ink: #172033;
            --muted: #5f6b7a;
            --line: #d8dee8;
            --line-strong: #b9c4d2;
            --accent: #245f73;
            --accent-soft: #e5f2f5;
            --warn-soft: #fff4d6;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            background: var(--bg);
            color: var(--ink);
            font-family: "Segoe UI", Arial, sans-serif;
            font-size: 14px;
            line-height: 1.45;
        }

        header {
            background: #ffffff;
            border-bottom: 1px solid var(--line);
            padding: 24px 32px 18px;
        }

        h1 {
            margin: 0 0 8px;
            font-size: 28px;
            font-weight: 650;
            letter-spacing: 0;
        }

        .subtitle {
            color: var(--muted);
            margin: 0;
        }

        main {
            max-width: 1500px;
            margin: 0 auto;
            padding: 24px 32px 40px;
        }

        .toolbar,
        .metric-grid,
        .note {
            margin-bottom: 18px;
        }

        .metric-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
            gap: 12px;
        }

        .metric {
            background: var(--panel);
            border: 1px solid var(--line);
            border-radius: 8px;
            padding: 14px 16px;
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
            font-size: 24px;
            font-weight: 650;
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
            background: #ffffff;
            color: var(--ink);
            font: inherit;
            min-height: 36px;
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
            flex: 1 1 320px;
            padding: 0 12px;
        }

        .note {
            background: var(--warn-soft);
            border: 1px solid #ead596;
            border-radius: 8px;
            padding: 12px 14px;
            color: #5a4a1f;
        }

        details {
            background: var(--panel);
            border: 1px solid var(--line);
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
            background: #f1f4f7;
            border: 1px solid var(--line);
            border-radius: 999px;
            padding: 2px 8px;
            white-space: nowrap;
        }

        .cluster-card[open] > summary {
            border-bottom: 1px solid var(--line);
        }

        .host-list {
            padding: 12px;
            background: #fbfcfd;
        }

        .host-card {
            border-radius: 6px;
        }

        .host-card[open] > summary {
            border-bottom: 1px solid var(--line);
        }

        .vm-panel {
            padding: 12px;
        }

        .vm-scroll {
            max-height: 360px;
            overflow: auto;
            border: 1px solid var(--line);
            border-radius: 6px;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 760px;
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
            background: #eef3f6;
            color: #243241;
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: .04em;
            z-index: 1;
        }

        tr:last-child td {
            border-bottom: 0;
        }

        .number {
            text-align: right;
            white-space: nowrap;
        }

        .empty-state {
            color: var(--muted);
            background: #f7f9fb;
            border: 1px dashed var(--line-strong);
            border-radius: 6px;
            padding: 14px;
        }

        .page-empty {
            background: #ffffff;
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
            <div class="metric"><span class="label">CPU Cores In Scope</span><span class="value">$totalCores</span></div>
            <div class="metric"><span class="label">Windows Server VMs</span><span class="value">$totalVMs</span></div>
        </section>

        <section class="toolbar" aria-label="Report controls">
            <input id="filterBox" type="search" placeholder="Filter by vCenter, cluster, host, VM, power state, or OS">
            <button type="button" id="expandAll">Expand all</button>
            <button type="button" id="collapseAll">Collapse all</button>
            <button type="button" id="clearFilter">Clear filter</button>
        </section>

        <section class="note">
            Scope=ClusterWide includes every host in clusters that contain Windows Server VMs, plus standalone hosts running Windows Server VMs. Scope=HostOnly includes only hosts currently running Windows Server VMs. Each cluster row includes its vCenter, and CPU cores shown beside clusters are the sum of the visible hosts in that scope.
        </section>

        <section id="reportTree">
$($clusterHtml -join "`n")
        </section>
    </main>

    <script>
        const reportTree = document.getElementById('reportTree');
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
Write-Host " - Scope=ClusterWide includes all hosts in clusters containing Windows Server VMs, plus standalone hosts running Windows Server VMs."
Write-Host " - Scope=HostOnly includes only hosts currently running Windows Server VMs."
Write-Host " - Each cluster row includes the vCenter where that cluster was found."
Write-Host " - Cluster and host CPU counts show physical CPU cores for the hosts included in the selected scope."
