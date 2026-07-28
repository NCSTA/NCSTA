# Windows Audit developer guide

## Maintainer directory

Use this as the change index. Start with the named module or configuration item instead of rescanning the project.

| Need to change | Start here | Notes |
|---|---|---|
| Command-line options or run sequencing | `Invoke-WindowsAudit.ps1` | Collect and manifest-verification entry points. |
| Output folder, filenames, headers, text encoding, errors, hashing | `Modules/Audit.Common.psm1` | These form the auditor-facing compatibility contract. |
| System, native-command, services, updates, drives, log settings | `Invoke-AuditSystemCollectors` | In `Modules/Audit.Collectors.psm1`. |
| ACLs, file/folder scope, shares | `Invoke-AuditPermissionCollectors` | Target lists are in `Config/AuditTargets.psd1`. |
| Registry scope and output formatting | `Invoke-AuditConfigurationCollectors` / `Get-RegistryReportText` | Registry paths are in `Config/AuditTargets.psd1`. |
| Local accounts and groups | `Get-LocalUserReportText` / `Get-LocalGroupReportText` | Used on non-domain controllers. |
| Privileged accounts on DCs | `Get-AdministrativeAccountReportText` | Group scope is configured by `PrivilegedGroupNames`. |
| AD accounts, groups, trusts, GPO backup | `Invoke-AuditDomainControllerCollectors` | Requires the ActiveDirectory module; GPO backup also requires GroupPolicy. |
| Password, audit, and user-rights export | `Invoke-AuditSecurityPolicyCollector` | Produces `AuditandUserRights.txt`. |
| Report scope only | `Config/AuditTargets.psd1` | Preserve list order for legacy comparison. |

## Design rules

- Require elevation and run only locally. The script does not remediate configuration.
- Continue after collector-level failures and record them in `ErrorLog.txt`; a startup or unrecoverable failure stops the run.
- Keep report filenames, confidentiality header, tab-delimited layout, and legacy `.xls` suffixes unless an auditor-approved change says otherwise.
- Keep values on one logical TSV row. `ConvertTo-AuditField` strips tabs and line breaks; quote escaping is handled by `ConvertTo-AuditQuotedField`.
- Do not add a third-party executable. Use built-in Windows commands and PowerShell/CIM APIs.
- Do not delete a report directory. A timestamp collision gets a numeric suffix, preserving evidence that the VBS could have deleted.
- Each collector must have a small comment-based annotation and be listed in this directory when added or renamed.

## Output contract

The baseline output set is intentionally close to the VBS. `.xls` files are tab-separated text for Excel compatibility; they are not binary Excel workbooks.

| Artifact | Source | Notes |
|---|---|---|
| `(host)SystemInfo.xls` | CIM + `systeminfo.exe` | System, OS, IP, domain, and current identity. |
| `(host)Users.xls`, `(host)Groups.xls` | CIM or ActiveDirectory | Local on member servers; domain data on DCs. |
| `(host)AdministrativeAccounts.xls` | ActiveDirectory | DC-only, recursive members of configured privileged groups with password-last-changed data. |
| `(host)Services.xls`, `(host)HotFixes.xls`, `(host)Drives.xls` | CIM | Maintains tabular text layout. |
| `(host)RegistryValues.xls`, `(host)LogSettings.xls` | Registry provider | Scope defined in configuration. |
| `(host)FilePermissions.xls`, `(host)DirectoryPermissions.xls`, `(host)Shares.xls` | `Get-Acl`, CIM, SMB cmdlets | Includes missing-target and access errors in report/error log. |
| `(host)gpresult.txt` and HTML | `gpresult.exe` | HTML is written beside the text report. |
| `(host)AuditPolicy.txt`, `(host)DetailedAuditSettings.txt` | `auditpol.exe` | Category and subcategory views. |
| `(host)EventLogPermissions.txt`, `(host)Netstat.txt` | `icacls.exe`, `netstat.exe` | Existing auditor-readable style. |
| `(host)ADTrusts.xls`, `GPOBackup` | AD/GroupPolicy on DCs | DC-only. |
| `AuditandUserRights.txt` | `secedit.exe /export` | Replaces the legacy invalid/opaque `secedit` flow. |
| `ErrorLog.txt`, `SHA256SUMS.txt` | Shared utilities | SHA-256 replaces the bundled MD5 executable. |

## Intentional deltas from VBS

These are safety or correctness fixes, not report redesigns:

1. CIM and supported PowerShell providers replace COM-heavy VBS/WMI monikers.
2. `auditpol /get` is used for detailed audit data; the legacy Windows 2008 branch mistakenly wrote `netstat` to that report.
3. Server paths use `$env:windir` / `$env:SystemDrive`, rather than hard-coded `C:\Windows`.
4. SHA-256 manifest verification replaces MD5 and `md5.exe`.
5. `secedit /export` produces a readable policy artifact. The legacy `secedit /analyze` / `export` path had inconsistent input/output files.
6. GPOs are backed up with `Backup-GPO` rather than an unstructured copy of live SYSVOL.
7. Offline missing-patch scanning is disabled by default. Enable it only after the audit owner confirms that the supplied scan package is current and the method is approved for the target operating systems.
8. `AdministrativeAccounts.xls` reports recursively resolved membership of the configured standard privileged AD groups. Add organization-specific privileged groups to `PrivilegedGroupNames`; ACL delegation, GPO preference-based local-group membership, and arbitrary user-right assignments are not inferred.

## Requirements and operation

- Windows PowerShell 5.1 or later, run elevated.
- Built-in CIM, `gpresult`, `auditpol`, `icacls`, `netstat`, and `secedit` utilities.
- Domain-controller reports require the ActiveDirectory module. GPO backup additionally requires the GroupPolicy module.
- Write access to the selected output root. Audit data can include sensitive configuration and identity information; protect the output location accordingly.

Run the parser check before commit:

```powershell
$tokens = $null; $errors = $null
Get-ChildItem . -Recurse -Filter '*.ps1' | ForEach-Object {
  [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
}
$errors
```

## Validation gate for the first audit cycle

Run the VBS and PowerShell editions on one representative member server and one domain controller in a controlled test window. Compare artifact names, report headings, record counts, selected account/group memberships, share ACLs, registry keys, and policy exports. Record every expected difference in this document before auditors rely on the PowerShell result.
