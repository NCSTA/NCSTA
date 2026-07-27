# Windows Server Retirement - Phase 1 Dependency Audit

## Use Case

This project supports Phase 1 of a Windows Server retirement workflow. It helps infrastructure teams verify whether a target Windows server still has active dependencies before the server is powered off.

The script reads a CSV of retirement targets, checks WinRM connectivity, runs a remote audit against each server, logs all actions locally, and sends an Outlook-compatible HTML email to the owning team when active dependencies are detected.

Servers with no active external TCP connections, no open SMB sessions, and no open SMB file sessions are logged as clear. SMB shares are collected for visibility, but shares with zero active sessions do not trigger an email by themselves.

## Files

- `Invoke-ServerRetirementPhase1.ps1` - production PowerShell workflow script.
- `Sample-RetirementEmail.html` - static HTML preview of the notification email.
- `server_retirement.csv` - expected input file name. Create this file in the same folder as the script before running.
- `Logs` - created automatically at runtime for timestamped audit logs.

## Input CSV Format

Create `server_retirement.csv` in this project folder with these columns:

```csv
Servername,change,Distro,datetoretire,alias
filesrv01.contoso.com,CHG0123456,server-owners@contoso.com,06/15/2026,files.contoso.com;finance-files.contoso.com;legacy-share.contoso.com
```

Column details:

- `Servername` - FQDN of the target Windows server.
- `change` - change control ticket number.
- `Distro` - email address or distribution group for the owning team.
- `datetoretire` - planned power-off date. The email displays this as `MM/dd/yyyy`.
- `alias` - manually entered BlueCat alias records for the server. Use semicolons between aliases, for example `files.contoso.com;legacy-share.contoso.com`.

## Configuration

Open `Invoke-ServerRetirementPhase1.ps1` and review the variables near the top:

```powershell
$SMTPServer = ''
$SMTPPort = 25
$EmailFrom = 'server-retirement@yourcompany.com'
$EmailCc = ''
$EmailUseSsl = $false
$SmtpCredential = $null
$PSRemotingCredential = $null
$PSRemotingAuthentication = 'Default'
$EmailDetailRowLimit = 5
$TcpComputerExclusionList = @(
    '10.10.20.30',
    'scanner01.contoso.com',
    'pentest-*'
)
$ExcludedSmbShareNamePatterns = @(
    '^ADMIN\$$',
    '^IPC\$$',
    '^print\$$',
    '^[A-Z]\$$'
)
```

Set `$SMTPServer` before production use. Set `$EmailCc` to one or more CC recipients if needed, separated by commas or semicolons. Leave `$EmailCc` blank to send no CC. Leave `$PSRemotingCredential` as `$null` to use the current user context, or assign a credential object if the orchestration server requires alternate credentials.

If you use prompted credentials, set the credential like this:

```powershell
$PSRemotingCredential = Get-Credential -Message 'Enter credential for target server PSRemoting'
$PSRemotingAuthentication = 'Default'
```

The authentication value is passed to both `Test-WSMan` and `Invoke-Command`. `Default` is usually correct for domain-joined Windows servers; use `Kerberos`, `Negotiate`, or another supported option only if your WinRM policy requires it.

Use `$TcpComputerExclusionList` to suppress noisy TCP connections from known scanners, domain controllers, or internal pen-testing systems. Entries can be exact IP addresses, FQDNs, short hostnames, or PowerShell wildcard patterns.

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
4. Counts active TCP connections, SMB shares, SMB sessions, and open SMB files.
5. Logs clear servers without sending email.
6. Sends one HTML email per server when dependencies are detected.

## Email Behavior

The email subject identifies the server and change ticket. The email header is formatted as:

```text
<Change> retire <Server>
```

Each email includes:

- Server name, change ticket, and power-off date.
- Server aliases provided in the CSV.
- Total counts for active TCP connections, SMB shares, open SMB sessions, and open file sessions.
- Up to five rows per detail section, controlled by `$EmailDetailRowLimit`.
- A `Showing first X of Y` line above each capped detail table.

Default administrative shares are excluded from the SMB share section by `$ExcludedSmbShareNamePatterns`. The defaults exclude `ADMIN$`, `IPC$`, `print$`, and drive administrative shares such as `C$` and `D$`.

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
- Known scanner computers, domain controllers, or other expected infrastructure peers can be excluded from the Active Processes and TCP Connections section by `$TcpComputerExclusionList`.
- The script exits with code `0` when processing completes without errors, `1` for fatal startup errors, and `2` when one or more server-level errors occur.
