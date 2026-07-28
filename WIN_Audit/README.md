# Windows Audit

PowerShell replacement for the legacy PwC Windows Configuration Interrogation VBS. The first release prioritizes auditor-facing report compatibility: it emits the same report names, tab-separated text layout, and timestamped host folder. Files ending in `.xls` are deliberately tab-delimited text, matching the legacy script.

Run an elevated Windows PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Invoke-WindowsAudit.ps1 -OutputRoot 'D:\AuditOutput'
```

`ClientName` defaults to the local computer name. Override it when the report header should use a client or engagement label:

```powershell
.\Invoke-WindowsAudit.ps1 -ClientName 'Example Client' -OutputRoot 'D:\AuditOutput'
```

Use `-Verify` to verify the SHA-256 manifest produced with a completed audit:

```powershell
.\Invoke-WindowsAudit.ps1 -Verify -VerifyPath 'D:\AuditOutput\SERVER-Monday, July 28, 2026 09.30.00 AM'
```

GPO backup is disabled by default. On a domain controller, add `-IncludeGpoBackup` only when the audit scope requires a `Backup-GPO` export:

```powershell
.\Invoke-WindowsAudit.ps1 -OutputRoot 'D:\AuditOutput' -IncludeGpoBackup
```

See [the developer guide](docs/WindowsAudit-Developer-Guide.md) for the collector index, compatibility decisions, configuration points, prerequisites, and validation process.
