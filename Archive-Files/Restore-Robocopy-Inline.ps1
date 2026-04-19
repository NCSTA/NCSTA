# ============================================================================
#  Restore-Robocopy (inline / Script-Pane version)
# ----------------------------------------------------------------------------
#  Copies everything from the archive root back to the original share using
#  Robocopy. Skips any file that already exists at the destination — nothing
#  is overwritten.
#
#  Paste into the PowerShell ISE / VS Code script pane, edit CONFIG, press F5.
# ============================================================================

# --- CONFIG: edit these ----------------------------------------------------

# Where the archived files currently live.
$ArchiveRoot = 'G:\archives'

# Where to restore them (the original share root).
$DestinationRoot = 'G:\public'

# Robocopy log file.
$RobocopyLog = "C:\Temp\Robocopy-Restore-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

# $true  = preview only (adds /L flag, nothing is copied)
# $false = actually copy files back
$DryRun = $true

# ---------------------------------------------------------------------------

$robocopyArgs = @(
    $ArchiveRoot
    $DestinationRoot
    '/E'            # all subdirectories including empty
    '/XC'           # skip changed (existing) files
    '/XN'           # skip newer (existing) files
    '/XO'           # skip older (existing) files
    '/MT:4'         # multithreaded copy using 4 threads (matches server CPU count)
    '/NP'           # no progress percentage (cleaner log)
    "/LOG:$RobocopyLog"
)

if ($DryRun) {
    $robocopyArgs += '/L'
    Write-Host "*** DRY RUN - /L flag active, no files will be copied ***" -ForegroundColor Yellow
}

Write-Host "Running: robocopy $($robocopyArgs -join ' ')" -ForegroundColor Cyan
Write-Host ""

& robocopy @robocopyArgs

Write-Host ""
Write-Host "===== Complete =====" -ForegroundColor Green
Write-Host "Log: $RobocopyLog" -ForegroundColor Cyan
if ($DryRun) {
    Write-Host "(DryRun was `$true; remove /L or set `$DryRun = `$false to copy for real)" -ForegroundColor Yellow
}
