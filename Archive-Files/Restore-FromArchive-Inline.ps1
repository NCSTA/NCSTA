# ============================================================================
#  Restore-FromArchive (inline / Script-Pane version)
# ----------------------------------------------------------------------------
#  Scans the archive root (e.g. G:\archives) and moves every file back to
#  its original location by reversing the path transformation. Does NOT
#  depend on the archive log CSV — it walks the archive folder directly.
#
#  Paste into the PowerShell ISE / VS Code script pane, edit CONFIG, press F5.
# ============================================================================

# --- CONFIG: edit these ----------------------------------------------------

# Root folder where archived files currently live.
$ArchiveRoot = 'G:\archives'

# Original drive root the files came from.
# Files under G:\archives\public\Nasco\... are restored to G:\public\Nasco\...
$OriginalDriveRoot = 'G:\'

# Where to write this restore run's log (appended per entry, never lost).
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
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$OriginalPath,
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason = ''
    )
    $entry = [PSCustomObject]@{
        Timestamp    = (Get-Date).ToString('s')
        ArchivePath  = $ArchivePath
        OriginalPath = $OriginalPath
        Action       = $Action
        Reason       = $Reason
    }
    $entry | Export-Csv -LiteralPath $RestoreLogPath -Append -NoTypeInformation -Encoding UTF8
    $script:Log.Add($entry)
}

# --- Main ------------------------------------------------------------------

if ($DryRun) {
    Write-Host "*** DRY RUN - no files will be moved ***" -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $ArchiveRoot)) {
    throw "Archive root not found: $ArchiveRoot"
}

# Ensure log directory exists up front so per-entry appends don't fail.
$logParent = Split-Path -Path $RestoreLogPath -Parent
if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
    New-Item -ItemType Directory -Path $logParent -Force | Out-Null
}

Write-Host "Scanning archive root: $ArchiveRoot" -ForegroundColor Cyan
$files = @(Get-ChildItem -LiteralPath $ArchiveRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
$total = $files.Count
Write-Host "Found $total files to restore." -ForegroundColor Cyan

if ($total -eq 0) {
    Write-Host "Archive root is empty; nothing to restore." -ForegroundColor Yellow
    return
}

# Normalize the archive root for reliable substring operations.
$normalizedRoot = $ArchiveRoot.TrimEnd('\', '/')

$script:Log = [System.Collections.Generic.List[object]]::new()
$i = 0

try {
    foreach ($file in $files) {
        $i++
        $archivePath = $file.FullName

        Write-Progress -Activity 'Restoring from archive' `
            -Status "$i / $total  $archivePath" `
            -PercentComplete ([math]::Min(100, ($i / $total) * 100))

        try {
            # Compute original path by stripping the archive root and
            # prepending the original drive root.
            $relative     = $archivePath.Substring($normalizedRoot.Length).TrimStart('\', '/')
            $originalPath = Join-Path -Path $OriginalDriveRoot -ChildPath $relative

            if (Test-Path -LiteralPath $originalPath) {
                Add-LogEntry -ArchivePath $archivePath -OriginalPath $originalPath `
                    -Action 'Skipped' -Reason 'OriginalLocationOccupied'
                continue
            }

            $parent = Split-Path -Path $originalPath -Parent
            Ensure-Directory -Path $parent

            if ($DryRun) {
                Write-Host "  [DryRun] would restore: $archivePath -> $originalPath" -ForegroundColor DarkGray
            }
            else {
                Move-Item -LiteralPath $archivePath -Destination $originalPath -ErrorAction Stop
            }
            Add-LogEntry -ArchivePath $archivePath -OriginalPath $originalPath -Action 'Restored'
        }
        catch {
            Add-LogEntry -ArchivePath $archivePath -OriginalPath $originalPath `
                -Action 'Failed' -Reason $_.Exception.Message
        }
    }
}
finally {
    Write-Progress -Activity 'Restoring from archive' -Completed
}

# --- Summary ---------------------------------------------------------------

$restored = @($script:Log | Where-Object Action -EQ 'Restored').Count
$skipped  = @($script:Log | Where-Object Action -EQ 'Skipped').Count
$failed   = @($script:Log | Where-Object Action -EQ 'Failed').Count

Write-Host ""
Write-Host "===== Restore Summary =====" -ForegroundColor Green
Write-Host "Files found:   $total"
Write-Host "Restored:      $restored" -ForegroundColor Green
Write-Host "Skipped:       $skipped"  -ForegroundColor Yellow
Write-Host "Failed:        $failed"   -ForegroundColor Red
Write-Host "Log:           $RestoreLogPath" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "(DryRun was `$true; no files were actually moved)" -ForegroundColor Yellow
}
