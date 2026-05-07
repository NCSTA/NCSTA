[CmdletBinding()]
param(
    [string[]]$Domains = @(
        # Add domains here, or pass -Domains when running the script.
        # 'contoso.com'
    ),

    [string]$OutputDirectory = 'C:\temp'
)

$ErrorActionPreference = 'Stop'

foreach ($moduleName in @('ActiveDirectory', 'ImportExcel')) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Error "$moduleName module is required. Please install it before running this script."
        exit 1
    }
}

Import-Module ActiveDirectory
Import-Module ImportExcel

function Get-ServerOsFamily {
    param(
        [AllowNull()]
        [string]$OperatingSystem
    )

    if ([string]::IsNullOrWhiteSpace($OperatingSystem)) {
        return 'Unknown'
    }

    switch -Regex ($OperatingSystem) {
        '2025' { return 'Windows Server 2025' }
        '2022' { return 'Windows Server 2022' }
        '2019' { return 'Windows Server 2019' }
        '2016' { return 'Windows Server 2016' }
        '2012\s*R2' { return 'Windows Server 2012 R2' }
        '2012' { return 'Windows Server 2012' }
        '2008\s*R2' { return 'Windows Server 2008 R2' }
        '2008' { return 'Windows Server 2008' }
        '2003' { return 'Windows Server 2003' }
        default {
            if ($OperatingSystem -match 'Windows.*Server') {
                return 'Other Windows Server'
            }

            return 'Other / Unknown'
        }
    }
}

function Get-SafeWorksheetName {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [hashtable]$UsedNames
    )

    if ($null -eq $UsedNames) {
        $UsedNames = @{}
    }

    $baseName = $Name -replace '[:\\\/\?\*\[\]]', '_'
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = 'Domain'
    }

    if ($baseName.Length -gt 31) {
        $baseName = $baseName.Substring(0, 31)
    }

    $candidate = $baseName
    $suffix = 2
    while ($UsedNames.ContainsKey($candidate.ToLowerInvariant())) {
        $suffixText = "_$suffix"
        $maxBaseLength = 31 - $suffixText.Length
        $candidate = $baseName.Substring(0, [Math]::Min($baseName.Length, $maxBaseLength)) + $suffixText
        $suffix++
    }

    $UsedNames[$candidate.ToLowerInvariant()] = $true
    return $candidate
}

function Get-SafeExcelTableName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $tableName = $Name -replace '[^A-Za-z0-9_]', '_'
    if ($tableName -notmatch '^[A-Za-z_]') {
        $tableName = "T_$tableName"
    }

    return $tableName
}

function New-CountRows {
    param(
        [object[]]$InputObjects,

        [Parameter(Mandatory)]
        [string]$PropertyName,

        [Parameter(Mandatory)]
        [string]$OutputName
    )

    if ($null -eq $InputObjects) {
        $InputObjects = @()
    }

    @($InputObjects |
        Group-Object -Property $PropertyName |
        Sort-Object @{Expression = 'Count'; Descending = $true}, @{Expression = 'Name'; Ascending = $true} |
        ForEach-Object {
            [PSCustomObject]@{
                $OutputName = $_.Name
                Count = $_.Count
            }
        })
}

function ConvertTo-EmbeddedJson {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = [string]($InputObject | ConvertTo-Json -Depth 8 -Compress)

    $json `
        -replace '<', '\u003c' `
        -replace '>', '\u003e' `
        -replace '&', '\u0026'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputFile = Join-Path $OutputDirectory "AD_Servers_Export_$timestamp.xlsx"
$htmlFile = Join-Path $OutputDirectory "AD_Servers_Report_$timestamp.html"

$allServers = @()
$queryResults = @()
$usedSheetNames = @{}

Write-Host "Starting server export from $($Domains.Count) domains..." -ForegroundColor Cyan

foreach ($domain in $Domains) {
    Write-Host "`nProcessing domain: $domain" -ForegroundColor Green

    try {
        $servers = Get-ADComputer -Server $domain -Filter * -Properties Name, DNSHostName, IPv4Address, OperatingSystem, Enabled -ErrorAction Stop |
            Where-Object {
                ($_.OperatingSystem -like 'Windows*server*') -and
                ($_.Name -like '*v') -and
                ($_.Name -notlike '*z') -and
                ($_.Name -notlike '*l') -and
                ($_.Enabled -eq $true)
            }

        $filteredServers = @($servers | Where-Object {
            $name = $_.Name
            -not ($name -match '[zl]$' -or $name -match 'z\d{2}$')
        })

        $exportData = @($filteredServers | ForEach-Object {
            $operatingSystem = if ($_.OperatingSystem) { $_.OperatingSystem } else { 'Unknown' }

            [PSCustomObject]@{
                Hostname = $_.Name
                Domain = $domain
                DNSHostName = if ($_.DNSHostName) { $_.DNSHostName } else { 'N/A' }
                IP = if ($_.IPv4Address) { $_.IPv4Address } else { 'N/A' }
                OperatingSystem = $operatingSystem
                OSFamily = Get-ServerOsFamily -OperatingSystem $operatingSystem
            }
        })

        foreach ($server in $exportData) {
            $allServers += $server
        }

        if ($exportData.Count -gt 0) {
            $sheetName = Get-SafeWorksheetName -Name $domain -UsedNames $usedSheetNames
            $tableName = Get-SafeExcelTableName -Name "Servers_$sheetName"

            $exportData |
                Select-Object Hostname, Domain, DNSHostName, IP,
                    @{Name = 'Operating System'; Expression = { $_.OperatingSystem }},
                    @{Name = 'OS Family'; Expression = { $_.OSFamily }} |
                Export-Excel -Path $outputFile -WorksheetName $sheetName -AutoSize -TableName $tableName -FreezeTopRow -BoldTopRow -TableStyle Medium2

            Write-Host "  Exported $($exportData.Count) servers (filtered from $($servers.Count) total)" -ForegroundColor White
        }
        else {
            Write-Host '  No servers found in this domain' -ForegroundColor Yellow
        }

        $queryResults += [PSCustomObject]@{
            Domain = $domain
            Status = 'Success'
            MatchedBeforeFinalFilter = @($servers).Count
            ExportedServers = $exportData.Count
            Error = ''
        }
    }
    catch {
        Write-Host "  ERROR accessing domain: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.InvocationInfo.ScriptLineNumber) {
            Write-Host "  Failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkYellow
        }

        $queryResults += [PSCustomObject]@{
            Domain = $domain
            Status = 'Error'
            MatchedBeforeFinalFilter = 0
            ExportedServers = 0
            Error = $_.Exception.Message
        }
    }
}

$allServerRows = @($allServers)
$queryResultRows = @($queryResults)
$osTotals = New-CountRows -InputObjects $allServerRows -PropertyName 'OSFamily' -OutputName 'OS Family'
$domainTotals = New-CountRows -InputObjects $allServerRows -PropertyName 'Domain' -OutputName 'Domain'
$rawOsTotals = New-CountRows -InputObjects $allServerRows -PropertyName 'OperatingSystem' -OutputName 'Operating System'
$domainOsBreakdown = @($allServerRows |
    Group-Object -Property Domain, OSFamily |
    Sort-Object @{Expression = 'Count'; Descending = $true}, @{Expression = 'Name'; Ascending = $true} |
    ForEach-Object {
        $parts = $_.Name -split ', ', 2
        [PSCustomObject]@{
            Domain = $parts[0]
            'OS Family' = if ($parts.Count -gt 1) { $parts[1] } else { 'Unknown' }
            Count = $_.Count
        }
    })

$overviewRows = @(
    [PSCustomObject]@{ Metric = 'Generated At'; Value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') }
    [PSCustomObject]@{ Metric = 'Domains Queried'; Value = [string]$Domains.Count }
    [PSCustomObject]@{ Metric = 'Domains With Servers'; Value = [string]@($domainTotals).Count }
    [PSCustomObject]@{ Metric = 'Total Servers'; Value = [string]$allServerRows.Count }
    [PSCustomObject]@{ Metric = 'Servers Missing IP'; Value = [string]@($allServerRows | Where-Object { $_.IP -eq 'N/A' }).Count }
    [PSCustomObject]@{ Metric = 'Query Errors'; Value = [string]@($queryResultRows | Where-Object { $_.Status -eq 'Error' }).Count }
)

$overviewRows | Export-Excel -Path $outputFile -WorksheetName 'Overview' -AutoSize -TableName 'Overview' -FreezeTopRow -BoldTopRow -TableStyle Medium2

if ($osTotals.Count -gt 0) {
    $osTotals | Export-Excel -Path $outputFile -WorksheetName 'OS Totals' -AutoSize -TableName 'OSTotals' -FreezeTopRow -BoldTopRow -TableStyle Medium2
}

if ($rawOsTotals.Count -gt 0) {
    $rawOsTotals | Export-Excel -Path $outputFile -WorksheetName 'Raw OS Totals' -AutoSize -TableName 'RawOSTotals' -FreezeTopRow -BoldTopRow -TableStyle Medium2
}

if ($domainTotals.Count -gt 0) {
    $domainTotals | Export-Excel -Path $outputFile -WorksheetName 'Domain Totals' -AutoSize -TableName 'DomainTotals' -FreezeTopRow -BoldTopRow -TableStyle Medium2
}

if ($domainOsBreakdown.Count -gt 0) {
    $domainOsBreakdown | Export-Excel -Path $outputFile -WorksheetName 'Domain OS Breakdown' -AutoSize -TableName 'DomainOSBreakdown' -FreezeTopRow -BoldTopRow -TableStyle Medium2
}

if ($queryResultRows.Count -gt 0) {
    $queryResultRows | Export-Excel -Path $outputFile -WorksheetName 'Query Results' -AutoSize -TableName 'QueryResults' -FreezeTopRow -BoldTopRow -TableStyle Medium2
}

$reportData = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    totalServers = $allServerRows.Count
    domainsQueried = $Domains.Count
    domainsWithServers = @($domainTotals).Count
    serversMissingIp = @($allServerRows | Where-Object { $_.IP -eq 'N/A' }).Count
    queryErrors = @($queryResultRows | Where-Object { $_.Status -eq 'Error' }).Count
    servers = @($allServerRows | Sort-Object Domain, OSFamily, Hostname)
    queryResults = @($queryResultRows)
}

$json = ConvertTo-EmbeddedJson -InputObject $reportData

$htmlTemplate = @'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>AD Windows Server Report</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0d1117;
      --panel: #151b23;
      --panel-2: #1f2732;
      --border: #303947;
      --text: #e6edf3;
      --muted: #9aa7b4;
      --accent: #2f81f7;
      --accent-2: #41b883;
      --warn: #d29922;
      --bad: #f85149;
      --shadow: rgba(0, 0, 0, .24);
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font-family: "Segoe UI", Arial, sans-serif;
      font-size: 14px;
      line-height: 1.45;
    }

    header {
      border-bottom: 1px solid var(--border);
      background: #10161f;
      padding: 24px 28px;
    }

    main {
      padding: 24px 28px 36px;
      max-width: 1600px;
      margin: 0 auto;
    }

    h1, h2 {
      margin: 0;
      letter-spacing: 0;
    }

    h1 {
      font-size: 28px;
      font-weight: 700;
    }

    h2 {
      font-size: 17px;
      font-weight: 650;
      margin-bottom: 12px;
    }

    .subhead {
      color: var(--muted);
      margin-top: 6px;
    }

    .metric-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
      margin-bottom: 18px;
    }

    .metric, .section {
      background: var(--panel);
      border: 1px solid var(--border);
      border-radius: 8px;
      box-shadow: 0 12px 30px var(--shadow);
    }

    .metric {
      padding: 14px 16px;
      min-height: 86px;
    }

    .metric .label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
    }

    .metric .value {
      font-size: 28px;
      font-weight: 750;
      margin-top: 8px;
    }

    .section {
      padding: 16px;
      margin-top: 16px;
    }

    .filters {
      display: grid;
      grid-template-columns: minmax(220px, 1.2fr) minmax(220px, 1.2fr) minmax(260px, 2fr) auto;
      gap: 12px;
      align-items: end;
    }

    label {
      display: block;
      color: var(--muted);
      font-size: 12px;
      margin-bottom: 6px;
    }

    select, input, button {
      width: 100%;
      min-height: 38px;
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--panel-2);
      color: var(--text);
      padding: 8px 10px;
      font: inherit;
    }

    button {
      cursor: pointer;
      background: var(--accent);
      border-color: var(--accent);
      font-weight: 650;
      white-space: nowrap;
    }

    .two-column {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 16px;
    }

    .table-wrap {
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      min-width: 520px;
    }

    th, td {
      border-bottom: 1px solid var(--border);
      padding: 9px 10px;
      text-align: left;
      vertical-align: top;
      white-space: nowrap;
    }

    th {
      position: sticky;
      top: 0;
      background: #19212d;
      color: #c9d7e3;
      z-index: 1;
      font-size: 12px;
      text-transform: uppercase;
    }

    tr:last-child td {
      border-bottom: 0;
    }

    .bar-cell {
      min-width: 180px;
      width: 34%;
    }

    .bar {
      height: 10px;
      background: #263240;
      border-radius: 999px;
      overflow: hidden;
    }

    .bar span {
      display: block;
      height: 100%;
      background: linear-gradient(90deg, var(--accent), var(--accent-2));
    }

    .status-success {
      color: var(--accent-2);
      font-weight: 650;
    }

    .status-error {
      color: var(--bad);
      font-weight: 650;
    }

    .muted {
      color: var(--muted);
    }

    @media (max-width: 900px) {
      header, main {
        padding-left: 16px;
        padding-right: 16px;
      }

      .filters, .two-column {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <h1>AD Windows Server Report</h1>
    <div class="subhead" id="generatedAt"></div>
  </header>

  <main>
    <section class="metric-grid" id="metricGrid"></section>

    <section class="section">
      <h2>Filters</h2>
      <div class="filters">
        <div>
          <label for="domainFilter">Domain</label>
          <select id="domainFilter"></select>
        </div>
        <div>
          <label for="osFilter">OS Family</label>
          <select id="osFilter"></select>
        </div>
        <div>
          <label for="searchFilter">Search hostname, DNS, IP, domain, OS</label>
          <input id="searchFilter" type="search" placeholder="Type to filter">
        </div>
        <button id="resetFilters" type="button">Reset</button>
      </div>
    </section>

    <section class="two-column">
      <div class="section">
        <h2>OS Totals</h2>
        <div class="table-wrap" id="osTotals"></div>
      </div>
      <div class="section">
        <h2>Domain Totals</h2>
        <div class="table-wrap" id="domainTotals"></div>
      </div>
    </section>

    <section class="section">
      <h2>Domain By OS</h2>
      <div class="table-wrap" id="domainOsMatrix"></div>
    </section>

    <section class="section">
      <h2>Server Details</h2>
      <div class="table-wrap" id="serverDetails"></div>
    </section>

    <section class="section">
      <h2>Query Results</h2>
      <div class="table-wrap" id="queryResults"></div>
    </section>
  </main>

  <script id="report-data" type="application/json">__REPORT_JSON__</script>
  <script>
    const report = JSON.parse(document.getElementById('report-data').textContent);
    const servers = report.servers || [];
    const queryResults = report.queryResults || [];

    const domainFilter = document.getElementById('domainFilter');
    const osFilter = document.getElementById('osFilter');
    const searchFilter = document.getElementById('searchFilter');

    document.getElementById('generatedAt').textContent = `Generated ${report.generatedAt}`;

    function escapeHtml(value) {
      return String(value ?? '').replace(/[&<>"']/g, char => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
      }[char]));
    }

    function uniqueValues(items, key) {
      return [...new Set(items.map(item => item[key]).filter(Boolean))]
        .sort((a, b) => String(a).localeCompare(String(b)));
    }

    function setOptions(select, values, allLabel) {
      select.innerHTML = `<option value="">${escapeHtml(allLabel)}</option>` +
        values.map(value => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`).join('');
    }

    function groupCount(items, key) {
      const map = new Map();
      for (const item of items) {
        const value = item[key] || 'Unknown';
        map.set(value, (map.get(value) || 0) + 1);
      }

      return [...map.entries()]
        .map(([name, count]) => ({ name, count }))
        .sort((a, b) => b.count - a.count || String(a.name).localeCompare(String(b.name)));
    }

    function filteredServers() {
      const domain = domainFilter.value;
      const os = osFilter.value;
      const search = searchFilter.value.trim().toLowerCase();

      return servers.filter(server => {
        if (domain && server.Domain !== domain) return false;
        if (os && server.OSFamily !== os) return false;

        if (search) {
          const haystack = [
            server.Hostname,
            server.Domain,
            server.DNSHostName,
            server.IP,
            server.OperatingSystem,
            server.OSFamily
          ].join(' ').toLowerCase();

          if (!haystack.includes(search)) return false;
        }

        return true;
      });
    }

    function renderMetrics(items) {
      const domains = uniqueValues(items, 'Domain').length;
      const osFamilies = uniqueValues(items, 'OSFamily').length;
      const missingIp = items.filter(item => item.IP === 'N/A').length;
      const errorCount = queryResults.filter(item => item.Status === 'Error').length;

      const metrics = [
        ['Visible Servers', items.length],
        ['Total Servers', report.totalServers],
        ['Domains In View', domains],
        ['OS Types In View', osFamilies],
        ['Missing IP In View', missingIp],
        ['Query Errors', errorCount]
      ];

      document.getElementById('metricGrid').innerHTML = metrics.map(([label, value]) => `
        <div class="metric">
          <div class="label">${escapeHtml(label)}</div>
          <div class="value">${escapeHtml(value)}</div>
        </div>
      `).join('');
    }

    function renderBarTable(targetId, rows, labelHeader) {
      const total = rows.reduce((sum, row) => sum + row.count, 0) || 1;
      const body = rows.length
        ? rows.map(row => `
            <tr>
              <td>${escapeHtml(row.name)}</td>
              <td>${escapeHtml(row.count)}</td>
              <td class="bar-cell"><div class="bar"><span style="width:${(row.count / total) * 100}%"></span></div></td>
            </tr>
          `).join('')
        : '<tr><td colspan="3" class="muted">No matching data</td></tr>';

      document.getElementById(targetId).innerHTML = `
        <table>
          <thead><tr><th>${escapeHtml(labelHeader)}</th><th>Count</th><th>Share</th></tr></thead>
          <tbody>${body}</tbody>
        </table>
      `;
    }

    function renderDomainOsMatrix(items) {
      const domains = uniqueValues(items, 'Domain');
      const osFamilies = uniqueValues(items, 'OSFamily');
      const counts = new Map();

      for (const item of items) {
        const key = `${item.Domain}|||${item.OSFamily}`;
        counts.set(key, (counts.get(key) || 0) + 1);
      }

      const rows = domains.map(domain => {
        const cells = osFamilies.map(os => counts.get(`${domain}|||${os}`) || 0);
        const total = cells.reduce((sum, count) => sum + count, 0);
        return { domain, cells, total };
      }).sort((a, b) => b.total - a.total || a.domain.localeCompare(b.domain));

      const head = '<th>Domain</th>' + osFamilies.map(os => `<th>${escapeHtml(os)}</th>`).join('') + '<th>Total</th>';
      const body = rows.length
        ? rows.map(row => `
            <tr>
              <td>${escapeHtml(row.domain)}</td>
              ${row.cells.map(count => `<td>${count || ''}</td>`).join('')}
              <td>${row.total}</td>
            </tr>
          `).join('')
        : `<tr><td colspan="${osFamilies.length + 2}" class="muted">No matching data</td></tr>`;

      document.getElementById('domainOsMatrix').innerHTML = `
        <table>
          <thead><tr>${head}</tr></thead>
          <tbody>${body}</tbody>
        </table>
      `;
    }

    function renderServerDetails(items) {
      const body = items.length
        ? items.map(server => `
            <tr>
              <td>${escapeHtml(server.Hostname)}</td>
              <td>${escapeHtml(server.Domain)}</td>
              <td>${escapeHtml(server.DNSHostName)}</td>
              <td>${escapeHtml(server.IP)}</td>
              <td>${escapeHtml(server.OSFamily)}</td>
              <td>${escapeHtml(server.OperatingSystem)}</td>
            </tr>
          `).join('')
        : '<tr><td colspan="6" class="muted">No matching servers</td></tr>';

      document.getElementById('serverDetails').innerHTML = `
        <table>
          <thead>
            <tr>
              <th>Hostname</th>
              <th>Domain</th>
              <th>DNS Hostname</th>
              <th>IP</th>
              <th>OS Family</th>
              <th>Operating System</th>
            </tr>
          </thead>
          <tbody>${body}</tbody>
        </table>
      `;
    }

    function renderQueryResults() {
      const body = queryResults.length
        ? queryResults.map(result => {
            const statusClass = result.Status === 'Error' ? 'status-error' : 'status-success';
            return `
              <tr>
                <td>${escapeHtml(result.Domain)}</td>
                <td class="${statusClass}">${escapeHtml(result.Status)}</td>
                <td>${escapeHtml(result.MatchedBeforeFinalFilter)}</td>
                <td>${escapeHtml(result.ExportedServers)}</td>
                <td>${escapeHtml(result.Error)}</td>
              </tr>
            `;
          }).join('')
        : '<tr><td colspan="5" class="muted">No domains were queried</td></tr>';

      document.getElementById('queryResults').innerHTML = `
        <table>
          <thead>
            <tr>
              <th>Domain</th>
              <th>Status</th>
              <th>Matched Before Final Filter</th>
              <th>Exported Servers</th>
              <th>Error</th>
            </tr>
          </thead>
          <tbody>${body}</tbody>
        </table>
      `;
    }

    function render() {
      const items = filteredServers();
      renderMetrics(items);
      renderBarTable('osTotals', groupCount(items, 'OSFamily'), 'OS Family');
      renderBarTable('domainTotals', groupCount(items, 'Domain'), 'Domain');
      renderDomainOsMatrix(items);
      renderServerDetails(items);
    }

    setOptions(domainFilter, uniqueValues(servers, 'Domain'), 'All domains');
    setOptions(osFilter, uniqueValues(servers, 'OSFamily'), 'All OS families');

    domainFilter.addEventListener('change', render);
    osFilter.addEventListener('change', render);
    searchFilter.addEventListener('input', render);
    document.getElementById('resetFilters').addEventListener('click', () => {
      domainFilter.value = '';
      osFilter.value = '';
      searchFilter.value = '';
      render();
    });

    renderQueryResults();
    render();
  </script>
</body>
</html>
'@

$htmlTemplate.Replace('__REPORT_JSON__', [string]$json) | Set-Content -Path $htmlFile -Encoding UTF8

Write-Host "`nExport complete!" -ForegroundColor Cyan
Write-Host "Excel file saved to: $outputFile" -ForegroundColor Cyan
Write-Host "HTML report saved to: $htmlFile" -ForegroundColor Cyan
