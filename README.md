# NCSTA

## Projects

### BlueCatDNS
WPF GUI for managing DNS records via the BlueCat Address Manager RESTful v2 API.

### ESXi-to-HyperV
CSV-driven batch migration tool for converting ESXi VMs to Hyper-V via SCVMM V2V, with post-conversion Guest Services enablement and high availability clustering.

### server-qa-checker
WPF GUI for automated server build QA validation with pass/fail checks against t-shirt size templates.

### WIN_Audit
PowerShell replacement for the legacy PwC Windows Configuration Interrogation VBS. The first release prioritizes auditor-facing report compatibility: it emits the same report names, tab-separated text layout, and timestamped host folder. Files ending in `.xls` are deliberately tab-delimited text, matching the legacy script.

Run an elevated Windows PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Invoke-WindowsAudit.ps1 -ClientName 'Example Client' -OutputRoot 'D:\AuditOutput'
```

Use `-Verify` to verify the SHA-256 manifest produced with a completed audit:

```powershell
.\Invoke-WindowsAudit.ps1 -Verify -VerifyPath 'D:\AuditOutput\SERVER-Monday, July 28, 2026 09.30.00 AM'
```

See [the developer guide](docs/WindowsAudit-Developer-Guide.md) for the collector index, compatibility decisions, configuration points, prerequisites, and validation process.
