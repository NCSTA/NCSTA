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

    $rowsHtml = ''
    foreach ($r in $Results) {
        $bgColor = $statusColors[$r.Status]
        $rowsHtml += @"
            <tr>
                <td>$($r.Category)</td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($r.Expected))</td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($r.Actual))</td>
                <td><span class="badge" style="background:$bgColor;">$($r.Status.ToUpper())</span></td>
                <td>$([System.Web.HttpUtility]::HtmlEncode($r.Details))</td>
            </tr>
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
    .summary { display: flex; gap: 12px; margin-bottom: 20px; }
    .summary .badge { padding: 6px 16px; border-radius: 4px; font-weight: 600; font-size: 13px; color: #1e1e2e; }
    .pct { color: #cdd6f4; font-size: 18px; font-weight: 700; align-self: center; margin-left: 12px; }
    table { width: 100%; border-collapse: collapse; background: #181825; }
    th { background: #313244; color: #89b4fa; text-align: left; padding: 10px 12px; font-weight: 600; }
    td { padding: 8px 12px; border-bottom: 1px solid #313244; }
    tr:nth-child(even) { background: #1e1e2e; }
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
<table>
    <thead>
        <tr><th>Category</th><th>Expected</th><th>Actual</th><th>Status</th><th>Details</th></tr>
    </thead>
    <tbody>
        $rowsHtml
    </tbody>
</table>
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
