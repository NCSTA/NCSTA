#Requires -Version 5.1
<#
.SYNOPSIS
    Moves files and folders listed in a CSV into an archive root while
    preserving the original folder structure.

.DESCRIPTION
    Reads a CSV produced by the records department (converted from Excel)
    containing a "Path" column with absolute paths to files and/or folders
    that are slated for deletion. Each item is relocated under -ArchiveRoot
    (default G:\archives) mirroring the full source path so the original
    location is recoverable.

    Behavior:
      - Drive letter is stripped from the source so G:\foo\bar becomes
        <ArchiveRoot>\foo\bar.
      - For folder rows, each child file is moved individually preserving
        its relative subpath; if a destination file already exists it is
        skipped (never overwritten).
      - Source folders are never deleted, even if emptied. This way any
        files left behind (because their destination already existed)
        remain in their original structure.
      - Missing source paths are logged and skipped; a single failure
        never aborts the batch.
      - Every action (Moved / Skipped / Failed) is recorded to a results
        CSV whose path is printed at the end.
      - Supports -WhatIf and -Confirm via SupportsShouldProcess.

.PARAMETER CsvPath
    Path to the input CSV. Must contain the column named by -PathColumn
    (default "Path").

.PARAMETER ArchiveRoot
    Root folder where the mirrored structure is created. Defaults to
    G:\archives. Created automatically if it does not exist.

.PARAMETER LogPath
    Output results CSV. Defaults to a timestamped file in the current
    directory: .\Move-ToArchive-Log-yyyyMMdd-HHmmss.csv.

.PARAMETER PathColumn
    Name of the column in the input CSV that holds the source paths.
    Defaults to "Path".

.EXAMPLE
    .\Move-ToArchive.ps1 -CsvPath .\retire-list.csv -WhatIf

    Dry run against the default archive root. No files are moved; the log
    still records the intended actions.

.EXAMPLE
    .\Move-ToArchive.ps1 -CsvPath .\retire-list.csv -ArchiveRoot G:\archives

    Real run. Mirrors each listed path under G:\archives.

.EXAMPLE
    .\Move-ToArchive.ps1 -CsvPath .\retire-list.csv -LogPath C:\Temp\run1.csv

    Real run with an explicit log path.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter()]
    [string]$ArchiveRoot = 'G:\archives',

    [Parameter()]
    [string]$LogPath = ".\Move-ToArchive-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",

    [Parameter()]
    [string]$PathColumn = 'Path'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ----------------------------------------------------------------

function Get-ArchiveDestination {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ArchiveRoot
    )
    # Strip any drive qualifier (e.g. "G:") leaving a rooted path like "\foo\bar".
    $noQualifier = Split-Path -Path $SourcePath -NoQualifier
    # Trim leading slash so Join-Path doesn't treat it as absolute.
    $relative    = $noQualifier.TrimStart('\', '/')
    return (Join-Path -Path $ArchiveRoot -ChildPath $relative)
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
        }
    }
}

function Add-LogEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Action,
        [string]$Reason = '',
        [string]$Destination = ''
    )
    $script:Log.Add([PSCustomObject]@{
        Timestamp   = (Get-Date).ToString('s')
        Path        = $Path
        Destination = $Destination
        Type        = $Type
        Action      = $Action
        Reason      = $Reason
    })
}

function Move-FileIfAbsent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) {
        Add-LogEntry -Path $Source -Destination $Destination -Type 'File' `
            -Action 'Skipped' -Reason 'DestinationExists'
        return
    }
    # Ensure the destination's parent directory exists.
    $parent = Split-Path -Path $Destination -Parent
    Ensure-Directory -Path $parent

    if ($PSCmdlet.ShouldProcess($Source, "Move to $Destination")) {
        Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    }
    Add-LogEntry -Path $Source -Destination $Destination -Type 'File' -Action 'Moved'
}

function Move-FolderMerged {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationFolder
    )
    # Walk every file in the source tree and move each individually so that
    # skipped conflicts leave the original structure intact.
    $files = @(Get-ChildItem -LiteralPath $SourceFolder -Recurse -File -Force -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0) {
        # Empty source folder: still mirror the directory so the structure is recorded.
        Ensure-Directory -Path $DestinationFolder
        Add-LogEntry -Path $SourceFolder -Destination $DestinationFolder -Type 'Folder' `
            -Action 'Moved' -Reason 'EmptyFolderMirrored'
        return
    }

    foreach ($file in $files) {
        try {
            $relative = $file.FullName.Substring($SourceFolder.Length).TrimStart('\', '/')
            $destFile = Join-Path -Path $DestinationFolder -ChildPath $relative
            Move-FileIfAbsent -Source $file.FullName -Destination $destFile
        }
        catch {
            Add-LogEntry -Path $file.FullName -Type 'File' -Action 'Failed' `
                -Reason $_.Exception.Message
        }
    }
}

# --- Main -------------------------------------------------------------------

Write-Host "Loading CSV: $CsvPath" -ForegroundColor Cyan
$rows = @(Import-Csv -LiteralPath $CsvPath)
$total = $rows.Count
Write-Host "Loaded $total rows." -ForegroundColor Cyan

if ($total -eq 0) {
    Write-Host "CSV is empty; nothing to do." -ForegroundColor Yellow
    return
}

$columns = $rows[0].PSObject.Properties.Name
if ($columns -notcontains $PathColumn) {
    throw "CSV is missing required column '$PathColumn'. Found columns: $($columns -join ', ')"
}

# Make sure the archive root exists before we start.
Ensure-Directory -Path $ArchiveRoot

$script:Log = [System.Collections.Generic.List[object]]::new()
$i = 0

try {
    foreach ($row in $rows) {
        $i++
        $src = [string]$row.$PathColumn
        if ($src) { $src = $src.Trim() }

        Write-Progress -Activity 'Archiving paths' `
            -Status "$i / $total  $src" `
            -PercentComplete ([math]::Min(100, ($i / $total) * 100))

        try {
            if ([string]::IsNullOrWhiteSpace($src)) {
                Add-LogEntry -Path '' -Type 'Unknown' -Action 'Skipped' -Reason 'EmptyPath'
                continue
            }

            if (-not (Test-Path -LiteralPath $src)) {
                Add-LogEntry -Path $src -Type 'Unknown' -Action 'Skipped' -Reason 'NotFound'
                continue
            }

            $dest = Get-ArchiveDestination -SourcePath $src -ArchiveRoot $ArchiveRoot

            if (Test-Path -LiteralPath $src -PathType Leaf) {
                Move-FileIfAbsent -Source $src -Destination $dest
            }
            else {
                Move-FolderMerged -SourceFolder $src -DestinationFolder $dest
            }
        }
        catch {
            Add-LogEntry -Path $src -Type 'Unknown' -Action 'Failed' `
                -Reason $_.Exception.Message
        }
    }
}
finally {
    Write-Progress -Activity 'Archiving paths' -Completed

    # Always flush the log, even if the run was interrupted.
    if ($script:Log.Count -gt 0) {
        $logParent = Split-Path -Path $LogPath -Parent
        if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
            New-Item -ItemType Directory -Path $logParent -Force | Out-Null
        }
        $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    }
}

# --- Summary ----------------------------------------------------------------

$moved   = @($script:Log | Where-Object Action -EQ 'Moved').Count
$skipped = @($script:Log | Where-Object Action -EQ 'Skipped').Count
$failed  = @($script:Log | Where-Object Action -EQ 'Failed').Count

Write-Host ""
Write-Host "===== Archive Summary =====" -ForegroundColor Green
Write-Host "Input rows:  $total"
Write-Host "Moved:       $moved"   -ForegroundColor Green
Write-Host "Skipped:     $skipped" -ForegroundColor Yellow
Write-Host "Failed:      $failed"  -ForegroundColor Red
Write-Host "Log:         $LogPath" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "(ran in -WhatIf mode; no files were actually moved)" -ForegroundColor Yellow
}
