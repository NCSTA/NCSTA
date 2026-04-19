# ============================================================================
#  Restore-FromArchive (inline / Script-Pane version)
# ----------------------------------------------------------------------------
#  Reverses a Move-ToArchive run by reading the log CSV it produced and
#  moving every successfully archived file back to its original location.
#
#  Paste into the PowerShell ISE / VS Code script pane, edit CONFIG, press F5.
# ============================================================================

# --- CONFIG: edit these ----------------------------------------------------

# Path to the log CSV produced by Move-ToArchive (the Move-ToArchive-Log-*.csv).
# It must contain columns: Path, Destination, Action.
$ArchiveLogPath = 'C:\Temp\Move-ToArchive-Log-20260419-120000.csv'

# Where to write this restore run's own log.
$RestoreLogPath = "C:\Temp\Restore-FromArchive-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

# $true  = preview only, nothing is moved
# $false = actually move files back
$DryRun = $true

# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($DryRun) {
            Write-Host "  [DryRun] would create directory: $Path" -ForegroundColor DarkGray
        }
        else {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Add-LogEntry {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason = ''
    )
    $script:Log.Add([PSCustomObject]@{
        Timestamp   = (Get-Date).ToString('s')
        ArchivePath = $Source
        OriginalPath = $Destination
        Action      = $Action
        Reason      = $Reason
    })
}

# --- Main ------------------------------------------------------------------

if ($DryRun) {
    Write-Host "*** DRY RUN - no files will be moved ***" -ForegroundColor Yellow
}

Write-Host "Loading archive log: $ArchiveLogPath" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $ArchiveLogPath -PathType Leaf)) {
    throw "Archive log not found: $ArchiveLogPath"
}

$allRows = @(Import-Csv -LiteralPath $ArchiveLogPath)
Write-Host "Loaded $($allRows.Count) total log entries." -ForegroundColor Cyan

$columns = $allRows[0].PSObject.Properties.Name
foreach ($required in @('Path', 'Destination', 'Action')) {
    if ($columns -notcontains $required) {
        throw "Log CSV is missing required column '$required'. Found: $($columns -join ', ')"
    }
}

# Only restore rows that were actually moved (skip rows that were Skipped/Failed).
$rows  = @($allRows | Where-Object { $_.Action -eq 'Moved' -and $_.Destination -ne '' })
$total = $rows.Count
Write-Host "Found $total rows with Action = 'Moved' to restore." -ForegroundColor Cyan

if ($total -eq 0) {
    Write-Host "Nothing to restore." -ForegroundColor Yellow
    return
}

$script:Log = [System.Collections.Generic.List[object]]::new()
$i = 0

try {
    foreach ($row in $rows) {
        $i++
        $archivePath  = $row.Destination.Trim()   # file currently lives here (in archives)
        $originalPath = $row.Path.Trim()           # where it came from originally

        Write-Progress -Activity 'Restoring from archive' `
            -Status "$i / $total  $archivePath" `
            -PercentComplete ([math]::Min(100, ($i / $total) * 100))

        try {
            # Verify the archived copy still exists.
            if (-not (Test-Path -LiteralPath $archivePath)) {
                Add-LogEntry -Source $archivePath -Destination $originalPath `
                    -Action 'Skipped' -Reason 'ArchiveFileNotFound'
                continue
            }

            # If the original location already has a file (shouldn't happen, but be safe).
            if (Test-Path -LiteralPath $originalPath) {
                Add-LogEntry -Source $archivePath -Destination $originalPath `
                    -Action 'Skipped' -Reason 'OriginalLocationOccupied'
                continue
            }

            # Ensure the original parent directory exists.
            $parent = Split-Path -Path $originalPath -Parent
            Ensure-Directory -Path $parent

            if ($DryRun) {
                Write-Host "  [DryRun] would restore: $archivePath -> $originalPath" -ForegroundColor DarkGray
            }
            else {
                Move-Item -LiteralPath $archivePath -Destination $originalPath -ErrorAction Stop
            }
            Add-LogEntry -Source $archivePath -Destination $originalPath -Action 'Restored'
        }
        catch {
            Add-LogEntry -Source $archivePath -Destination $originalPath `
                -Action 'Failed' -Reason $_.Exception.Message
        }
    }
}
finally {
    Write-Progress -Activity 'Restoring from archive' -Completed

    if ($script:Log.Count -gt 0) {
        $logParent = Split-Path -Path $RestoreLogPath -Parent
        if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
            New-Item -ItemType Directory -Path $logParent -Force | Out-Null
        }
        $script:Log | Export-Csv -LiteralPath $RestoreLogPath -NoTypeInformation -Encoding UTF8
    }
}

# --- Summary ---------------------------------------------------------------

$restored = @($script:Log | Where-Object Action -EQ 'Restored').Count
$skipped  = @($script:Log | Where-Object Action -EQ 'Skipped').Count
$failed   = @($script:Log | Where-Object Action -EQ 'Failed').Count

Write-Host ""
Write-Host "===== Restore Summary =====" -ForegroundColor Green
Write-Host "Eligible rows: $total"
Write-Host "Restored:      $restored" -ForegroundColor Green
Write-Host "Skipped:       $skipped"  -ForegroundColor Yellow
Write-Host "Failed:        $failed"   -ForegroundColor Red
Write-Host "Log:           $RestoreLogPath" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "(DryRun was `$true; no files were actually moved)" -ForegroundColor Yellow
}
