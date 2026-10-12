# Group Owners

Fills in the owner of each access group in a CSV by reading the group's membership from Active Directory, then writes the result to an Excel workbook.

It is built for owner groups that hold a single member: the member's name is recorded as the owner. Groups with several members get all names joined with `; `.

## Requirements

- Windows PowerShell 5.1 or later
- `ActiveDirectory` module (RSAT)
- `ImportExcel` module (`Install-Module ImportExcel -Scope CurrentUser`)

## Input

A CSV with at least these two columns:

| Column | Contents |
|---|---|
| `ID` | Group in `DOMAIN\group-name` form |
| `ID Owners` | Left blank; the script fills it in |

The domain part has `.com` appended to form the AD server name, so `CONTOSO\Share-Finance-M` is looked up against `CONTOSO.com`. Change that line if your domains use a different suffix.

## Usage

Set the two paths at the top of the script, then run it:

```powershell
$CsvPath = "C:\Temp\GroupOwners.csv"
$OutPath = "C:\Temp\GroupOwners.xlsx"
```

```powershell
.\Get-GroupOwners.ps1
```

## Behavior

- Rows that already have an owner, or have no `ID`, are skipped.
- Each distinct group is queried once and cached, so repeated groups cost no extra AD queries.
- A group that cannot be read is left blank and is not retried.
- A summary of rows, AD queries, cache hits and skipped rows is printed at the end.

## Output

`GroupOwners.xlsx` with a `GroupOwners` sheet formatted as a table. The sheet is cleared and rewritten on each run.
