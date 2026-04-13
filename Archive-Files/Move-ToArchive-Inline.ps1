# ============================================================================
#  Move-ToArchive (inline / Script-Pane version)
# ----------------------------------------------------------------------------
#  Paste this entire file into the PowerShell ISE / VS Code script pane and
#  press F5. Use this when .ps1 execution is blocked by policy on the server.
#
#  Edit the four variables in the CONFIG block, then run.
# ============================================================================

# --- CONFIG: edit these ----------------------------------------------------

# Full path to the CSV exported from the records Excel workbook.
# The CSV must contain a column named by $PathColumn (default "Path").
$CsvPath     = 'C:\Temp\retire-list.csv'

# Root folder where the mirrored structure will be created.
$ArchiveRoot = 'G:\archives'

# Where to write the run results CSV (Moved / Skipped / Failed per row).
$LogPath     = "C:\Temp\Move-ToArchive-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"

# Name of the source-path column in the input CSV.
$PathColumn  = 'Path'

# $true  = preview only, nothing is moved (log still records intended actions)
# $false = actually move files
$DryRun      = $true

# ---------------------------------------------------------------------------

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

function Get-ArchiveDestination {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ArchiveRoot
    )
    $noQualifier = Split-Path -Path $SourcePath -NoQualifier
    $relative    = $noQualifier.TrimStart('\', '/')
    return (Join-Path -Path $ArchiveRoot -ChildPath $relative)
}

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
    $parent = Split-Path -Path $Destination -Parent
    Ensure-Directory -Path $parent

    if ($DryRun) {
        Write-Host "  [DryRun] would move: $Source -> $Destination" -ForegroundColor DarkGray
    }
    else {
        Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    }
    Add-LogEntry -Path $Source -Destination $Destination -Type 'File' -Action 'Moved'
}

function Move-FolderMerged {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestinationFolder
    )
    $files = @(Get-ChildItem -LiteralPath $SourceFolder -Recurse -File -Force -ErrorAction SilentlyContinue)

    if ($files.Count -eq 0) {
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

# --- Main ------------------------------------------------------------------

if ($DryRun) {
    Write-Host "*** DRY RUN - no files will be moved ***" -ForegroundColor Yellow
}

Write-Host "Loading CSV: $CsvPath" -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $CsvPath -PathType Leaf)) {
    throw "CSV not found: $CsvPath"
}
$rows  = @(Import-Csv -LiteralPath $CsvPath)
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

    if ($script:Log.Count -gt 0) {
        $logParent = Split-Path -Path $LogPath -Parent
        if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
            New-Item -ItemType Directory -Path $logParent -Force | Out-Null
        }
        $script:Log | Export-Csv -LiteralPath $LogPath -NoTypeInformation -Encoding UTF8
    }
}

# --- Summary ---------------------------------------------------------------

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
if ($DryRun) {
    Write-Host "(DryRun was `$true; no files were actually moved)" -ForegroundColor Yellow
}
