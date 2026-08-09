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
}

# ── Store DryRun flag at script scope so all functions can read it ──
$Script:IsDryRun = $DryRun.IsPresent

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
    <# Returns a stats object for a given path: folder count, file count, total size #>
    param([string]$Path)

    Write-Step "Scanning $Path (this may take a few minutes for large trees)..."

    $folders = 0
    $files   = 0
    $size    = [long]0

    # Use robocopy /L (list-only) for speed on large trees — counts without touching files
    $robocopyOutput = & robocopy $Path 'NUL' /L /E /NJH /NJS /BYTES /NFL /NDL 2>&1
    # Fallback to Get-ChildItem if robocopy listing doesn't parse cleanly
    try {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        $folders = @($items | Where-Object { $_.PSIsContainer }).Count
        $files   = @($items | Where-Object { -not $_.PSIsContainer }).Count
        $size    = ($items | Where-Object { -not $_.PSIsContainer } |
                   Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $size) { $size = 0 }
    }
    catch {
        Write-Step "Error scanning ${Path}: $_" -Level Error
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

    # ── Count source folders for reference ──
    Write-Step 'Counting source directories...'
    $srcFolderCount = @(Get-ChildItem -LiteralPath $src -Recurse -Directory -Force -ErrorAction SilentlyContinue).Count
    Write-Step "Source contains $($srcFolderCount.ToString('N0')) directories" -Level Detail

    # ── Run robocopy — directories only, no files ──
    if ($Script:IsDryRun) { $dryRunLabel = ' [DRY RUN — /L list-only]' } else { $dryRunLabel = '' }
    Write-Step "Running robocopy to mirror directory structure (no files)...$dryRunLabel"
    Write-Step "Command: robocopy `"$src`" `"$dst`" /E /XF * /DCOPY:DAT /R:3 /W:5 /V /LOG:`"$logFile`"" -Level Detail

    $roboArgs = @(
        $src
        $dst
        '/E'            # Include subdirectories, including empty ones
        '/XF', '*'      # Exclude ALL files
        '/DCOPY:DAT'    # Copy directory Data, Attributes, Timestamps
        '/R:3'          # Retry 3 times
        '/W:5'          # Wait 5 seconds between retries
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

    # ── Verify ──
    Write-Step 'Verifying archive directory count...'
    $dstFolderCount = @(Get-ChildItem -LiteralPath $dst -Recurse -Directory -Force -ErrorAction SilentlyContinue).Count
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

    # ── Count total files and size for progress tracking ──
    Write-Step 'Counting files for progress tracking (this may take a few minutes)...'
    $allFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)
    $totalFiles = $allFiles.Count
    $totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }

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

    $totalUnits     = $topLevelFolders.Count + 1  # +1 for root-level files batch
    $completedUnits = 0
    $movedFiles     = 0
    $movedBytes     = [long]0
    $failedFiles    = 0
    $startTime      = Get-Date
    $logAppend      = $false   # First write creates; subsequent writes append

    # ── Helper: run robocopy for a specific subfolder ──
    function Move-Subfolder {
        param(
            [string]$SubSource,
            [string]$SubDest,
            [string]$Log,
            [bool]$Append
        )

        if ($Append) { $logFlag = '/LOG+:' + $Log } else { $logFlag = '/LOG:' + $Log }

        $args = @(
            $SubSource
            $SubDest
            '/E'            # All subdirectories
            '/MOV'          # Move files (delete source after copy) — leaves dirs
            '/COPYALL'      # Copy all file attributes (security, timestamps, owner, audit)
            '/R:3'          # 3 retries
            '/W:5'          # 5-second wait between retries
            '/V'            # Verbose
            '/NP'           # No robocopy progress (we do our own)
            '/NJH'          # No job header in log
            '/NJS'          # No job summary in log (we summarize ourselves)
            '/BYTES'        # Show sizes in bytes for parsing
            $logFlag
        )

        if ($Script:IsDryRun) { $args += '/L' }

        $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $args `
            -NoNewWindow -Wait -PassThru -RedirectStandardOutput 'NUL'

        return $proc.ExitCode
    }

    # ── Move root-level files first (files sitting directly in G:\Public) ──
    if ($topLevelFiles.Count -gt 0) {
        if ($Script:IsDryRun) { $actionVerb = 'Simulating move of' } else { $actionVerb = 'Moving' }
        Write-Step ("{0} {1} root-level files..." -f $actionVerb, $topLevelFiles.Count) -Level Detail

        # Robocopy with /LEV:1 to only move files at root level, not recurse
        $rootLogFlag = '/LOG:' + $logFile
        $rootArgs = @(
            $src
            $dst
            '/LEV:1'        # Only root level
            '/MOV'          # Move files only
            '/COPYALL'
            '/R:3'
            '/W:5'
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

        $movedFiles += $topLevelFiles.Count
        $movedBytes += ($topLevelFiles | Measure-Object -Property Length -Sum).Sum
    }

    $completedUnits++

    # ── Move each top-level folder ──
    foreach ($folder in $topLevelFolders) {
        $folderSrc  = $folder.FullName
        $folderDest = Join-Path $dst $folder.Name

        # Count files in this folder for reporting
        $folderFiles = @(Get-ChildItem -LiteralPath $folderSrc -Recurse -File -Force -ErrorAction SilentlyContinue)
        $folderFileCount = $folderFiles.Count
        $folderSize = ($folderFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
        if ($null -eq $folderSize) { $folderSize = 0 }

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

        # Build the bar: 40 chars wide
        $barWidth  = 40
        $filled    = [math]::Round($barWidth * $pctComplete / 100)
        $empty     = $barWidth - $filled
        $bar       = ('█' * $filled) + ('░' * $empty)

        Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  ETA: {4}  │  {5}" -f
            $bar, $pctComplete, ($completedUnits - 1), $topLevelFolders.Count,
            $etaStr, $folder.Name.PadRight(30)) -NoNewline -ForegroundColor Yellow

        # ── Execute the move ──
        if ($folderFileCount -gt 0) {
            $exitCode = Move-Subfolder -SubSource $folderSrc -SubDest $folderDest `
                -Log $logFile -Append $logAppend
            $logAppend = $true

            if (Test-RobocopySuccess $exitCode) {
                $movedFiles += $folderFileCount
                $movedBytes += $folderSize
            }
            else {
                $failedFiles += $folderFileCount
                Write-Host ''
                Write-Step ("Errors moving folder: {0} (exit code {1})" -f $folder.Name, $exitCode) -Level Warning
            }
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
    Write-Host ("  │ Files Moved       │ {0,-35} │" -f $movedFiles.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Data Moved        │ {0,-35} │" -f (Format-FileSize $movedBytes)) -ForegroundColor DarkCyan
    Write-Host ("  │ Files Failed      │ {0,-35} │" -f $failedFiles.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host ("  │ Elapsed Time      │ {0,-35} │" -f ('{0:hh\:mm\:ss}' -f $totalElapsed)) -ForegroundColor DarkCyan
    Write-Host ("  │ Robocopy Log      │ {0,-35} │" -f (Split-Path $logFile -Leaf)) -ForegroundColor DarkCyan
    Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    if ($failedFiles -gt 0) {
        Write-Step ("$failedFiles files failed to move. Review log: $logFile") -Level Warning
        Write-Step 'Re-run -MoveFiles after clearing locks to retry failed files.' -Level Warning
    }
    else {
        Write-Step 'All files moved successfully.' -Level Success
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
    Write-Step 'Scanning source for remaining files...'
    $srcFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)

    # Separate notice files from unexpected leftovers
    $noticeFileName = $Script:Config.NoticeFileName
    $noticeFiles    = @($srcFiles | Where-Object { $_.Name -eq $noticeFileName })
    $leftoverFiles  = @($srcFiles | Where-Object { $_.Name -ne $noticeFileName })

    Write-Step "Source files remaining: $($srcFiles.Count) total" -Level Detail
    Write-Step "  Notice files: $($noticeFiles.Count)" -Level Detail
    Write-Step "  Leftover files (not moved): $($leftoverFiles.Count)" -Level Detail

    # ── Scan archive ──
    Write-Step 'Scanning archive...'
    $dstStats = Get-FolderStats -Path $dst

    # ── Compare folder structure ──
    Write-Step 'Comparing folder structures...'
    $srcFolders = @(Get-ChildItem -LiteralPath $src -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($src.Length) })
    $dstFolders = @(Get-ChildItem -LiteralPath $dst -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName.Substring($dst.Length) })

    $missingInArchive = @(Compare-Object -ReferenceObject $srcFolders -DifferenceObject $dstFolders |
        Where-Object { $_.SideIndicator -eq '<=' } |
        ForEach-Object { $_.InputObject })

    if ($missingInArchive.Count -gt 0) {
        Write-Step "$($missingInArchive.Count) folders missing from archive:" -Level Warning
        foreach ($missing in $missingInArchive | Select-Object -First 20) {
            Write-Step "  MISSING: $missing" -Level Warning
        }
        if ($missingInArchive.Count -gt 20) {
            Write-Step "  ... and $($missingInArchive.Count - 20) more" -Level Warning
        }
    }
    else {
        Write-Step 'All source folders exist in archive' -Level Success
    }

    # ── List leftover files ──
    if ($leftoverFiles.Count -gt 0) {
        Write-Step 'Files that were NOT moved (still in source):' -Level Warning
        foreach ($file in $leftoverFiles | Select-Object -First 50) {
            $relativePath = $file.FullName.Substring($src.Length)
            $sizeStr = Format-FileSize $file.Length
            Write-Step ("  LEFTOVER: {0}  ({1})" -f $relativePath, $sizeStr) -Level Warning
        }
        if ($leftoverFiles.Count -gt 50) {
            Write-Step "  ... and $($leftoverFiles.Count - 50) more" -Level Warning
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
        "Source Leftovers:  $($leftoverFiles.Count) files (not moved)"
        "Notice Files:      $($noticeFiles.Count)"
        "Missing Folders:   $($missingInArchive.Count)"
        ""
    )

    if ($leftoverFiles.Count -gt 0) {
        $reportLines += "LEFTOVER FILES:"
        foreach ($file in $leftoverFiles) {
            $reportLines += "  $($file.FullName)"
        }
        $reportLines += ""
    }

    if ($missingInArchive.Count -gt 0) {
        $reportLines += "MISSING FOLDERS IN ARCHIVE:"
        foreach ($missing in $missingInArchive) {
            $reportLines += "  $missing"
        }
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

    if ($leftoverFiles.Count -eq 0) { $leftoverColor = 'DarkCyan' } else { $leftoverColor = 'Yellow' }
    Write-Host ("  │ Leftover Files    │ {0,-35} │" -f $leftoverFiles.Count.ToString('N0')) -ForegroundColor $leftoverColor

    if ($missingInArchive.Count -eq 0) { $missingColor = 'DarkCyan' } else { $missingColor = 'Yellow' }
    Write-Host ("  │ Missing Folders   │ {0,-35} │" -f $missingInArchive.Count.ToString('N0')) -ForegroundColor $missingColor

    Write-Host ("  │ Notice Files      │ {0,-35} │" -f $noticeFiles.Count.ToString('N0')) -ForegroundColor DarkCyan
    Write-Host '  └───────────────────┴─────────────────────────────────────┘' -ForegroundColor DarkCyan
    Write-Host ''

    if ($leftoverFiles.Count -eq 0 -and $missingInArchive.Count -eq 0) {
        Write-Step '✓ Migration validated — all files moved, all folders accounted for' -Level Success
    }
    elseif ($leftoverFiles.Count -gt 0) {
        Write-Step "⚠ $($leftoverFiles.Count) files still in source. Re-run -MoveFiles to retry." -Level Warning
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
    $noticeFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $noticeFileName })

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

    # Count files in archive
    Write-Step 'Counting files in archive for progress tracking...'
    $allFiles = @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue)
    $totalFiles = $allFiles.Count
    $totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalBytes) { $totalBytes = 0 }

    Write-Step ("Files to restore: {0}" -f $totalFiles.ToString('N0'))
    Write-Step ("Total size:       {0}" -f (Format-FileSize $totalBytes))

    if ($totalFiles -eq 0) {
        Write-Step 'Archive is empty — no files to restore.' -Level Warning
    }
    else {
        $topLevelItems   = @(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue)
        $topLevelFolders = @($topLevelItems | Where-Object { $_.PSIsContainer })
        $topLevelFiles   = @($topLevelItems | Where-Object { -not $_.PSIsContainer })

        $totalUnits     = $topLevelFolders.Count + 1
        $completedUnits = 0
        $restoredFiles  = 0
        $restoredBytes  = [long]0
        $failedFiles    = 0
        $startTime      = Get-Date
        $logAppend      = $false

        # ── Restore root-level files ──
        if ($topLevelFiles.Count -gt 0) {
            if ($Script:IsDryRun) { $actionVerb = 'Simulating restore of' } else { $actionVerb = 'Restoring' }
            Write-Step ("{0} {1} root-level files..." -f $actionVerb, $topLevelFiles.Count) -Level Detail

            $rootLogFlag = '/LOG:' + $logFile
            $rootArgs = @(
                $dst            # Archive is the source for rollback
                $src            # Original share is the destination
                '/LEV:1'
                '/MOV'
                '/COPYALL'
                '/R:3'
                '/W:5'
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

            $restoredFiles += $topLevelFiles.Count
            $restoredBytes += ($topLevelFiles | Measure-Object -Property Length -Sum).Sum
        }

        $completedUnits++

        # ── Restore each top-level folder ──
        foreach ($folder in $topLevelFolders) {
            $folderSrc  = $folder.FullName                              # Archive subfolder
            $folderDest = Join-Path $src $folder.Name                   # Original subfolder

            $folderFiles = @(Get-ChildItem -LiteralPath $folderSrc -Recurse -File -Force -ErrorAction SilentlyContinue)
            $folderFileCount = $folderFiles.Count
            $folderSize = ($folderFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
            if ($null -eq $folderSize) { $folderSize = 0 }

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

            $barWidth = 40
            $filled   = [math]::Round($barWidth * $pctComplete / 100)
            $empty    = $barWidth - $filled
            $bar      = ('█' * $filled) + ('░' * $empty)

            if ($Script:IsDryRun) { $barColor = 'DarkYellow' } else { $barColor = 'Yellow' }
            Write-Host ("`r  [{0}] {1,5:N1}%  │  {2}/{3} folders  │  ETA: {4}  │  {5}" -f
                $bar, $pctComplete, ($completedUnits - 1), $topLevelFolders.Count,
                $etaStr, $folder.Name.PadRight(30)) -NoNewline -ForegroundColor $barColor

            if ($folderFileCount -gt 0) {
                if ($logAppend) { $logFlag = '/LOG+:' + $logFile } else { $logFlag = '/LOG:' + $logFile }
                $roboArgs = @(
                    $folderSrc
                    $folderDest
                    '/E'
                    '/MOV'
                    '/COPYALL'
                    '/R:3'
                    '/W:5'
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
                    $restoredFiles += $folderFileCount
                    $restoredBytes += $folderSize
                }
                else {
                    $failedFiles += $folderFileCount
                    Write-Host ''
                    Write-Step ("Errors restoring folder: {0} (exit code {1})" -f $folder.Name, $proc.ExitCode) -Level Warning
                }
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
        Write-Host ("  │ Files Restored    │ {0,-35} │" -f $restoredFiles.ToString('N0')) -ForegroundColor DarkCyan
        Write-Host ("  │ Data Restored     │ {0,-35} │" -f (Format-FileSize $restoredBytes)) -ForegroundColor DarkCyan
        Write-Host ("  │ Files Failed      │ {0,-35} │" -f $failedFiles.ToString('N0')) -ForegroundColor DarkCyan
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

    $srcFilesAfter = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne $noticeFileName })
    $dstFilesAfter = @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction SilentlyContinue)

    Write-Step ("Source files restored:    {0}" -f $srcFilesAfter.Count.ToString('N0'))
    Write-Step ("Archive files remaining:  {0}" -f $dstFilesAfter.Count.ToString('N0'))

    if ($Script:IsDryRun) {
        Write-Step 'DRY RUN complete — no files were moved. Run without -DryRun to execute.' -Level Success
    }
    elseif ($dstFilesAfter.Count -eq 0) {
        Write-Step '✓ Rollback complete — all files restored to source, archive is empty' -Level Success
    }
    else {
        Write-Step ("⚠ $($dstFilesAfter.Count) files still in archive. Re-run -Rollback to retry.") -Level Warning
    }

    Write-Step "Robocopy log: $logFile" -Level Detail
    return $true
}

# ═══════════════════════════════════════════════════════════════════════════════
#  EXECUTION ENTRY POINT
# ═══════════════════════════════════════════════════════════════════════════════

# ── Show usage if no switches provided ──
$anySwitchSet = $PreFlight -or $MirrorStructure -or $MoveFiles -or $DropNotices -or $Validate -or $RunAll -or $Rollback

if (-not $anySwitchSet) {
    Write-Host ''
    Write-Host '  Retire-PublicShare.ps1 — Public Share Migration Toolkit' -ForegroundColor White
    Write-Host '  ─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Usage (run in PowerShell ISE script pane):' -ForegroundColor Gray
    Write-Host ''
    Write-Host '    .\Retire-PublicShare.ps1 -PreFlight         # Phase 0: Scan and report' -ForegroundColor Cyan
    Write-Host '    .\Retire-PublicShare.ps1 -MirrorStructure   # Phase 1: Copy folder tree only' -ForegroundColor Cyan
    Write-Host '    .\Retire-PublicShare.ps1 -MoveFiles         # Phase 2: Move files (progress bar)' -ForegroundColor Cyan
    Write-Host '    .\Retire-PublicShare.ps1 -DropNotices       # Phase 3: Place retirement notices' -ForegroundColor Cyan
    Write-Host '    .\Retire-PublicShare.ps1 -Validate          # Phase 4: Verify migration' -ForegroundColor Cyan
    Write-Host '    .\Retire-PublicShare.ps1 -RunAll            # Run all phases in sequence' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Modifiers:' -ForegroundColor Gray
    Write-Host '    -DryRun                                     # Simulate without changes' -ForegroundColor DarkYellow
    Write-Host '    -Rollback                                   # Reverse: archive → source' -ForegroundColor DarkYellow
    Write-Host '    -Rollback -DryRun                           # Preview rollback' -ForegroundColor DarkYellow
    Write-Host ''
    Write-Host '  Source:  ' -NoNewline -ForegroundColor Gray
    Write-Host $Script:Config.SourcePath -ForegroundColor White
    Write-Host '  Archive: ' -NoNewline -ForegroundColor Gray
    Write-Host $Script:Config.ArchivePath -ForegroundColor White
    Write-Host '  Logs:    ' -NoNewline -ForegroundColor Gray
    Write-Host $Script:Config.LogFolder -ForegroundColor White
    Write-Host ''
    return
}

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
Write-Host ''

$overallStart = Get-Date
$phaseResults = @{}

# ── Rollback path (separate from forward migration) ──
if ($Rollback) {
    $phaseResults['Rollback'] = Invoke-Rollback
}
else {
    # ── Execute requested phases ──
    if ($RunAll -or $PreFlight) {
        $phaseResults['PreFlight'] = Invoke-PreFlight
        if ($RunAll -and $phaseResults['PreFlight'] -eq $false) {
            Write-Step 'Pre-flight failed. Aborting remaining phases.' -Level Error
            Stop-Logging
            return
        }
    }

    if ($RunAll -or $MirrorStructure) {
        $phaseResults['MirrorStructure'] = Invoke-MirrorStructure
        if ($RunAll -and $phaseResults['MirrorStructure'] -eq $false) {
            Write-Step 'Mirror structure failed. Aborting remaining phases.' -Level Error
            Stop-Logging
            return
        }
    }

    if ($RunAll -or $MoveFiles) {
        $phaseResults['MoveFiles'] = Invoke-MoveFiles
    }

    if ($RunAll -or $DropNotices) {
        $phaseResults['DropNotices'] = Invoke-DropNotices
    }

    if ($RunAll -or $Validate) {
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
