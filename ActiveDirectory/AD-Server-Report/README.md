# AD Server Report

Exports every enabled Windows Server computer account from one or more Active Directory domains to an Excel workbook and a standalone HTML report.

## Requirements

- Windows PowerShell 5.1 or later
- `ActiveDirectory` module (RSAT)
- `ImportExcel` module (`Install-Module ImportExcel -Scope CurrentUser`)
- Read access to each domain being queried

## Usage

Pass the domains on the command line:

```powershell
.\Export-ADServersReport.ps1 -Domains 'contoso.com', 'emea.contoso.com' -OutputDirectory 'C:\temp'
```

Or add them to the `$Domains` default at the top of the script and run it with no arguments.

| Parameter | Default | Purpose |
|---|---|---|
| `-Domains` | empty | DNS names of the domains to query |
| `-OutputDirectory` | `C:\temp` | Folder the workbook and HTML report are written to |

## What is included

A computer account is reported when all of these are true:

- `OperatingSystem` matches `Windows*server*`
- The account is enabled
- The account has an IPv4 address registered
- The name does not end in `z`, `l`, or `z` followed by two digits

Adjust the name filter in the script if your naming convention differs.

## Output

| File | Contents |
|---|---|
| `AD_Servers_Export_<timestamp>.xlsx` | `Overview`, `OS Totals`, `Raw OS Totals`, `Domain Totals` and `Domain OS Breakdown` sheets, plus one sheet per domain |
| `AD_Servers_Report_<timestamp>.html` | Self-contained report built from the same data |

Each server row lists hostname, domain, DNS host name, IP, operating system and OS family (Windows Server 2003 through 2025).
