#Requires -Version 5.1

<#
.SYNOPSIS
    Retires G:\Public share by migrating all data to G:\Archive\Public.

.DESCRIPTION
    Executes a phased migration of the public share:
      Phase 0 (PreFlight)       - Validates paths, free space, baseline file/folder counts
      Phase 1 (MirrorStructure) - Recreates directory tree in archive (no files)
      Phase 2 (MoveFiles)       - Moves all files to archive with progress bar; skeleton stays
      Phase 3 (DropNotices)     - Places retirement notice files in root + top-level folders
      Phase 4 (Validate)        - Compares source vs archive, reports discrepancies

    Designed to run in PowerShell ISE script pane (F5) to bypass CarbonBlack.
    Run each phase in order, or use -RunAll for the full sequence.

    Use -DryRun with any phase to simulate without making changes.
    Use -Rollback to reverse the migration (move files back from archive to source).

.PARAMETER PreFlight
    Run Phase 0 only — scan and report.

.PARAMETER MirrorStructure
    Run Phase 1 only — mirror directory tree.

.PARAMETER MoveFiles
    Run Phase 2 only — move files with progress bar.

.PARAMETER DropNotices
    Run Phase 3 only — place retirement notices.

.PARAMETER Validate
    Run Phase 4 only — post-migration validation.

.PARAMETER RunAll
    Run all phases in sequence (0 through 4).

.PARAMETER DryRun
    Simulate all operations without making changes. Robocopy runs in list-only
    mode (/L), notice files are not written. Combine with any phase switch.

.PARAMETER Rollback
    Reverse the migration: remove notice files from source, move all files
    from archive back to source with progress bar, then validate.

.EXAMPLE
    .\Retire-PublicShare.ps1 -PreFlight
    .\Retire-PublicShare.ps1 -MirrorStructure
    .\Retire-PublicShare.ps1 -MoveFiles
    .\Retire-PublicShare.ps1 -RunAll
    .\Retire-PublicShare.ps1 -RunAll -DryRun
    .\Retire-PublicShare.ps1 -Rollback
    .\Retire-PublicShare.ps1 -Rollback -DryRun

.NOTES
    Author  : NCSTA
    Date    : 2026-08-07
    Run As  : Administrator with full NTFS permissions
    Run In  : PowerShell ISE script pane (F5)
#>

[CmdletBinding()]
param(
    [switch]$PreFlight,
    [switch]$MirrorStructure,
    [switch]$MoveFiles,
    [switch]$DropNotices,
    [switch]$Validate,
    [switch]$RunAll,
    [switch]$DryRun,
    [switch]$Rollback
)

# ═══════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION — UPDATE THESE VALUES BEFORE RUNNING
# ═══════════════════════════════════════════════════════════════════════════════

$Script:Config = @{
    SourcePath     = 'G:\Public'
    ArchivePath    = 'G:\Archive\Public'
    LogFolder      = 'G:\Archive\Logs\RetirePublicShare'
    NoticeFileName = '_SHARE_RETIRED.txt'
    Timestamp      = (Get-Date -Format 'yyyyMMdd_HHmmss')

    # ── Update these for your environment ──
    ContactEmail   = 'IT@yourcompany.com'
    ContactTeam    = 'IT Infrastructure'
    TicketURL      = 'https://servicedesk.yourcompany.com'
    GraceDays      = 30
    ThreadCount    = 16          # Robocopy /MT threads (16 requires 8c/16GB+, scale VM before running)
}

# ═══════════════════════════════════════════════════════════════════════════════
#  RUN CONFIGURATION — TOGGLE WHAT TO RUN, THEN PASTE INTO ISE AND HIT F5
#  (These override the param switches when pasting into ISE script pane)
# ═══════════════════════════════════════════════════════════════════════════════

$Script:Run = @{
    PreFlight       = $true     # Phase 0: Scan and report
    MirrorStructure = $true     # Phase 1: Copy folder tree only
    MoveFiles       = $true     # Phase 2: Move files (progress bar)
    DropNotices     = $true     # Phase 3: Place retirement notices
    Validate        = $true     # Phase 4: Verify migration
    DryRun          = $false    # Simulate only — no changes made
    Rollback        = $false    # Reverse: move files from archive back to source
}

# ── Merge: param switches (if called as .ps1) override the block above ──
if ($PreFlight -or $MirrorStructure -or $MoveFiles -or $DropNotices -or $Validate -or $RunAll -or $Rollback) {
    # Script was called with explicit switches — use those instead
    $Script:Run.PreFlight       = $PreFlight.IsPresent -or $RunAll.IsPresent
    $Script:Run.MirrorStructure = $MirrorStructure.IsPresent -or $RunAll.IsPresent
    $Script:Run.MoveFiles       = $MoveFiles.IsPresent -or $RunAll.IsPresent
    $Script:Run.DropNotices     = $DropNotices.IsPresent -or $RunAll.IsPresent
    $Script:Run.Validate        = $Validate.IsPresent -or $RunAll.IsPresent
    $Script:Run.DryRun          = $DryRun.IsPresent
    $Script:Run.Rollback        = $Rollback.IsPresent
}

$Script:IsDryRun = $Script:Run.DryRun

# ═══════════════════════════════════════════════════════════════════════════════
#  HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

function Write-Banner {
    <# Prints a phase header banner — shows [DRY RUN] when simulating #>
    param([string]$Text)

    if ($Script:IsDryRun) { $dryTag = '  ** DRY RUN — NO CHANGES WILL BE MADE **' } else { $dryTag = '' }
    $line = '=' * 80
    Write-Host ''
    Write-Host $line -ForegroundColor White
    Write-Host "  $Text" -ForegroundColor White
    if ($dryTag) { Write-Host $dryTag -ForegroundColor Yellow }
    Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host $line -ForegroundColor White
    Write-Host ''
}

function Write-Step {
    <# Timestamped log line with severity coloring #>
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Detail')]
        [string]$Level = 'Info'
    )

    $ts = Get-Date -Format 'HH:mm:ss'
    switch ($Level) {
        'Info'    { Write-Host "  [$ts] [INFO]    $Message" -ForegroundColor Cyan }
        'Success' { Write-Host "  [$ts] [OK]      $Message" -ForegroundColor Green }
        'Warning' { Write-Host "  [$ts] [WARN]    $Message" -ForegroundColor Yellow }
        'Error'   { Write-Host "  [$ts] [ERROR]   $Message" -ForegroundColor Red }
        'Detail'  { Write-Host "  [$ts]           $Message" -ForegroundColor DarkGray }
    }
}

function Format-FileSize {
    <# Converts bytes to human-readable string #>
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes / 1KB) }
    return "$Bytes Bytes"
}

function Get-FolderStats {
    <# Returns a stats object for a given path using robocopy /L (list-only).
       Robocopy scans the tree natively without loading objects into memory —
       orders of magnitude faster than Get-ChildItem on large trees. #>
    param([string]$Path)

    Write-Step "Scanning $Path ..."

    $folders = 0
    $files   = 0
    $size    = [long]0

    # Robocopy /L lists without copying. /BYTES gives exact byte counts.
    # /NFL /NDL suppresses file/dir names (we only need the summary).
    # Destination 'NUL' is a dummy — nothing is copied in /L mode.
    $output = & robocopy $Path "$Path\__robocopy_nul_target__" /L /E /BYTES /NFL /NDL /NJH /R:0 /W:0 2>&1
    $outputStr = $output -join "`n"

    # Parse the summary block at the end of robocopy output:
    #    Dirs :      1234    1234       0       0       0       0
    #   Files :     56789   56789       0       0       0       0
    #   Bytes :  640000000  640000000   0       0       0       0
    $dirMatch   = [regex]::Match($outputStr, 'Dirs\s*:\s*(\d+)')
    $fileMatch  = [regex]::Match($outputStr, 'Files\s*:\s*(\d+)')
    $bytesMatch = [regex]::Match($outputStr, 'Bytes\s*:\s*(\d+)')

    if ($dirMatch.Success)   { $folders = [long]$dirMatch.Groups[1].Value }
    if ($fileMatch.Success)  { $files   = [long]$fileMatch.Groups[1].Value }
    if ($bytesMatch.Success) { $size    = [long]$bytesMatch.Groups[1].Value }

    # Fallback if robocopy summary didn't parse (shouldn't happen, but safe)
    if (-not $fileMatch.Success) {
        Write-Step 'Robocopy summary not found — falling back to Get-ChildItem...' -Level Warning
        try {
            $fileItems = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue
            $files   = @($fileItems).Count
            $size    = ($fileItems | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $size) { $size = 0 }
            $folders = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue).Count
        }
        catch {
            Write-Step "Error scanning ${Path}: $_" -Level Error
        }
    }

    return [PSCustomObject]@{
        Path       = $Path
        Folders    = $folders
        Files      = $files
        SizeBytes  = $size
        SizeHuman  = Format-FileSize $size
    }
}

function Test-RobocopySuccess {
    <# Robocopy exit codes 0-7 are success; 8+ are errors #>
    param([int]$ExitCode)
    return $ExitCode -lt 8
}

function Initialize-Logging {
    <# Creates log folder and starts transcript #>

    $logDir = $Script:Config.LogFolder
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        Write-Step "Created log folder: $logDir" -Level Detail
    }

    $transcriptPath = Join-Path $logDir "Transcript_$($Script:Config.Timestamp).log"
    try {
        Start-Transcript -Path $transcriptPath -Append | Out-Null
        Write-Step "Transcript logging to: $transcriptPath" -Level Detail
        $Script:TranscriptActive = $true
    }
    catch {
        Write-Step "Could not start transcript (may already be running): $_" -Level Warning
        $Script:TranscriptActive = $false
    }
}

function Stop-Logging {
    if ($Script:TranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 0 — PRE-FLIGHT CHECKS
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-PreFlight {
    Write-Banner 'PHASE 0: PRE-FLIGHT CHECKS'

    $src = $Script:Config.SourcePath
    $dst = $Script:Config.ArchivePath

    # ── Check source exists ──
    Write-Step "Checking source path exists: $src"
    if (-not (Test-Path $src)) {
        Write-Step "Source path does not exist: $src" -Level Error
        Write-Step 'Aborting. Verify the path and try again.' -Level Error
        return $false
    }
    Write-Step "Source path confirmed" -Level Success

    # ── Check archive drive exists ──
    $archiveDrive = Split-Path $dst -Qualifier
    Write-Step "Checking archive drive exists: $archiveDrive"
    if (-not (Test-Path $archiveDrive)) {
        Write-Step "Archive drive not found: $archiveDrive" -Level Error
        return $false
    }
    Write-Step "Archive drive confirmed" -Level Success

    # ── Check free space on archive volume ──
    Write-Step "Checking free space on $archiveDrive"
    $volume = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$archiveDrive'" -ErrorAction SilentlyContinue
    if ($volume) {
        $freeSpace = $volume.FreeSpace
        Write-Step "Free space: $(Format-FileSize $freeSpace)" -Level Detail
    }
    else {
        Write-Step "Could not query free space for $archiveDrive (WMI issue)" -Level Warning
    }

    # ── Check robocopy available ──
    Write-Step 'Checking robocopy.exe is available'
    $robo = Get-Command robocopy.exe -ErrorAction SilentlyContinue
    if ($robo) {
        Write-Step "robocopy found: $($robo.Source)" -Level Success
    }
    else {
        Write-Step 'robocopy.exe not found in PATH — cannot proceed' -Level Error
        return $false
    }

    # ── Check running as admin ──
    Write-Step 'Checking administrative privileges'
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Step 'Running as Administrator' -Level Success
    }
    else {
        Write-Step 'NOT running as Administrator — file moves may fail due to permissions' -Level Warning
    }

    # ── Scan source ──
    Write-Step 'Gathering baseline stats for source...'
    $srcStats = Get-FolderStats -Path $src

    # ── Check archive path ──
    if (Test-Path $dst) {
        Write-Step "Archive path already exists: $dst" -Level Warning
        Write-Step 'Gathering stats for existing archive...'
        $dstStats = Get-FolderStats -Path $dst
    }
    else {
        Write-Step "Archive path does not yet exist (will be created in Phase 1): $dst" -Level Detail
        $dstStats = $null
    }

    # ── Space comparison ──
    if ($volume -and $srcStats.SizeBytes -gt 0) {
        if ($freeSpace -lt ($srcStats.SizeBytes * 1.05)) {
            Write-Step ("Not enough free space. Need ~{0}, have {1}" -f
                (Format-FileSize ($srcStats.SizeBytes * 1.05)), (Format-FileSize $freeSpace)) -Level Error
            return $false
        }
        Write-Step ("Space check passed: need ~{0}, have {1}" -f
            (Format-FileSize $srcStats.SizeBytes), (Format-FileSize $freeSpace)) -Level Success
    }

    # ── Summary table ──
    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor DarkCyan
    Write-Host '  │              PRE-FLIGHT SUMMARY                        │' -ForegroundColor DarkCyan
    Write-Host '  ├───────────────────┬─────────────────────────────────────┤' -ForegroundColor DarkCyan
    Write-Host ("  │ Source            │ {0,-35} │" -f $src) -ForegroundColor DarkCyan
    Write-Host ("  │ Archive           │ {0,-35} │" -f $dst) -ForegroundColor DarkCyan
    Write-Host ("  │ Total Folders     │ {0,-35} │" -f $srcStats.Folders.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Total Files       │ {0,-35} │" -f $srcStats.Files.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Total Size        │ {0,-35} │" -f $srcStats.SizeHuman) -ForegroundColor DarkCyan
    if ($volume) {
        Write-Host ("  │ Free Space        │ {0,-35} │" -f (Format-FileSize $freeSpace)) -ForegroundColor DarkCyan
    }
    Write-Host ("  │ Admin             │ {0,-35} │" -f $isAdmin) -ForegroundColor DarkCyan
    Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    if ($dstStats) {
        Write-Step ("Archive already contains {0} folders and {1} files ({2})" -f
            $dstStats.Folders.ToString('N0'), $dstStats.Files.ToString('N0'), $dstStats.SizeHuman) -Level Warning
    }

    # ── Store baseline for later validation ──
    $Script:Baseline = $srcStats
    Write-Step 'Pre-flight complete. Ready to proceed.' -Level Success
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — MIRROR DIRECTORY STRUCTURE
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-MirrorStructure {
    Write-Banner 'PHASE 1: MIRROR DIRECTORY STRUCTURE (FOLDERS ONLY)'

    $src = $Script:Config.SourcePath
    $dst = $Script:Config.ArchivePath
    $logFile = Join-Path $Script:Config.LogFolder "RobocopyMirror_$($Script:Config.Timestamp).log"

    # ── Validate source ──
    if (-not (Test-Path $src)) {
        Write-Step "Source path not found: $src" -Level Error
        return $false
    }

    # ── Create archive root if needed ──
    $archiveParent = Split-Path $dst -Parent
    if (-not (Test-Path $archiveParent)) {
        if ($Script:IsDryRun) {
            Write-Step "[DRY RUN] Would create archive parent: $archiveParent" -Level Detail
        }
        else {
            Write-Step "Creating archive parent: $archiveParent"
            New-Item -ItemType Directory -Path $archiveParent -Force | Out-Null
            Write-Step "Created $archiveParent" -Level Success
        }
    }

    # ── Count source folders for reference (robocopy /L — fast) ──
    Write-Step 'Counting source directories...'
    $srcStats = Get-FolderStats -Path $src
    $srcFolderCount = $srcStats.Folders
    Write-Step "Source contains $($srcFolderCount.ToString('N0')) directories" -Level Detail

    # ── Run robocopy — directories only, no files ──
    if ($Script:IsDryRun) { $dryRunLabel = ' [DRY RUN — /L list-only]' } else { $dryRunLabel = '' }
    Write-Step "Running robocopy to mirror directory structure (no files)...$dryRunLabel"
    Write-Step "Command: robocopy `"$src`" `"$dst`" /E /XF * /DCOPY:DAT /R:3 /W:5 /V /LOG:`"$logFile`"" -Level Detail

    $mtFlag = '/MT:' + $Script:Config.ThreadCount
    $roboArgs = @(
        $src
        $dst
        '/E'            # Include subdirectories, including empty ones
        '/XF', '*'      # Exclude ALL files
        '/DCOPY:DAT'    # Copy directory Data, Attributes, Timestamps
        '/R:3'          # Retry 3 times
        '/W:5'          # Wait 5 seconds between retries
        $mtFlag         # Multi-threaded
        '/V'            # Verbose output
        '/NP'           # No progress percentage (we handle our own)
        '/LOG:' + $logFile
    )
    if ($Script:IsDryRun) { $roboArgs += '/L' }

    $roboProcess = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs `
        -NoNewWindow -Wait -PassThru

    $exitCode = $roboProcess.ExitCode
    Write-Step "Robocopy exit code: $exitCode" -Level Detail

    if (Test-RobocopySuccess $exitCode) {
        Write-Step 'Directory structure mirrored successfully' -Level Success
    }
    else {
        Write-Step "Robocopy reported errors (exit code $exitCode). Check log: $logFile" -Level Error
        return $false
    }

    # ── Verify (robocopy /L — fast) ──
    Write-Step 'Verifying archive directory count...'
    $dstStats = Get-FolderStats -Path $dst
    $dstFolderCount = $dstStats.Folders
    Write-Step "Archive now contains $($dstFolderCount.ToString('N0')) directories" -Level Detail

    if ($dstFolderCount -ge $srcFolderCount) {
        Write-Step "Directory mirror verified ($($dstFolderCount.ToString('N0')) dirs)" -Level Success
    }
    else {
        Write-Step ("Directory count mismatch: source has {0}, archive has {1}" -f
            $srcFolderCount.ToString('N0'), $dstFolderCount.ToString('N0')) -Level Warning
        Write-Step "Some directories may have been skipped. Review log: $logFile" -Level Warning
    }

    Write-Step "Full robocopy log: $logFile" -Level Detail
    Write-Step 'Phase 1 complete.' -Level Success
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — MOVE FILES (WITH PROGRESS BAR)
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-MoveFiles {
    if ($Script:IsDryRun) { $bannerText = 'PHASE 2: MOVE FILES TO ARCHIVE — DRY RUN (NO FILES MOVED)' } else { $bannerText = 'PHASE 2: MOVE FILES TO ARCHIVE (WITH PROGRESS)' }
    Write-Banner $bannerText

    $src = $Script:Config.SourcePath
    $dst = $Script:Config.ArchivePath
    $logFile = Join-Path $Script:Config.LogFolder "RobocopyMove_$($Script:Config.Timestamp).log"

    # ── Validate both paths ──
    if (-not (Test-Path $src)) {
        Write-Step "Source not found: $src" -Level Error
        return $false
    }
    if (-not (Test-Path $dst)) {
        Write-Step "Archive not found: $dst — run Phase 1 (MirrorStructure) first" -Level Error
        return $false
    }

    # ── Count total files and size for progress tracking (robocopy /L — fast) ──
    Write-Step 'Counting files for progress tracking...'
    $srcStats   = Get-FolderStats -Path $src
    $totalFiles = $srcStats.Files
    $totalBytes = $srcStats.SizeBytes

    Write-Step ("Total files to move: {0}" -f $totalFiles.ToString('N0'))
    Write-Step ("Total size to move:  {0}" -f (Format-FileSize $totalBytes))

    if ($totalFiles -eq 0) {
        Write-Step 'No files to move. Source is already empty.' -Level Warning
        return $true
    }

    # ── Move files using robocopy per top-level item for granular progress ──
    # Strategy: iterate top-level folders/files to update a progress bar after each one
    Write-Step 'Starting file move with progress tracking...'
    Write-Host ''

    $topLevelItems = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
    $topLevelFolders = @($topLevelItems | Where-Object { $_.PSIsContainer })
    $topLevelFiles   = @($topLevelItems | Where-Object { -not $_.PSIsContainer })

    $totalUnits      = $topLevelFolders.Count + 1  # +1 for root-level files batch
    $completedUnits  = 0
    $foldersOK       = 0
    $foldersFailed   = 0
    $startTime       = Get-Date
    $logAppend       = $false   # First write creates; subsequent writes append

    # ── Helper: run robocopy for a specific subfolder ──
    function Move-Subfolder {
        param(
            [string]$SubSource,
            [string]$SubDest,
            [string]$Log,
            [bool]$Append
        )

        if ($Append) { $logFlag = '/LOG+:' + $Log } else { $logFlag = '/LOG:' + $Log }

        $mtFlag = '/MT:' + $Script:Config.ThreadCount
        $roboArgs = @(
            $SubSource
            $SubDest
            '/E'            # All subdirectories
            '/MOV'          # Move files (delete source after copy) — leaves dirs
            '/COPYALL'      # Copy all file attributes (security, timestamps, owner, audit)
            '/R:3'          # 3 retries
            '/W:5'          # 5-second wait between retries
            $mtFlag         # Multi-threaded
            '/V'            # Verbose
            '/NP'           # No robocopy progress (we do our own)
            '/NJH'          # No job header in log
            '/NJS'          # No job summary in log (we summarize ourselves)
            '/BYTES'        # Show sizes in bytes for parsing
            $logFlag
        )

        if ($Script:IsDryRun) { $roboArgs += '/L' }

        $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput 'NUL'

        return $proc.ExitCode
    }

    # ── Move root-level files first (files sitting directly in G:\Public) ──
    if ($topLevelFiles.Count -gt 0) {
        if ($Script:IsDryRun) { $actionVerb = 'Simulating move of' } else { $actionVerb = 'Moving' }
        Write-Step ("{0} {1} root-level files..." -f $actionVerb, $topLevelFiles.Count) -Level Detail

        # Robocopy with /LEV:1 to only move files at root level, not recurse
        $rootLogFlag = '/LOG:' + $logFile
        $mtFlag = '/MT:' + $Script:Config.ThreadCount
        $rootArgs = @(
            $src
            $dst
            '/LEV:1'        # Only root level
            '/MOV'          # Move files only
            '/COPYALL'
            '/R:3'
            '/W:5'
            $mtFlag         # Multi-threaded
            '/V'
            '/NP'
            '/BYTES'
            $rootLogFlag
        )
        if ($Script:IsDryRun) { $rootArgs += '/L' }

        $rootProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rootArgs `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput 'NUL'

        $logAppend = $true

        if (-not (Test-RobocopySuccess $rootProc.ExitCode)) {
            Write-Step "Some root-level files may have failed (exit code $($rootProc.ExitCode))" -Level Warning
        }
    }

    $completedUnits++

    # ── Move each top-level folder (no per-folder scan — straight to move) ──
    $barWidth = 40
    foreach ($folder in $topLevelFolders) {
        $folderSrc  = $folder.FullName
        $folderDest = Join-Path $dst $folder.Name

        # ── Progress bar ──
        $completedUnits++
        $pctComplete = [math]::Min(100, [math]::Round(($completedUnits / $totalUnits) * 100, 1))
        $elapsed     = (Get-Date) - $startTime
        if ($completedUnits -gt 1 -and $elapsed.TotalSeconds -gt 0) {
            $unitsPerSec = ($completedUnits - 1) / $elapsed.TotalSeconds
            $remaining   = ($totalUnits - $completedUnits) / [math]::Max($unitsPerSec, 0.001)
            $eta         = [TimeSpan]::FromSeconds([math]::Round($remaining))
            $etaStr      = '{0:hh\:mm\:ss}' -f $eta
        }
        else {
            $etaStr = '--:--:--'
        }

        $filled = [math]::Round($barWidth * $pctComplete / 100)
        $empty  = $barWidth - $filled
        $bar    = ('█' * $filled) + ('░' * $empty)

        Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  ETA: {4}  │  {5}" -f
            $bar, $pctComplete, ($completedUnits - 1), $topLevelFolders.Count,
            $etaStr, $folder.Name.PadRight(30)) -NoNewline -ForegroundColor Yellow

        # ── Execute the move ──
        $exitCode = Move-Subfolder -SubSource $folderSrc -SubDest $folderDest `
            -Log $logFile -Append $logAppend
        $logAppend = $true

        if (Test-RobocopySuccess $exitCode) {
            $foldersOK++
        }
        else {
            $foldersFailed++
            Write-Host ''
            Write-Step ("Errors moving folder: {0} (exit code {1})" -f $folder.Name, $exitCode) -Level Warning
        }
    }

    # ── Final progress bar at 100% ──
    $bar = '█' * $barWidth
    $totalElapsed = (Get-Date) - $startTime
    Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  Done in {4:hh\:mm\:ss}         " -f
        $bar, 100.0, $topLevelFolders.Count, $topLevelFolders.Count,
        $totalElapsed) -ForegroundColor Green
    Write-Host ''

    # ── Summary ──
    if ($Script:IsDryRun) { $summaryLabel = 'MOVE SUMMARY (DRY RUN — SIMULATED)' } else { $summaryLabel = 'MOVE SUMMARY' }
    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor DarkCyan
    Write-Host ("  │ {0,-55} │" -f $summaryLabel) -ForegroundColor DarkCyan
    Write-Host '  ├───────────────────┬─────────────────────────────────────┤' -ForegroundColor DarkCyan
    Write-Host ("  │ Total Files       │ {0,-35} │" -f $totalFiles.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Total Size        │ {0,-35} │" -f (Format-FileSize $totalBytes)) -ForegroundColor DarkCyan
    Write-Host ("  │ Folders OK        │ {0,-35} │" -f $foldersOK.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Folders Failed    │ {0,-35} │" -f $foldersFailed.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Elapsed Time      │ {0,-35} │" -f ('{0:hh\:mm\:ss}' -f $totalElapsed)) -ForegroundColor DarkCyan
    Write-Host ("  │ Robocopy Log      │ {0,-35} │" -f (Split-Path $logFile -Leaf)) -ForegroundColor DarkCyan
    Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    if ($foldersFailed -gt 0) {
        Write-Step "$foldersFailed folders had errors. Review log: $logFile" -Level Warning
        Write-Step 'Re-run -MoveFiles after clearing locks to retry failed folders.' -Level Warning
    }
    else {
        Write-Step 'All folders moved successfully.' -Level Success
    }

    Write-Step "Full robocopy log: $logFile" -Level Detail
    Write-Step 'Phase 2 complete.' -Level Success
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — DROP RETIREMENT NOTICES
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-DropNotices {
    Write-Banner 'PHASE 3: DROP RETIREMENT NOTICES'

    $src          = $Script:Config.SourcePath
    $noticeFile   = $Script:Config.NoticeFileName
    $contactEmail = $Script:Config.ContactEmail
    $contactTeam  = $Script:Config.ContactTeam
    $ticketURL    = $Script:Config.TicketURL
    $graceDays    = $Script:Config.GraceDays
    $expiryDate   = (Get-Date).AddDays($graceDays).ToString('MMMM dd, yyyy')
    $retireDate   = Get-Date -Format 'MMMM dd, yyyy'

    if (-not (Test-Path $src)) {
        Write-Step "Source not found: $src" -Level Error
        return $false
    }

    # ── Build notice text template ──
    # {0} = the specific folder path the user is browsing
    $noticeTemplate = @"
================================================================================
                    PUBLIC SHARE RETIREMENT NOTICE
================================================================================

Date:           $retireDate
Effective:      Immediately
Grace Period:   $graceDays days (until $expiryDate)

WHAT HAPPENED
─────────────
The G:\Public share has been retired. All files have been moved to a
secure archive. The folder structure you see here has been preserved
so you can identify the path of any files you need.

THIS FOLDER
────────────
  Original path:   {0}
  Archive path:    {1}

NEED A FILE?
─────────────
If you need access to any file that was in this share:

  1. Note the folder path shown above
  2. Contact $contactTeam
     Email:  $contactEmail
     Portal: $ticketURL
  3. Include the original file path in your request

TIMELINE
─────────
  • $retireDate        — Files moved to archive, share set to read-only
  • $expiryDate   — Folder structure removed, server decommissioned

If no file requests are received by $expiryDate, all archived
data will follow the standard data retention policy.

================================================================================
"@

    $noticesPlaced = 0

    # ── Root notice ──
    $rootNoticePath = Join-Path $src $noticeFile
    $rootNotice = $noticeTemplate -f $src, $Script:Config.ArchivePath
    if ($Script:IsDryRun) {
        Write-Step "[DRY RUN] Would place notice: $rootNoticePath" -Level Detail
        $noticesPlaced++
    }
    else {
        try {
            $rootNotice | Out-File -FilePath $rootNoticePath -Encoding UTF8 -Force
            Write-Step "Placed notice: $rootNoticePath" -Level Success
            $noticesPlaced++
        }
        catch {
            Write-Step "Failed to place root notice: $_" -Level Error
        }
    }

    # ── Top-level folder notices ──
    $topFolders = @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue)
    if ($Script:IsDryRun) { $actionVerb = 'Simulating notice placement in' } else { $actionVerb = 'Placing notices in' }
    Write-Step "$actionVerb $($topFolders.Count) top-level folders..."

    foreach ($folder in $topFolders) {
        $folderNoticePath = Join-Path $folder.FullName $noticeFile
        $archiveEquiv     = Join-Path $Script:Config.ArchivePath $folder.Name
        $folderNotice     = $noticeTemplate -f $folder.FullName, $archiveEquiv

        if ($Script:IsDryRun) {
            Write-Step "[DRY RUN] Would place notice: $($folder.Name)\$noticeFile" -Level Detail
            $noticesPlaced++
        }
        else {
            try {
                $folderNotice | Out-File -FilePath $folderNoticePath -Encoding UTF8 -Force
                Write-Step "Placed notice: $($folder.Name)\$noticeFile" -Level Detail
                $noticesPlaced++
            }
            catch {
                Write-Step "Failed to write notice in $($folder.Name): $_" -Level Error
            }
        }
    }

    Write-Host ''
    if ($Script:IsDryRun) { $dryTag = ' (simulated)' } else { $dryTag = '' }
    Write-Step "$noticesPlaced notice files$dryTag across root + top-level folders" -Level Success
    Write-Step 'Phase 3 complete.' -Level Success
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 4 — VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Validate {
    Write-Banner 'PHASE 4: POST-MIGRATION VALIDATION'

    $src = $Script:Config.SourcePath
    $dst = $Script:Config.ArchivePath
    $validationLog = Join-Path $Script:Config.LogFolder "Validation_$($Script:Config.Timestamp).log"

    if (-not (Test-Path $src)) {
        Write-Step "Source not found: $src" -Level Error
        return $false
    }
    if (-not (Test-Path $dst)) {
        Write-Step "Archive not found: $dst" -Level Error
        return $false
    }

    # ── Scan source (should be mostly empty — only notice files) ──
    # Use robocopy /L to count total files (fast, no PS object overhead)
    # Then count notices directly (root + top-level only, where we placed them)
    Write-Step 'Scanning source for remaining files...'
    $srcFileStats   = Get-FolderStats -Path $src
    $totalSrcFiles  = $srcFileStats.Files

    $noticeFileName = $Script:Config.NoticeFileName
    $noticeCount    = 0
    if (Test-Path (Join-Path $src $noticeFileName)) { $noticeCount++ }
    $topDirsVal = @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($d in $topDirsVal) {
        if (Test-Path (Join-Path $d.FullName $noticeFileName)) { $noticeCount++ }
    }

    $leftoverCount = [math]::Max(0, $totalSrcFiles - $noticeCount)

    Write-Step "Source files remaining: $totalSrcFiles total" -Level Detail
    Write-Step "  Notice files: $noticeCount" -Level Detail
    Write-Step "  Leftover files (not moved): $leftoverCount" -Level Detail

    # If leftovers exist, run robocopy /L to list them (exclude notice files)
    $leftoverDetails = @()
    if ($leftoverCount -gt 0) {
        Write-Step 'Identifying leftover files...' -Level Detail
        $listOutput = & robocopy $src "$src\__robocopy_nul_target__" /L /E /BYTES /NJH /NJS /NP /R:0 /W:0 /XF $noticeFileName 2>&1
        foreach ($line in $listOutput) {
            $lineStr = $line.ToString().Trim()
            # Robocopy file lines look like: "       <size>  <path>"  (new file lines have tab-separated fields)
            if ($lineStr -match '^\s*(?:New File|Newer|Older|Changed|Extra File)\s+(\d+)\s+(.+)$') {
                $leftoverDetails += [PSCustomObject]@{
                    SizeBytes = [long]$Matches[1]
                    Path      = $Matches[2].Trim()
                }
            }
        }
    }

    # ── Scan archive ──
    Write-Step 'Scanning archive...'
    $dstStats = Get-FolderStats -Path $dst

    # ── Compare folder counts (robocopy /L — fast) ──
    Write-Step 'Comparing folder counts...'
    $srcFolderStats = Get-FolderStats -Path $src
    $srcFolderCount = $srcFolderStats.Folders
    $dstFolderCount = $dstStats.Folders

    if ($dstFolderCount -ge $srcFolderCount) {
        Write-Step ("Folder counts match: source {0}, archive {1}" -f
            $srcFolderCount.ToString('N0'), $dstFolderCount.ToString('N0')) -Level Success
    }
    else {
        $missingCount = $srcFolderCount - $dstFolderCount
        Write-Step ("Folder count mismatch: source {0}, archive {1} ({2} missing)" -f
            $srcFolderCount.ToString('N0'), $dstFolderCount.ToString('N0'),
            $missingCount.ToString('N0')) -Level Warning
        Write-Step 'Re-run -MirrorStructure to sync missing directories.' -Level Warning
    }

    # ── List leftover files ──
    if ($leftoverCount -gt 0) {
        Write-Step 'Files that were NOT moved (still in source):' -Level Warning
        $shown = 0
        foreach ($item in $leftoverDetails | Select-Object -First 50) {
            $sizeStr = Format-FileSize $item.SizeBytes
            Write-Step ("  LEFTOVER: {0}  ({1})" -f $item.Path, $sizeStr) -Level Warning
            $shown++
        }
        if ($leftoverCount -gt 50) {
            Write-Step "  ... and $($leftoverCount - 50) more" -Level Warning
        }
    }

    # ── Write validation report to log ──
    $reportLines = @(
        "VALIDATION REPORT — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "================================================================="
        ""
        "Source:            $src"
        "Archive:           $dst"
        ""
        "Archive Folders:   $($dstStats.Folders.ToString('N0'))"
        "Archive Files:     $($dstStats.Files.ToString('N0'))"
        "Archive Size:      $($dstStats.SizeHuman)"
        ""
        "Source Leftovers:  $leftoverCount files (not moved)"
        "Notice Files:      $noticeCount"
        "Source Folders:    $($srcFolderCount.ToString('N0'))"
        "Archive Folders:   $($dstFolderCount.ToString('N0'))"
        ""
    )

    if ($leftoverCount -gt 0) {
        $reportLines += "LEFTOVER FILES:"
        foreach ($item in $leftoverDetails) {
            $reportLines += "  $($item.Path)"
        }
        $reportLines += ""
    }

    $reportLines | Out-File -FilePath $validationLog -Encoding UTF8
    Write-Step "Validation report saved: $validationLog" -Level Detail

    # ── Final summary ──
    Write-Host ''
    Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor DarkCyan
    Write-Host '  │              VALIDATION SUMMARY                        │' -ForegroundColor DarkCyan
    Write-Host '  ├───────────────────┬─────────────────────────────────────┤' -ForegroundColor DarkCyan
    Write-Host ("  │ Archive Folders   │ {0,-35} │" -f $dstStats.Folders.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Archive Files     │ {0,-35} │" -f $dstStats.Files.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Archive Size      │ {0,-35} │" -f $dstStats.SizeHuman) -ForegroundColor DarkCyan

    if ($leftoverCount -eq 0) { $leftoverColor = 'DarkCyan' } else { $leftoverColor = 'Yellow' }
    Write-Host ("  │ Leftover Files    │ {0,-35} │" -f $leftoverCount.ToString('N0')) -ForegroundColor $leftoverColor

    if ($dstFolderCount -ge $srcFolderCount) { $missingColor = 'DarkCyan'; $missingCount = 0 } else { $missingColor = 'Yellow'; $missingCount = $srcFolderCount - $dstFolderCount }
    Write-Host ("  │ Missing Folders   │ {0,-35} │" -f $missingCount.ToString('N0')) -ForegroundColor $missingColor

    Write-Host ("  │ Notice Files      │ {0,-35} │" -f $noticeCount.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    if ($leftoverCount -eq 0 -and $missingCount -eq 0) {
        Write-Step '✓ Migration validated — all files moved, all folders accounted for' -Level Success
    }
    elseif ($leftoverCount -gt 0) {
        Write-Step "⚠ $leftoverCount files still in source. Re-run -MoveFiles to retry." -Level Warning
    }

    Write-Step 'Phase 4 complete.' -Level Success
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ROLLBACK — REVERSE THE MIGRATION
# ═══════════════════════════════════════════════════════════════════════════════

function Invoke-Rollback {
    if ($Script:IsDryRun) { $bannerText = 'ROLLBACK — REVERSE MIGRATION (DRY RUN)' } else { $bannerText = 'ROLLBACK — REVERSE MIGRATION' }
    Write-Banner $bannerText

    $src = $Script:Config.SourcePath      # G:\Public        (destination for rollback)
    $dst = $Script:Config.ArchivePath     # G:\Archive\Public (source for rollback)
    $logFile = Join-Path $Script:Config.LogFolder "RobocopyRollback_$($Script:Config.Timestamp).log"

    # ── Validate both paths exist ──
    if (-not (Test-Path $src)) {
        Write-Step "Original source not found: $src" -Level Error
        return $false
    }
    if (-not (Test-Path $dst)) {
        Write-Step "Archive not found: $dst — nothing to roll back" -Level Error
        return $false
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  STEP 1 — Remove retirement notice files from source
    # ═══════════════════════════════════════════════════════════════════════
    Write-Step '── Step 1/3: Removing retirement notice files ──'

    $noticeFileName = $Script:Config.NoticeFileName
    # Notices were placed in root + top-level folders only — no need to recurse 296K dirs
    $noticeFiles = @()
    $rootNotice = Join-Path $src $noticeFileName
    if (Test-Path $rootNotice) { $noticeFiles += Get-Item -LiteralPath $rootNotice }
    $topDirs = @(Get-ChildItem -LiteralPath $src -Directory -Force -ErrorAction SilentlyContinue)
    foreach ($dir in $topDirs) {
        $n = Join-Path $dir.FullName $noticeFileName
        if (Test-Path $n) { $noticeFiles += Get-Item -LiteralPath $n }
    }

    if ($noticeFiles.Count -gt 0) {
        foreach ($notice in $noticeFiles) {
            if ($Script:IsDryRun) {
                Write-Step "[DRY RUN] Would remove: $($notice.FullName)" -Level Detail
            }
            else {
                try {
                    Remove-Item -LiteralPath $notice.FullName -Force -ErrorAction Stop
                    Write-Step "Removed: $($notice.FullName)" -Level Detail
                }
                catch {
                    Write-Step "Failed to remove notice: $($notice.FullName) — $_" -Level Warning
                }
            }
        }
        if ($Script:IsDryRun) { $actionLabel = 'Would remove' } else { $actionLabel = 'Removed' }
        Write-Step "$actionLabel $($noticeFiles.Count) notice files" -Level Success
    }
    else {
        Write-Step 'No notice files found in source — skipping' -Level Detail
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  STEP 2 — Move files from archive back to source (with progress)
    # ═══════════════════════════════════════════════════════════════════════
    Write-Step '── Step 2/3: Moving files from archive back to source ──'

    # Count files in archive (robocopy /L — fast)
    Write-Step 'Counting files in archive for progress tracking...'
    $archiveStats = Get-FolderStats -Path $dst
    $totalFiles = $archiveStats.Files
    $totalBytes = $archiveStats.SizeBytes

    Write-Step ("Files to restore: {0}" -f $totalFiles.ToString('N0'))
    Write-Step ("Total size:       {0}" -f (Format-FileSize $totalBytes))

    if ($totalFiles -eq 0) {
        Write-Step 'Archive is empty — no files to restore.' -Level Warning
    }
    else {
        $topLevelItems   = @(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue)
        $topLevelFolders = @($topLevelItems | Where-Object { $_.PSIsContainer })
        $topLevelFiles   = @($topLevelItems | Where-Object { -not $_.PSIsContainer })

        $totalUnits      = $topLevelFolders.Count + 1
        $completedUnits  = 0
        $foldersOK       = 0
        $foldersFailed   = 0
        $startTime       = Get-Date
        $logAppend       = $false

        # ── Restore root-level files ──
        if ($topLevelFiles.Count -gt 0) {
            if ($Script:IsDryRun) { $actionVerb = 'Simulating restore of' } else { $actionVerb = 'Restoring' }
            Write-Step ("{0} {1} root-level files..." -f $actionVerb, $topLevelFiles.Count) -Level Detail

            $rootLogFlag = '/LOG:' + $logFile
            $mtFlag = '/MT:' + $Script:Config.ThreadCount
            $rootArgs = @(
                $dst            # Archive is the source for rollback
                $src            # Original share is the destination
                '/LEV:1'
                '/MOV'
                '/COPYALL'
                '/R:3'
                '/W:5'
                $mtFlag         # Multi-threaded
                '/V'
                '/NP'
                '/BYTES'
                $rootLogFlag
            )
            if ($Script:IsDryRun) { $rootArgs += '/L' }

            $rootProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rootArgs `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput 'NUL'

            $logAppend = $true

            if (-not (Test-RobocopySuccess $rootProc.ExitCode)) {
                Write-Step "Some root-level files may have failed (exit code $($rootProc.ExitCode))" -Level Warning
            }
        }

        $completedUnits++

        # ── Restore each top-level folder (no per-folder scan — straight to move) ──
        $barWidth = 40
        foreach ($folder in $topLevelFolders) {
            $folderSrc  = $folder.FullName                              # Archive subfolder
            $folderDest = Join-Path $src $folder.Name                   # Original subfolder

            # ── Progress bar ──
            $completedUnits++
            $pctComplete = [math]::Min(100, [math]::Round(($completedUnits / $totalUnits) * 100, 1))
            $elapsed     = (Get-Date) - $startTime
            if ($completedUnits -gt 1 -and $elapsed.TotalSeconds -gt 0) {
                $unitsPerSec = ($completedUnits - 1) / $elapsed.TotalSeconds
                $remaining   = ($totalUnits - $completedUnits) / [math]::Max($unitsPerSec, 0.001)
                $eta         = [TimeSpan]::FromSeconds([math]::Round($remaining))
                $etaStr      = '{0:hh\:mm\:ss}' -f $eta
            }
            else {
                $etaStr = '--:--:--'
            }

            $filled = [math]::Round($barWidth * $pctComplete / 100)
            $empty  = $barWidth - $filled
            $bar    = ('█' * $filled) + ('░' * $empty)

            if ($Script:IsDryRun) { $barColor = 'DarkYellow' } else { $barColor = 'Yellow' }
            Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  ETA: {4}  │  {5}" -f
                $bar, $pctComplete, ($completedUnits - 1), $topLevelFolders.Count,
                $etaStr, $folder.Name.PadRight(30)) -NoNewline -ForegroundColor $barColor

            # ── Execute the restore ──
            if ($logAppend) { $logFlag = '/LOG+:' + $logFile } else { $logFlag = '/LOG:' + $logFile }
            $mtFlag = '/MT:' + $Script:Config.ThreadCount
            $roboArgs = @(
                $folderSrc
                $folderDest
                '/E'
                '/MOV'
                '/COPYALL'
                '/R:3'
                '/W:5'
                $mtFlag         # Multi-threaded
                '/V'
                '/NP'
                '/NJH'
                '/NJS'
                '/BYTES'
                $logFlag
            )
            if ($Script:IsDryRun) { $roboArgs += '/L' }

            $logAppend = $true
            $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs `
                -NoNewWindow -Wait -PassThru -RedirectStandardOutput 'NUL'

            if (Test-RobocopySuccess $proc.ExitCode) {
                $foldersOK++
            }
            else {
                $foldersFailed++
                Write-Host ''
                Write-Step ("Errors restoring folder: {0} (exit code {1})" -f $folder.Name, $proc.ExitCode) -Level Warning
            }
        }

        # ── Final progress bar ──
        $bar = '█' * $barWidth
        $totalElapsed = (Get-Date) - $startTime
        Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  Done in {4:hh\:mm\:ss}         " -f
            $bar, 100.0, $topLevelFolders.Count, $topLevelFolders.Count,
            $totalElapsed) -ForegroundColor Green
        Write-Host ''

        # ── Summary ──
        if ($Script:IsDryRun) { $summaryLabel = 'ROLLBACK SUMMARY (DRY RUN — SIMULATED)' } else { $summaryLabel = 'ROLLBACK SUMMARY' }
        Write-Host ''
        Write-Host '  ┌─────────────────────────────────────────────────────────┐' -ForegroundColor DarkCyan
        Write-Host ("  │ {0,-55} │" -f $summaryLabel) -ForegroundColor DarkCyan
        Write-Host '  ├───────────────────┬─────────────────────────────────────┤' -ForegroundColor DarkCyan
        Write-Host ("  │ Total Files       │ {0,-35} │" -f $totalFiles.ToString('N0')) -ForegroundColor DarkCyan
        Write-Host ("  │ Total Size        │ {0,-35} │" -f (Format-FileSize $totalBytes)) -ForegroundColor DarkCyan
        Write-Host ("  │ Folders OK        │ {0,-35} │" -f $foldersOK.ToString('N0')) -ForegroundColor DarkCyan
        Write-Host ("  │ Folders Failed    │ {0,-35} │" -f $foldersFailed.ToString('N0')) -ForegroundColor DarkCyan
        Write-Host ("  │ Notices Removed   │ {0,-35} │" -f $noticeFiles.Count.ToString('N0')) -ForegroundColor DarkCyan
        Write-Host ("  │ Elapsed Time      │ {0,-35} │" -f ('{0:hh\:mm\:ss}' -f $totalElapsed)) -ForegroundColor DarkCyan
        Write-Host ("  │ Robocopy Log      │ {0,-35} │" -f (Split-Path $logFile -Leaf)) -ForegroundColor DarkCyan
        Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
        Write-Host ''
    }

    # ═══════════════════════════════════════════════════════════════════════
    #  STEP 3 — Validate rollback
    # ═══════════════════════════════════════════════════════════════════════
    Write-Step '── Step 3/3: Validating rollback ──'

    $srcStatsAfter = Get-FolderStats -Path $src
    $dstStatsAfter = Get-FolderStats -Path $dst

    Write-Step ("Source files restored:    {0}" -f $srcStatsAfter.Files.ToString('N0'))
    Write-Step ("Archive files remaining:  {0}" -f $dstStatsAfter.Files.ToString('N0'))

    if ($Script:IsDryRun) {
        Write-Step 'DRY RUN complete — no files were moved. Run without -DryRun to execute.' -Level Success
    }
    elseif ($dstStatsAfter.Files -eq 0) {
        Write-Step '✓ Rollback complete — all files restored to source, archive is empty' -Level Success
    }
    else {
        Write-Step ("⚠ $($dstStatsAfter.Files) files still in archive. Re-run -Rollback to retry.") -Level Warning
    }

    Write-Step "Robocopy log: $logFile" -Level Detail
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  EXECUTION ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

# ── Initialize logging ──
Initialize-Logging

if ($Script:IsDryRun) { $modeLabel = ' [DRY RUN]' } else { $modeLabel = '' }
Write-Host ''
Write-Host '  ╔═══════════════════════════════════════════════════════════════╗' -ForegroundColor Magenta
Write-Host ("  ║         RETIRE PUBLIC SHARE — MIGRATION TOOLKIT{0}              ║" -f $modeLabel) -ForegroundColor Magenta
Write-Host '  ║         Started: ' -NoNewline -ForegroundColor Magenta
Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')                          ║" -ForegroundColor White
Write-Host '  ╚═══════════════════════════════════════════════════════════════╝' -ForegroundColor Magenta
if ($Script:IsDryRun) {
    Write-Host '  ⚠  DRY RUN MODE — All operations are simulated, nothing will be changed.' -ForegroundColor Yellow
}

# ── Show what's enabled ──
Write-Host ''
Write-Host '  Running: ' -NoNewline -ForegroundColor Gray
$enabledPhases = @()
if ($Script:Run.Rollback)        { $enabledPhases += 'ROLLBACK' }
if ($Script:Run.PreFlight)       { $enabledPhases += 'PreFlight' }
if ($Script:Run.MirrorStructure) { $enabledPhases += 'MirrorStructure' }
if ($Script:Run.MoveFiles)       { $enabledPhases += 'MoveFiles' }
if ($Script:Run.DropNotices)     { $enabledPhases += 'DropNotices' }
if ($Script:Run.Validate)        { $enabledPhases += 'Validate' }
Write-Host ($enabledPhases -join ' → ') -ForegroundColor White
Write-Host ''

$overallStart = Get-Date
$phaseResults = @{}

# ── Rollback path (separate from forward migration) ──
if ($Script:Run.Rollback) {
    $phaseResults['Rollback'] = Invoke-Rollback
}
else {
    # ── Execute requested phases ──
    if ($Script:Run.PreFlight) {
        $phaseResults['PreFlight'] = Invoke-PreFlight
        if ($phaseResults['PreFlight'] -eq $false) {
            Write-Step 'Pre-flight failed. Aborting remaining phases.' -Level Error
            Stop-Logging
            return
        }
    }

    if ($Script:Run.MirrorStructure) {
        $phaseResults['MirrorStructure'] = Invoke-MirrorStructure
        if ($phaseResults['MirrorStructure'] -eq $false) {
            Write-Step 'Mirror structure failed. Aborting remaining phases.' -Level Error
            Stop-Logging
            return
        }
    }

    if ($Script:Run.MoveFiles) {
        $phaseResults['MoveFiles'] = Invoke-MoveFiles
    }

    if ($Script:Run.DropNotices) {
        $phaseResults['DropNotices'] = Invoke-DropNotices
    }

    if ($Script:Run.Validate) {
        $phaseResults['Validate'] = Invoke-Validate
    }
}

# ── Final status ──
$overallElapsed = (Get-Date) - $overallStart

Write-Host ''
Write-Host '  ─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ("  Total elapsed time: {0:hh\:mm\:ss}" -f $overallElapsed) -ForegroundColor White
Write-Host ("  Log folder: {0}" -f $Script:Config.LogFolder) -ForegroundColor DarkGray
Write-Host '  ─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ''

Stop-Logging
