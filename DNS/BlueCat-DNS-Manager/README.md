# BlueCat DNS Manager

A lightweight PowerShell WPF GUI for managing DNS records via the BlueCat Address Manager RESTful v2 API.

The GUI supports record create/modify/delete operations, optional immediate deployment, and local JSONL logging for troubleshooting. It does not require SQLite or native database DLLs.

## Requirements

- Windows 10/11 or Windows Server with Desktop Experience
- PowerShell 5.1+
- BlueCat Address Manager 9.5.0+ with RESTful v2 API enabled
- Network access to BAM from the management workstation

## Quick Start

```powershell
# Create data\ and logs\ folders
.\scripts\Setup.ps1

# Launch the GUI
.\Launch-BlueCatDnsManager.bat

# If BAM uses a self-signed certificate:
.\Launch-BlueCatDnsManager-SkipCert.bat
```

## Documentation

- [Codebase and collaboration guide](docs/bluecat-dns-manager/README.md)
- [Operator guide](HOWTO.md)

## Features

### Create / Modify Records
- Create A, CNAME, MX, TXT, SRV, and Generic records
- Modify existing records by selecting from the zone record grid
- Optional automatic reverse (PTR) record creation
- Optional immediate selective deploy

### Delete Records
- Search and browse records in any selectable zone
- Delete with optional immediate zone quick deploy
- Confirmation dialog prevents accidental deletions

### Logs
- View recent GUI actions and API errors in the **Logs** tab
- Log files are written as JSON lines to `.\logs\bluecat-dns-manager-YYYYMMDD.jsonl`
- Error logging includes richer REST failure details when BlueCat returns them

### Deploy Tools
- **Selective Deploy**: Push a single entity ID via `POST /api/v2/deployments`
- **Quick Deploy**: Deploy all pending changes in a specific zone
- **Deployment Status**: Check the status of a deployment by ID

## Project Structure

```text
BlueCatDNS/
|-- BlueCatDnsManager-GUI.ps1
|-- Launch-BlueCatDnsManager.bat
|-- Launch-BlueCatDnsManager-SkipCert.bat
|-- modules/
|   `-- BlueCatApi.psm1
|-- scripts/
|   `-- Setup.ps1
|-- docs/
|   `-- bluecat-dns-manager/
|       `-- README.md
|-- data/                              Runtime directory
`-- logs/                              Runtime directory
```

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
| Record Addresses | `GET /api/v2/resourceRecords/{id}/addresses` |
| Create Record | `POST /api/v2/zones/{id}/resourceRecords` |
| Update Record | `PUT /api/v2/resourceRecords/{id}` |
| Delete Record | `DELETE /api/v2/resourceRecords/{id}` |
| Selective Deploy | `POST /api/v2/deployments` |
| Quick Deploy (Zone) | `POST /api/v2/zones/{id}/deployments` |
| Server Deploy | `POST /api/v2/servers/{id}/deployments` |
| Deploy Status | `GET /api/v2/deployments/{id}` |

## Troubleshooting

**TLS/Certificate errors**: Use `Launch-BlueCatDnsManager-SkipCert.bat`, or add BAM's issuing CA certificate to Windows trust.

**401 Unauthorized**: Verify the BAM username/password and that the account has API permissions.

**400 on deploy in dev**: Record changes can work while deployment fails if the dev BAM environment has no deployable DNS servers/roles. Check the **Logs** tab for the detailed BlueCat response.

**Selective deploy fails**: Ensure the target DNS server is configured for deployment and has had a full deployment at least once.
