# BlueCat DNS Manager

A PowerShell WPF GUI for managing DNS records via the BlueCat Address Manager RESTful v2 API. Enables ad-hoc DNS record deployment without interfering with scheduled batch deployments.

## Requirements

- Windows 10/11 with PowerShell 5.1+
- BlueCat Address Manager 9.5.0+ with the RESTful v2 API enabled
- Network access to BAM from your management jumpbox

## Quick Start

```powershell
# 1. Run setup (downloads SQLite dependency)
.\scripts\Setup.ps1

# 2. Launch the GUI
.\Launch-BlueCatDnsManager.bat

# If your BAM uses a self-signed certificate:
.\Launch-BlueCatDnsManager-SkipCert.bat
```

## Features

### Create / Modify Records
- Create A, CNAME, MX, TXT, SRV, and Generic records
- Modify existing records by selecting from the zone record grid
- Optional automatic reverse (PTR) record creation
- Deploy immediately via selective deploy or stage for later

### Delete Records
- Search and browse records in any zone
- Delete with optional immediate deployment
- Confirmation dialog prevents accidental deletions

### Staged Items Viewer
- See all changes made through the tool (pending, deployed, failed)
- Track who made each change and when
- Cancel pending changes or deploy them on demand
- Filter by status (All, Pending, Deployed, Failed, Scheduled)

### Deploy Tools
- **Selective Deploy**: Push a single entity by ID without affecting other staged changes
- **Quick Deploy**: Deploy all pending changes in a specific zone
- **Deployment Status**: Check the status of any deployment by ID

### Scheduled Deployments
- Queue a record creation for a future date/time
- A background scheduled task processes the queue automatically

## Project Structure

```
BlueCat-DNS-Manager/
├── BlueCatDnsManager-GUI.ps1      # Main WPF GUI application
├── Launch-BlueCatDnsManager.bat   # Double-click launcher
├── Launch-BlueCatDnsManager-SkipCert.bat
├── modules/
│   ├── BlueCatApi.psm1            # BlueCat v2 API wrapper
│   └── StagingDb.psm1            # SQLite staging database
├── scripts/
│   ├── Setup.ps1                  # Dependency installer
│   ├── ScheduledDeploy.ps1       # Task Scheduler processor
│   └── Register-ScheduledTask.ps1 # Task Scheduler registration
├── data/                          # SQLite DB and credentials (gitignored)
├── lib/                           # System.Data.SQLite.dll (gitignored)
└── logs/                          # Scheduled deploy logs (gitignored)
```

## Setting Up Scheduled Deployments

```powershell
# 1. Create encrypted credential file (run once as your user)
Get-Credential | Export-Clixml .\data\cred.xml

# 2. Register the scheduled task (runs every 5 minutes)
.\scripts\Register-ScheduledTask.ps1 -BamServer bam.corp.local -IntervalMinutes 5
```

The scheduled task runs as your user account and checks the staging database for any jobs whose scheduled time has arrived. Logs are written to `.\logs\`.

## API Endpoints Used

| Operation | v2 Endpoint |
|---|---|
| Login | `POST /api/v2/sessions` |
| Logout | `PATCH /api/v2/sessions/current` |
| List Configs | `GET /api/v2/configurations` |
| List Views | `GET /api/v2/configurations/{id}/views` |
| List Zones | `GET /api/v2/views/{id}/zones` |
| Find Zone | `GET /api/v2/zones?filter=...` |
| List Records | `GET /api/v2/zones/{id}/resourceRecords` |
| Create Record | `POST /api/v2/zones/{id}/resourceRecords` |
| Update Record | `PUT /api/v2/resourceRecords/{id}` |
| Delete Record | `DELETE /api/v2/resourceRecords/{id}` |
| Selective Deploy | `POST /api/v2/deployments` |
| Quick Deploy (Zone) | `POST /api/v2/zones/{id}/deployments` |
| Server Deploy | `POST /api/v2/servers/{id}/deployments` |
| Deploy Status | `GET /api/v2/deployments/{id}` |

## Troubleshooting

**"SQLite library not found"**: Run `.\scripts\Setup.ps1` first, or manually place `System.Data.SQLite.dll` in `.\lib\`.

**TLS/Certificate errors**: Use the `-SkipCertCheck` launcher or add your BAM's CA cert to the Windows trust store.

**"401 Unauthorized"**: Verify your BAM credentials and that the account has API access.

**Selective deploy fails**: Ensure a full deployment has been performed at least once on the target DNS server before using selective deploy.
