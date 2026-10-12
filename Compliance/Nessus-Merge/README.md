# Nessus Merge

Combines individual Nessus scan exports into one master Excel workbook per zone and server role.

## Requirements

- Windows PowerShell 5.1
- `ImportExcel` module (`Install-Module ImportExcel -Scope CurrentUser`)
- Read access to the folder holding the Nessus exports

## Setup

Edit the SETTINGS block at the top of the script:

```powershell
[string]$InputFolder  = '\\SERVER\Share\NessusDumps',
[string]$OutputFolder = 'C:\temp',
[string[]]$Zones      = @('ZONE1', 'ZONE2'),
```

| Setting | Purpose |
|---|---|
| `InputFolder` | Folder the `.csv` or `.xlsx` Nessus exports are dropped in. The script stops if this is left at the placeholder. |
| `OutputFolder` | Where the master workbooks are written |
| `Zones` | Zone names that the export file names start with |

## File naming

Zone, OS year and role are read from each file name. A name must start with one of the configured zones and contain `Server <year> <role>`, where the role is `MS` (member server) or `DC` (domain controller):

```
ZONE2 Server 2019 MS Green (SCAN-2019-01) -ZONE2 Server 2019 MS SCAN-.696747
ZONE1 - Windows Server 2022 DC (SCAN-N-2022-03) -ZONE1 - Windows Server 2022 DC SCAN-.696702
```

Files that do not match are skipped with a warning.

## Usage

Run it with no arguments after editing the settings, or override them on the command line:

```powershell
.\Merge-NessusScans.ps1
.\Merge-NessusScans.ps1 -InputFolder '\\fileserver\scans\other' -OutputFolder 'D:\out' -Zones 'ZONE1'
```

## Output

One workbook per zone and role, for example `ZONE1_DC_Master.xlsx` and `ZONE1_MS_Master.xlsx`. Each contains:

- An `All` sheet with every row from every file in the group and a leading `Platform` column
- One sheet per source file, named after its OS year

Existing master workbooks in the output folder are overwritten on every run.

## Notes

- Rows are written in bulk through EPPlus rather than `Export-Excel`, which keeps 100k-row files fast.
- Cells longer than Excel's 32,767 character limit are truncated and reported.
- The run stops if a group would exceed Excel's row limit, or if the column headers differ between files in the same group.
