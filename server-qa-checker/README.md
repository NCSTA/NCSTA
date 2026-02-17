# Server QA Checker

PowerShell 5.1 WPF tool for validating Windows server build state against JSON templates.

## What It Does

- Collects server data remotely using WinRM
- Validates collected data against template rules
- Shows categorized pass/fail/warn/info/error results
- Exports results to HTML and CSV
- Optionally removes fully passed servers from patch AD groups

## Folder Structure

```text
server-qa-checker/
|-- Launch-ServerQaChecker.bat
|-- ServerQaChecker-GUI.ps1
|-- README.md
|-- modules/
|   |-- QaDataCollector.psm1
|   |-- QaValidationEngine.psm1
|   `-- QaResultExporter.psm1
|-- templates/
|   `-- *.json
|-- reports/   (created at runtime)
`-- logs/      (created at runtime)
```

## Requirements

- Windows + PowerShell 5.1+
- WinRM access to target servers
- Permission to run remote collection commands on target
- RSAT ActiveDirectory module for:
  - OU validation check
  - Remove From Patch Group action
- AD rights to remove computer objects from patch groups (if using remediation)

## Launch

### Recommended

Double-click:

- `Launch-ServerQaChecker.bat`

### Terminal

```powershell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\ServerQaChecker-GUI.ps1
```

## Runtime Flow

1. GUI loads templates from `templates/*.json`
2. User selects server + template and clicks **Run QA**
3. `QaDataCollector.psm1` collects raw data
4. `QaValidationEngine.psm1` evaluates checks
5. GUI renders grouped results and summary stats
6. Optional export writes HTML/CSV to `reports/`
7. If all checks pass (no Fail/Error), **Remove From Patch Group** is enabled

## Script Responsibilities

### `ServerQaChecker-GUI.ps1`

- Defines WPF layout and UI behavior
- Imports modules and loads templates
- Runs data collection + validation
- Builds grouped result panels and summary bar
- Handles:
  - Run QA
  - Failures-only filter
  - Export HTML/CSV
  - Remove From Patch Group
  - Patch debug logging toggle

### `modules/QaDataCollector.psm1`

- Exports `Get-QaServerData`
- Performs:
  - Connectivity test
  - Single `Invoke-Command` block for remote checks (CPU, memory, software, network, admins, hotfixes, ACL flags, F: drive, traceroute, VMware Tools, activation)
  - OU lookup via `Get-ADComputer` locally
- Returns standardized object structure for validation

### `modules/QaValidationEngine.psm1`

- Exports `Invoke-QaValidation`
- Contains per-check validators and comparison logic
- Status values:
  - `Pass`, `Fail`, `Warn`, `Error`, `Info`, `Skip`
- Drive ACL policy currently enforces `'Everyone' removed` when drive permissions check is configured

### `modules/QaResultExporter.psm1`

- Exports:
  - `Export-QaResultsHtml`
  - `Export-QaResultsCsv`
- Produces:
  - Styled HTML report grouped by category
  - Flat CSV with check-level rows

## Template Model

Templates are JSON files under `templates/` with top-level `checks`.

Common check keys used by the engine:

- `connectivity`
- `cpu`
- `memoryGB`
- `installedSoftware`
- `ipConfig`
- `localAdmins`
- `recentHotfixes`
- `drivePermissions`
- `fDrive`
- `traceroute`
- `vmwareTools`
- `winActivation`
- `ouPath`

Most checks support:

- `enabled`
- `expected` / `operator` (where applicable)

## Remove From Patch Group (AD Remediation)

Button behavior:

- Searches configured patch groups across domains
- Uses `Get-ADGroup` + ranged `member` retrieval instead of `Get-ADGroupMember`
- Resolves foreign security principal SID entries to NT account names for cross-domain matching
- Removes matched member by distinguished name via `Remove-ADGroupMember`

### Patch Debug

If **Patch Debug** is checked in the status bar, detailed lookup/removal traces are written to:

- `logs/PatchGroupDebug-YYYYMMDD.log`

## Outputs

- HTML report: `reports/QA-<server>-<timestamp>.html`
- CSV report: `reports/QA-<server>-<timestamp>.csv`
- Optional patch debug logs: `logs/PatchGroupDebug-YYYYMMDD.log`

## Common Troubleshooting

### QA fails immediately

- Verify server name/FQDN
- Verify WinRM connectivity and firewall policy
- Confirm account has remote query permissions

### OU check returns error

- Confirm RSAT AD module is installed
- Confirm AD lookup rights for target domain

### Remove From Patch Group fails

- Confirm ActiveDirectory module availability
- Confirm delegated rights for group modification
- Enable **Patch Debug** and inspect `logs/PatchGroupDebug-YYYYMMDD.log`

### Export fails

- Confirm `reports/` is writable
- Close existing report file if locked by another process

## Notes

- `reports/` and `logs/` are created automatically at startup if missing.
- `Launch-ServerQaChecker.bat` passes all command-line args through to the main script.
