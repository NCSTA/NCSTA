# Windows Server Retirement - Phase 1 Dependency Audit

## Use Case

This project supports Phase 1 of a Windows Server retirement workflow. It helps infrastructure teams verify whether a target Windows server still has active dependencies before the server is powered off.

The script reads a CSV of retirement targets, checks WinRM connectivity, runs a remote audit against each server, logs all actions locally, and sends an Outlook-compatible HTML email to the owning team when active dependencies are detected.

Servers with no active external TCP connections, no open SMB sessions, and no open SMB file sessions are logged as clear. Custom SMB shares with zero active sessions do not trigger an email.

## Files

- `Invoke-ServerRetirementPhase1.ps1` - production PowerShell workflow script.
- `Sample-RetirementEmail.html` - static HTML preview of the notification email.
- `server_retirement.csv` - expected input file name. Create this file in the same folder as the script before running.
- `Logs` - created automatically at runtime for timestamped audit logs.

## Input CSV Format

Create `server_retirement.csv` in this project folder with these columns:

```csv
Servername,change,Distro,datetoretire
filesrv01.contoso.com,CHG0123456,server-owners@contoso.com,06/15/2026
```

Column details:

- `Servername` - FQDN of the target Windows server.
- `change` - change control ticket number.
- `Distro` - email address or distribution group for the owning team.
- `datetoretire` - planned power-off date. The email displays this as `MMddyyyy`.

## Configuration

Open `Invoke-ServerRetirementPhase1.ps1` and review the variables near the top:

```powershell
$SMTPServer = ''
$SMTPPort = 25
$EmailFrom = 'server-retirement@yourcompany.com'
$EmailUseSsl = $false
$SmtpCredential = $null
$PSRemotingCredential = $null
$EmailDetailRowLimit = 5
```

Set `$SMTPServer` before production use. Leave `$PSRemotingCredential` as `$null` to use the current user context, or assign a credential object if the orchestration server requires alternate credentials.

## Running The Audit

Run from an elevated PowerShell session on the management or orchestration server:

```powershell
Set-Location C:\Path\To\Server-Retirement
.\Invoke-ServerRetirementPhase1.ps1
```

The script performs these steps for each CSV row:

1. Validates required CSV columns.
2. Checks WinRM connectivity with `Test-WSMan`.
3. Runs the remote `Test-ServerRetirementEligibility` audit.
4. Counts active non-excluded TCP connections, SMB sessions, and open SMB files.
5. Logs clear servers without sending email.
6. Sends one HTML email per server when dependencies are detected.

## Email Behavior

The email subject identifies the server and change ticket. The email header is formatted as:

```text
<Change> retire <Server>
```

Each email includes:

- Server name, change ticket, and power-off date.
- Total counts for external connections, open SMB sessions, and open file sessions.
- Up to five rows per detail section, controlled by `$EmailDetailRowLimit`.
- A `Showing first X of Y` line above each capped detail table.

The HTML template is table-based with inline styles for Outlook compatibility and uses only these colors:

- `#007b86`
- `#f4f4f4`
- `#ffffff`

## Logging

Logs are written under:

```text
.\Logs\Retirement_Phase1_yyyyMMdd_HHmmss.log
```

The log records CSV import, WinRM connectivity, remote audit execution, dependency counts, clear-server skips, email success or failure, and script errors.

## Operational Notes

- WinRM must be enabled and reachable on each target server.
- The account running the script must have permission to query TCP connections, SMB sessions, SMB open files, and process owner details on target servers.
- Native management agent processes are excluded by `$NativeProcessExclusionList`.
- The script exits with code `0` when processing completes without errors, `1` for fatal startup errors, and `2` when one or more server-level errors occur.
