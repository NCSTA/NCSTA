#Requires -Version 5.1
#Requires -Modules ImportExcel

<#
.SYNOPSIS
    Combines Nessus scan exports into one master workbook per zone and server role.

.DESCRIPTION
    Scans -InputFolder for Nessus exports (.csv or .xlsx) and reads the zone, OS
    year and server role from each file name, e.g.

        ZONE2 Server 2019 MS Green (SCAN-2019-01) -ZONE2 Server 2019 MS SCAN-.696747
        ZONE1 - Windows Server 2022 DC (SCAN-N-2022-03) -ZONE1 - Windows Server 2022 DC SCAN-.696702

    Files are grouped by zone + role and each group is written to its own workbook:

        ZONE1_DC_Master.xlsx   ZONE1_MS_Master.xlsx
        GWS_DC_Master.xlsx     GWS_MS_Master.xlsx

    Every master workbook contains:

      * an 'All' sheet - every row from every file in the group, with a leading 'Platform' column
      * one sheet per source file, named after its OS year

    Rows are written in bulk through EPPlus (the engine inside ImportExcel) instead
    of Export-Excel, which is too slow and memory-hungry for 100k-row files.

    Existing master workbooks in -OutputFolder are overwritten on every run.

    Written for Windows PowerShell 5.1. Set the two paths in the SETTINGS section
    below and press F5 in the ISE script pane - no arguments are needed.

.PARAMETER InputFolder
    UNC folder holding the Nessus export files. Default: set in the SETTINGS section.

.PARAMETER OutputFolder
    Folder for the master workbooks. Default: C:\temp.

.PARAMETER WorksheetName
    Worksheet to read from .xlsx sources. Default: the first worksheet.

.EXAMPLE
    .\Merge-NessusScans.ps1

.EXAMPLE
    .\Merge-NessusScans.ps1 -InputFolder '\\fileserver\scans\other' -OutputFolder 'D:\out'
#>

[CmdletBinding()]
param(
    # ==========================================================================
    #  SETTINGS - edit these two paths, then press F5 in the ISE script pane
    # ==========================================================================
    [string]$InputFolder  = '\\SERVER\Share\NessusDumps',   # UNC folder the Nessus exports are dropped in
    [string]$OutputFolder = 'C:\temp',                      # where the master workbooks are written
    # ==========================================================================

    [string]$WorksheetName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($InputFolder -eq '\\SERVER\Share\NessusDumps') {
    throw 'Set $InputFolder in the SETTINGS section at the top of this script to the UNC folder holding the Nessus exports.'
}
if (-not (Test-Path -LiteralPath $InputFolder)) {
    throw "Input folder not found or not reachable: $InputFolder"
}

$excelMaxRows      = 1048576
$excelMaxCellChars = 32767
$allSheetName      = 'All'
$masterSuffix      = '_Master.xlsx'
$dateFormat        = 'yyyy-mm-dd hh:mm:ss'

# Zone is the leading token, then '... Server <year> <role>'
$namePattern   = [regex]'^(?<Zone>ZONE1|ZONE2)\b.*?Server\s+(?<Year>\d{4})\s+(?<Role>MS|DC)\b'
$scanIdPattern = [regex]'\.(\d+)$'
$numberPattern = [regex]'^-?(0|[1-9]\d*)(\.\d+)?$'

# --- Readers: both return @{ Header = object[]; Rows = List[object[]]; Truncated = int } or $null ---

function Read-CsvScan {
    param([string]$Path)

    $records = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    if ($records.Count -eq 0) { return $null }

    $header   = [object[]]@($records[0].PSObject.Properties.Name)
    $colCount = $header.Length
    $rows     = New-Object 'System.Collections.Generic.List[object[]]' $records.Count
    $truncated = 0

    foreach ($record in $records) {
        $row = [object[]]::new($colCount)
        $c = 0
        foreach ($property in $record.PSObject.Properties) {
            $text = $property.Value
            if ($null -ne $text -and $text.Length -gt 0) {
                if ($text.Length -le 15 -and $numberPattern.IsMatch($text)) {
                    # Store IDs, ports and scores as numbers so they sort and filter properly
                    $row[$c] = [double]$text
                }
                elseif ($text.Length -gt $excelMaxCellChars) {
                    # Longer values produce a workbook Excel reports as corrupt
                    $row[$c] = $text.Substring(0, $excelMaxCellChars)
                    $truncated++
                }
                else {
                    $row[$c] = $text
                }
            }
            $c++
        }
        $rows.Add($row)
    }

    return @{ Header = $header; Rows = $rows; Truncated = $truncated }
}

function Read-XlsxScan {
    param(
        [string]$Path,
        [string]$WorksheetName,
        [System.Collections.Generic.HashSet[int]]$DateColumns
    )

    $package = Open-ExcelPackage -Path $Path
    try {
        if ($WorksheetName) {
            $sheet = $package.Workbook.Worksheets[$WorksheetName]
            if (-not $sheet) { throw "Worksheet '$WorksheetName' not found in $Path" }
        }
        else {
            $sheet = $package.Workbook.Worksheets | Select-Object -First 1
        }

        if (-not $sheet.Dimension -or $sheet.Dimension.End.Row -lt 2) { return $null }
        $rowCount = $sheet.Dimension.End.Row
        $colCount = $sheet.Dimension.End.Column

        # One call pulls the whole sheet as a zero-based object[,]
        $data = $sheet.Cells[1, 1, $rowCount, $colCount].Value
    }
    finally {
        Close-ExcelPackage -ExcelPackage $package -NoSave
    }

    $header = [object[]]::new($colCount)
    for ($c = 0; $c -lt $colCount; $c++) { $header[$c] = $data[0, $c] }

    $rows = New-Object 'System.Collections.Generic.List[object[]]' $rowCount
    for ($r = 1; $r -lt $rowCount; $r++) {
        $row = [object[]]::new($colCount)
        $hasValue = $false
        for ($c = 0; $c -lt $colCount; $c++) {
            $value = $data[$r, $c]
            if ($null -ne $value) {
                $hasValue = $true
                if ($value -is [datetime]) { [void]$DateColumns.Add($c + 1) }
                $row[$c] = $value
            }
        }
        # Dimension can include trailing blank rows
        if ($hasValue) { $rows.Add($row) }
    }

    return @{ Header = $header; Rows = $rows; Truncated = 0 }
}

# --- Discover source files and group them by zone + role ----------------------

# EPPlus resolves relative paths against the .NET working directory, not the PS location
$InputFolder = (Resolve-Path -LiteralPath $InputFolder).ProviderPath
$OutputFolder = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFolder)
if (-not (Test-Path -LiteralPath $OutputFolder)) {
    [void](New-Item -ItemType Directory -Path $OutputFolder)
}

$files = @(Get-ChildItem -LiteralPath $InputFolder -File |
    Where-Object {
        $_.Extension -in '.csv', '.xlsx' -and
        $_.Name -notlike "*$masterSuffix" -and
        $_.Name -notlike '~$*'
    })
if ($files.Count -eq 0) { throw "No .csv or .xlsx files found in $InputFolder" }

$sources = foreach ($file in $files) {
    $match = $namePattern.Match($file.BaseName)
    if (-not $match.Success) {
        Write-Warning "Skipped (file name does not identify zone, year and role): $($file.Name)"
        continue
    }
    $scanId = $scanIdPattern.Match($file.BaseName)
    [pscustomobject]@{
        Zone   = $match.Groups['Zone'].Value.ToUpper()
        Role   = $match.Groups['Role'].Value.ToUpper()
        Year   = $match.Groups['Year'].Value
        ScanId = if ($scanId.Success) { $scanId.Groups[1].Value } else { '' }
        File   = $file
    }
}
$sources = @($sources)
if ($sources.Count -eq 0) { throw "No files in $InputFolder matched the expected Nessus naming." }

$groups = @($sources | Group-Object Zone, Role | Sort-Object Name)

# --- Merge each group into its own master workbook ----------------------------

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$summary   = New-Object 'System.Collections.Generic.List[object]'

foreach ($group in $groups) {
    $zone       = $group.Group[0].Zone
    $role       = $group.Group[0].Role
    $masterName = '{0}_{1}{2}' -f $zone, $role, $masterSuffix
    $masterPath = Join-Path $OutputFolder $masterName
    $members    = @($group.Group | Sort-Object Year, ScanId)

    Write-Host ''
    Write-Host "=== $masterName ($($members.Count) file(s)) ==="

    $repeatedYears = @($members | Group-Object Year | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    foreach ($year in $repeatedYears) {
        Write-Warning "$zone $role has more than one $year file - all of them are included, check for an outdated scan."
    }

    if (Test-Path -LiteralPath $masterPath) { Remove-Item -LiteralPath $masterPath -Force }

    $outPkg         = Open-ExcelPackage -Path $masterPath -Create
    $allSheet       = $outPkg.Workbook.Worksheets.Add($allSheetName)
    $platformSheets = New-Object 'System.Collections.Generic.List[object]'
    $dateColumns    = New-Object 'System.Collections.Generic.HashSet[int]'   # 1-based source column numbers
    $masterKey      = $null
    $masterFile     = $null
    $nextAllRow     = 2

    try {
        foreach ($member in $members) {
            $file = $member.File
            Write-Host ("[{0}] Reading {1} ..." -f $member.Year, $file.Name)

            if ($file.Extension -eq '.csv') {
                $scan = Read-CsvScan -Path $file.FullName
            }
            else {
                $scan = Read-XlsxScan -Path $file.FullName -WorksheetName $WorksheetName -DateColumns $dateColumns
            }
            if ($null -eq $scan) {
                Write-Warning "$($file.Name) has no data rows - skipped."
                continue
            }

            $header   = $scan.Header
            $rows     = $scan.Rows
            $colCount = $header.Length

            # Header check against the first file of the group
            $headerKey = ($header | ForEach-Object { "$_".Trim() }) -join [char]31
            if ($null -eq $masterKey) {
                $masterKey  = $headerKey
                $masterFile = $file.Name

                $allHeader = [object[]]::new($colCount + 1)
                $allHeader[0] = 'Platform'
                [array]::Copy($header, 0, $allHeader, 1, $colCount)
                $headerRows = New-Object 'System.Collections.Generic.List[object[]]'
                $headerRows.Add($allHeader)
                [void]$allSheet.Cells[1, 1].LoadFromArrays($headerRows)
            }
            elseif ($headerKey -ne $masterKey) {
                throw "Column headers in $($file.Name) do not match $masterFile."
            }

            if (($nextAllRow + $rows.Count - 1) -gt $excelMaxRows) {
                throw "Adding $($file.Name) would push the '$allSheetName' sheet of $masterName past Excel's $excelMaxRows row limit."
            }

            Write-Host ("[{0}] Writing {1:N0} rows ..." -f $member.Year, $rows.Count)

            # 'All' sheet: same rows with the platform in front
            $allRows = New-Object 'System.Collections.Generic.List[object[]]' $rows.Count
            foreach ($row in $rows) {
                $allRow = [object[]]::new($colCount + 1)
                $allRow[0] = $member.Year
                [array]::Copy($row, 0, $allRow, 1, $colCount)
                $allRows.Add($allRow)
            }
            if ($allRows.Count -gt 0) {
                [void]$allSheet.Cells[$nextAllRow, 1].LoadFromArrays($allRows)
                $nextAllRow += $allRows.Count
            }
            $rowsWritten = $rows.Count
            $allRows = $null

            # Per-platform sheet: header + rows unchanged
            $sheetName = $member.Year
            if ($repeatedYears -contains $member.Year) {
                $sheetName = if ($member.ScanId) { "$($member.Year) ($($member.ScanId))" } else { "$($member.Year) ($($platformSheets.Count + 1))" }
            }
            $rows.Insert(0, $header)
            $platformSheet = $outPkg.Workbook.Worksheets.Add($sheetName)
            [void]$platformSheet.Cells[1, 1].LoadFromArrays($rows)
            $platformSheets.Add($platformSheet)

            if ($scan.Truncated -gt 0) {
                Write-Warning "$($file.Name): $($scan.Truncated) cell(s) exceeded Excel's $excelMaxCellChars character limit and were truncated."
            }

            $summary.Add([pscustomobject]@{
                Master   = $masterName
                Platform = $member.Year
                Rows     = $rowsWritten
                File     = $file.Name
            })

            $scan = $null
            $rows = $null
            [GC]::Collect()
        }

        if ($null -eq $masterKey) {
            Write-Warning "$masterName not created - none of its source files contained data."
            continue
        }

        # Raw DateTime values need a number format or Excel shows them as serial numbers
        foreach ($col in $dateColumns) {
            $allSheet.Column($col + 1).Style.Numberformat.Format = $dateFormat
            foreach ($sheet in $platformSheets) {
                $sheet.Column($col).Style.Numberformat.Format = $dateFormat
            }
        }

        Write-Host ("Saving {0} ({1:N0} rows) ..." -f $masterPath, ($nextAllRow - 2))
        Close-ExcelPackage -ExcelPackage $outPkg
        $outPkg = $null
    }
    finally {
        # Only still set if nothing was saved
        if ($outPkg) { Close-ExcelPackage -ExcelPackage $outPkg -NoSave }
    }
}

$stopwatch.Stop()
$summary | Format-Table -AutoSize | Out-Host
$summary | Group-Object Master | ForEach-Object {
    [pscustomobject]@{
        Master = $_.Name
        Files  = $_.Count
        Rows   = ($_.Group | Measure-Object Rows -Sum).Sum
    }
} | Format-Table -AutoSize | Out-Host
Write-Host ("Done in {0:mm\:ss}. Output folder: {1}" -f $stopwatch.Elapsed, $OutputFolder)
