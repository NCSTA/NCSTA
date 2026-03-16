#Requires -Version 5.1
<#
.SYNOPSIS
    Logging module for ESXi-to-HyperV migration operations.
.DESCRIPTION
    Provides structured logging with transcript support. Writes timestamped entries
    to both console and a structured log collection for batch summary reporting.
#>

$script:LogEntries = [System.Collections.ArrayList]::new()
$script:LogPath    = $null

function Start-MigrationLog {
    <#
    .SYNOPSIS
        Initializes logging for a migration session.
    .PARAMETER LogDirectory
        Directory to write log files to.
    .PARAMETER SessionName
        Optional name for the session. Defaults to timestamp.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LogDirectory,

        [string]$SessionName
    )

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    if (-not $SessionName) {
        $SessionName = "Migration-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    }

    $script:LogPath = Join-Path $LogDirectory "$SessionName.log"
    $script:LogEntries.Clear()

    Start-Transcript -Path $script:LogPath -Append | Out-Null

    Write-MigrationLog -Message "Migration session started: $SessionName" -Level Info
}

function Write-MigrationLog {
    <#
    .SYNOPSIS
        Writes a timestamped log entry.
    .PARAMETER Message
        The log message.
    .PARAMETER Level
        Severity level: Info, Warning, Error, Success.
    .PARAMETER VMName
        Optional VM name to associate with the entry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info',

        [string]$VMName
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($VMName) { "[$timestamp] [$Level] [$VMName]" } else { "[$timestamp] [$Level]" }
    $fullMessage = "$prefix $Message"

    switch ($Level) {
        'Error'   { Write-Host $fullMessage -ForegroundColor Red }
        'Warning' { Write-Host $fullMessage -ForegroundColor Yellow }
        'Success' { Write-Host $fullMessage -ForegroundColor Green }
        default   { Write-Host $fullMessage -ForegroundColor Cyan }
    }

    $script:LogEntries.Add([PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        VMName    = $VMName
        Message   = $Message
    }) | Out-Null
}

function New-MigrationResult {
    <#
    .SYNOPSIS
        Creates a standardized migration result object.
    .PARAMETER VMName
        Name of the VM.
    .PARAMETER Status
        Migration status: Success, Failed, Skipped.
    .PARAMETER Phase
        Phase where result was determined.
    .PARAMETER ErrorMessage
        Error details if failed.
    .PARAMETER Duration
        Time elapsed for this VM's migration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Failed', 'Skipped')]
        [string]$Status,

        [string]$Phase,
        [string]$ErrorMessage,
        [timespan]$Duration
    )

    [PSCustomObject]@{
        VMName       = $VMName
        Status       = $Status
        Phase        = $Phase
        ErrorMessage = $ErrorMessage
        Duration     = if ($Duration) { $Duration.ToString('hh\:mm\:ss') } else { '' }
        CompletedAt  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

function Write-MigrationSummary {
    <#
    .SYNOPSIS
        Outputs a summary table of all migration results.
    .PARAMETER Results
        Array of migration result objects from New-MigrationResult.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Results
    )

    $total     = $Results.Count
    $succeeded = ($Results | Where-Object Status -eq 'Success').Count
    $failed    = ($Results | Where-Object Status -eq 'Failed').Count
    $skipped   = ($Results | Where-Object Status -eq 'Skipped').Count

    Write-Host ''
    Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor White
    Write-Host '  MIGRATION BATCH SUMMARY' -ForegroundColor White
    Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor White
    Write-Host "  Total: $total | " -NoNewline
    Write-Host "Success: $succeeded" -ForegroundColor Green -NoNewline
    Write-Host " | " -NoNewline
    Write-Host "Failed: $failed" -ForegroundColor Red -NoNewline
    Write-Host " | " -NoNewline
    Write-Host "Skipped: $skipped" -ForegroundColor Yellow
    Write-Host '═══════════════════════════════════════════════════════════' -ForegroundColor White
    Write-Host ''

    $Results | Format-Table -AutoSize VMName, Status, Phase, Duration, ErrorMessage
}

function Stop-MigrationLog {
    <#
    .SYNOPSIS
        Stops logging and exports structured log entries.
    .PARAMETER ExportCsv
        If specified, exports log entries to a CSV alongside the transcript.
    #>
    [CmdletBinding()]
    param(
        [switch]$ExportCsv
    )

    Write-MigrationLog -Message "Migration session complete." -Level Info

    if ($ExportCsv -and $script:LogPath) {
        $csvPath = $script:LogPath -replace '\.log$', '-entries.csv'
        $script:LogEntries | Export-Csv -Path $csvPath -NoTypeInformation
        Write-Host "Log entries exported to: $csvPath" -ForegroundColor Gray
    }

    try { Stop-Transcript | Out-Null } catch { }
}

Export-ModuleMember -Function Start-MigrationLog, Write-MigrationLog, New-MigrationResult,
                              Write-MigrationSummary, Stop-MigrationLog
