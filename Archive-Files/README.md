# Archive-Files

Moves files and folders listed in a CSV into an archive root while preserving
the original folder structure. Built for the shared-drive retirement workflow:
records provides a list of paths scheduled for deletion, and this script
relocates them under `G:\archives` in a way that keeps each item's original
location recoverable.

## Requirements
- Windows PowerShell 5.1 or later
- Read access to every source path in the CSV
- Write access to the archive root (default `G:\archives`)

## Input CSV format
The CSV must contain a column named `Path` (customizable via `-PathColumn`)
holding absolute paths to files or folders. Extra columns (e.g. `ID`,
`ID Owner`) are ignored. Example exported from the records Excel workbook:

```
Path,ID,ID Owner
G:\public\Nasco\MacroBuild\Batfiles,BCBSFL\Pub-K-Nasco-MacroBuild5125-M,"Dudley, Ron"
G:\public\Nasco\MacroBuild\DLM,BCBSFL\Pub-K-Nasco-MacroBuild5125-M,"Dudley, Ron"
```

## Behavior
- Drive letter is stripped when mirroring, so `G:\public\Nasco\X` lands at
  `G:\archives\public\Nasco\X`.
- Folder rows are walked file-by-file. Each file is moved into a mirrored
  subfolder under the archive root.
- **Merge, never overwrite.** If a destination file already exists it is left
  untouched and the source file stays in place — it's logged as
  `Skipped / DestinationExists`.
- **Source folders are never deleted**, even when emptied. Any files that were
  skipped remain in their original structure for later review.
- Missing source paths log `Skipped / NotFound` and the batch continues.
- A results CSV is always written, even on `-WhatIf` or if the run is
  interrupted.

## Two flavors in this folder
- **`Move-ToArchive.ps1`** — full advanced function with `param()`, comment-based help, `-WhatIf`, `-Confirm`. Run from a shell where .ps1 execution is allowed.
- **`Move-ToArchive-Inline.ps1`** — same logic, but with a config block of plain `$Variables` at the top and a `$DryRun` switch. Paste the whole file into the ISE / VS Code **script pane** and press F5. Use this when execution policy blocks running .ps1 files directly.

## Usage (Move-ToArchive.ps1)

Dry run (recommended first):
```powershell
.\Move-ToArchive.ps1 -CsvPath .\retire-list.csv -WhatIf
```

Real run against the default archive root (`G:\archives`):
```powershell
.\Move-ToArchive.ps1 -CsvPath .\retire-list.csv
```

Custom archive root and log location:
```powershell
.\Move-ToArchive.ps1 `
    -CsvPath    .\retire-list.csv `
    -ArchiveRoot G:\archives `
    -LogPath     C:\Temp\archive-run1.csv
```

Alternate column name:
```powershell
.\Move-ToArchive.ps1 -CsvPath .\retire-list.csv -PathColumn 'FullName'
```

## Usage (Move-ToArchive-Inline.ps1 — script pane)
1. Open ISE or VS Code on the target server.
2. Open `Move-ToArchive-Inline.ps1` (or paste its contents into the script pane).
3. Edit the `CONFIG` block at the top:
   ```powershell
   $CsvPath     = 'C:\Temp\retire-list.csv'
   $ArchiveRoot = 'G:\archives'
   $LogPath     = "C:\Temp\Move-ToArchive-Log-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
   $PathColumn  = 'Path'
   $DryRun      = $true   # flip to $false for a real run
   ```
4. Press **F5**. Review the log CSV at `$LogPath`.
5. Flip `$DryRun = $false` and run again.

No external parameters, no execution-policy issues — the code just runs in the current session.

## Parameters
| Parameter     | Default                                          | Description                                         |
| ------------- | ------------------------------------------------ | --------------------------------------------------- |
| `CsvPath`     | *(required)*                                     | Input CSV produced from the records Excel workbook. |
| `ArchiveRoot` | `G:\archives`                                    | Root folder under which the mirrored tree is built. |
| `LogPath`     | `.\Move-ToArchive-Log-yyyyMMdd-HHmmss.csv`       | Results CSV.                                        |
| `PathColumn`  | `Path`                                           | Name of the source-path column in the input CSV.    |

Also supports the common `-WhatIf` and `-Confirm` parameters.

## Log columns
| Column        | Description                                                          |
| ------------- | -------------------------------------------------------------------- |
| `Timestamp`   | ISO-8601 local time when the row was written.                        |
| `Path`        | Source path that was considered.                                     |
| `Destination` | Target path inside the archive root (empty for skipped/failed rows). |
| `Type`        | `File`, `Folder`, or `Unknown`.                                      |
| `Action`      | `Moved`, `Skipped`, or `Failed`.                                     |
| `Reason`      | `DestinationExists`, `NotFound`, `EmptyPath`, error text, etc.       |

## Verification checklist
1. Build a small `sample.csv` (two files + one folder on a test drive).
2. `./Move-ToArchive.ps1 -CsvPath .\sample.csv -ArchiveRoot C:\tmp\archives -WhatIf`
   — confirm `ShouldProcess` messages and review the log.
3. Re-run without `-WhatIf`; inspect `C:\tmp\archives` and the log CSV.
4. Re-run a third time — every row should log `Skipped / DestinationExists`,
   and any source folders with skipped files should still exist.
5. Add a bogus path row; confirm `Skipped / NotFound` appears and the batch
   continues.

Once verified, run against the real records-dept CSV with `-WhatIf` first,
eyeball the log, then execute for real.
