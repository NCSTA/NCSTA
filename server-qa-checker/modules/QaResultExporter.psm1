#Requires -Version 5.1
<#
.SYNOPSIS
    Server QA result export module.
.DESCRIPTION
    Exports QA validation results to HTML and CSV formats.
#>

function Export-QaResultsHtml {
    <#
    .SYNOPSIS
        Exports QA results to a styled HTML report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Results,

        [Parameter(Mandatory = $true)]
        [string]$TemplateName,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $passCount = ($Results | Where-Object { $_.Status -eq 'Pass' }).Count
    $failCount = ($Results | Where-Object { $_.Status -eq 'Fail' }).Count
    $warnCount = ($Results | Where-Object { $_.Status -eq 'Warn' }).Count
    $infoCount = ($Results | Where-Object { $_.Status -eq 'Info' }).Count
    $errorCount = ($Results | Where-Object { $_.Status -eq 'Error' }).Count
    $skipCount = ($Results | Where-Object { $_.Status -eq 'Skip' }).Count
    $gradedCount = $passCount + $failCount
    $pct = if ($gradedCount -gt 0) { [math]::Round(($passCount / $gradedCount) * 100) } else { 0 }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $statusColors = @{
        Pass  = '#a6e3a1'
        Fail  = '#f38ba8'
        Warn  = '#f9e2af'
        Info  = '#89b4fa'
        Error = '#f38ba8'
        Skip  = '#6c7086'
    }

    # Category groupings matching the GUI
    $categories = @(
        @{ Name = 'Connectivity';     Keys = @('connectivity') }
        @{ Name = 'Hardware';         Keys = @('cpu', 'memoryGB') }
        @{ Name = 'Network';          Keys = @('ipConfig', 'traceroute') }
        @{ Name = 'Software';         Keys = @('installedSoftware', 'vmwareTools') }
        @{ Name = 'Security';         Keys = @('localAdmins') }
        @{ Name = 'Storage';          Keys = @('drivePermissions', 'fDrive') }
        @{ Name = 'Patching';         Keys = @('recentHotfixes') }
        @{ Name = 'Active Directory'; Keys = @('ouPath') }
    )

    # Build collapsible category sections
    $sectionsHtml = ''
    foreach ($cat in $categories) {
        $catResults = @($Results | Where-Object { $_.CheckKey -in $cat.Keys -and $_.Status -ne 'Skip' })
        if ($catResults.Count -eq 0) { continue }

        # Count pass/fail for this category
        $catPass = ($catResults | Where-Object { $_.Status -eq 'Pass' }).Count
        $catFail = ($catResults | Where-Object { $_.Status -eq 'Fail' }).Count
        $catBadge = ''
        if ($catFail -gt 0) {
            $catBadge = " <span class=`"badge`" style=`"background:#f38ba8; margin-left:8px;`">$catFail FAIL</span>"
        } elseif ($catPass -gt 0) {
            $catBadge = " <span class=`"badge`" style=`"background:#a6e3a1; margin-left:8px;`">ALL PASS</span>"
        }

        $rowsHtml = ''
        $adapterSeen = $false
        foreach ($r in $catResults) {
            # Adapter separator for Network category
            if ($cat.Name -eq 'Network' -and $r.Category -eq 'Adapter') {
                if ($adapterSeen) {
                    $rowsHtml += "            <tr class=`"adapter-sep`"><td colspan=`"5`"></td></tr>`n"
                }
                $adapterSeen = $true
            }

            $bgColor = $statusColors[$r.Status]
            # Handle newlines in Actual and Details for HTML display
            $actualHtml = [System.Web.HttpUtility]::HtmlEncode($r.Actual) -replace "`n", '<br/>'
            $detailsHtml = [System.Web.HttpUtility]::HtmlEncode($r.Details) -replace "`n", '<br/>'
            $rowsHtml += @"
            <tr>
                <td>$($r.Category)</td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($r.Expected))</td>
                <td>$actualHtml</td>
                <td><span class="badge" style="background:$bgColor;">$($r.Status.ToUpper())</span></td>
                <td>$detailsHtml</td>
            </tr>
"@
        }

        $sectionsHtml += @"
<details open>
    <summary>$($cat.Name)$catBadge</summary>
    <table>
        <thead>
            <tr><th>Check</th><th>Expected</th><th>Actual</th><th>Status</th><th>Details</th></tr>
        </thead>
        <tbody>
$rowsHtml
        </tbody>
    </table>
</details>
"@
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>QA Report - $ComputerName</title>
<style>
    body { font-family: 'Segoe UI', sans-serif; background: #1e1e2e; color: #cdd6f4; margin: 0; padding: 20px; }
    h1 { color: #89b4fa; margin-bottom: 4px; }
    .meta { color: #a6adc8; font-size: 13px; margin-bottom: 20px; }
    .summary { display: flex; gap: 12px; margin-bottom: 20px; flex-wrap: wrap; }
    .summary .badge { padding: 6px 16px; border-radius: 4px; font-weight: 600; font-size: 13px; color: #1e1e2e; }
    .pct { color: #cdd6f4; font-size: 18px; font-weight: 700; align-self: center; margin-left: 12px; }
    details { margin-bottom: 12px; background: #181825; border: 1px solid #45475a; border-radius: 6px; overflow: hidden; }
    summary { background: #313244; color: #89b4fa; font-size: 15px; font-weight: 600; padding: 10px 16px; cursor: pointer; user-select: none; display: flex; align-items: center; list-style: none; }
    summary::-webkit-details-marker { display: none; }
    summary::before { content: '\25B6'; margin-right: 10px; font-size: 12px; transition: transform 0.2s; }
    details[open] > summary::before { content: '\25BC'; }
    summary:hover { background: #45475a; }
    table { width: 100%; border-collapse: collapse; table-layout: fixed; }
    th, td { word-wrap: break-word; overflow-wrap: break-word; }
    th:nth-child(1), td:nth-child(1) { width: 14%; }
    th:nth-child(2), td:nth-child(2) { width: 20%; }
    th:nth-child(3), td:nth-child(3) { width: 28%; }
    th:nth-child(4), td:nth-child(4) { width: 8%; }
    th:nth-child(5), td:nth-child(5) { width: 30%; }
    th { background: #1e1e2e; color: #89b4fa; text-align: left; padding: 8px 12px; font-weight: 600; font-size: 12px; }
    td { padding: 8px 12px; border-bottom: 1px solid #313244; font-size: 13px; vertical-align: top; }
    tr:nth-child(even) { background: #1e1e2e; }
    tr.adapter-sep td { padding: 0; height: 1px; border-bottom: 2px solid #45475a; background: transparent; }
    .badge { padding: 2px 10px; border-radius: 3px; font-weight: 600; font-size: 11px; color: #1e1e2e; display: inline-block; }
</style>
</head>
<body>
<h1>Server QA Report</h1>
<div class="meta">
    Server: <strong>$ComputerName</strong> | Template: <strong>$TemplateName</strong> | Generated: $timestamp
</div>
<div class="summary">
    <span class="badge" style="background:#a6e3a1;">Pass: $passCount</span>
    <span class="badge" style="background:#f38ba8;">Fail: $failCount</span>
    <span class="badge" style="background:#f9e2af;">Warn: $warnCount</span>
    <span class="badge" style="background:#89b4fa;">Info: $infoCount</span>
    <span class="badge" style="background:#6c7086;">Error: $errorCount</span>
    <span class="badge" style="background:#6c7086;">Skip: $skipCount</span>
    <span class="pct">$pct% Pass</span>
</div>
$sectionsHtml
</body>
</html>
"@

    $html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
}

function Export-QaResultsCsv {
    <#
    .SYNOPSIS
        Exports QA results to a CSV file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$Results,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $csvData = foreach ($r in $Results) {
        [PSCustomObject]@{
            Server       = $ComputerName
            Timestamp    = $timestamp
            Category     = $r.Category
            CheckKey     = $r.CheckKey
            Expected     = $r.Expected
            Actual       = $r.Actual
            Status       = $r.Status
            Details      = $r.Details
            ErrorMessage = $r.ErrorMessage
        }
    }

    $csvData | Export-Csv -Path $OutputPath -NoTypeInformation -Force -Encoding UTF8
}

Export-ModuleMember -Function Export-QaResultsHtml, Export-QaResultsCsv
