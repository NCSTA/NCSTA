# BlueCat DNS Manager - User Guide

## Launching

```powershell
.\scripts\Setup.ps1
.\BlueCatDnsManager-GUI.ps1
```

Use `.\BlueCatDnsManager-GUI.ps1 -SkipCertCheck` if the BAM certificate is self-signed or issued by an internal CA that is not trusted by Windows.

## Connecting

1. Enter the BAM hostname or IP in **Server**.
2. Click **Connect**.
3. Enter BAM credentials in the PowerShell credential prompt.
4. Select the configuration and view.
5. The Zone dropdowns load top-level zones and child zones recursively.

## Searching Records

Select the target zone first. For example, select `domain.com`, not only the parent `com`, when searching for `server1.domain.com`.

Short searches such as `server1` search the record `name` field. FQDN-like searches such as `server1.domain.com` search `absoluteName`.

## Creating a CNAME

To create `alias.domain.com -> server1.domain.com`:

1. Select zone `domain.com`.
2. Search for `server1.domain.com`.
3. Select the target row in **Existing Records in Zone**.
4. Set **Record Type** to `CNAME`.
5. Set **Record Name** to `alias`.
6. Set **Value / Target** to `server1.domain.com`.
7. Click **Create Record**.

The API request uses the selected target record ID as `linkedRecord`.

## Logs

The old SQLite-backed staging view has been removed. The **Logs** tab now shows recent local action/error logs.

Logs are written to:

```text
.\logs\bluecat-dns-manager-YYYYMMDD.jsonl
```

Use **Refresh Logs** to reload entries, **Clear View** to clear only the visible grid, and **Open Log Folder** to browse the log files.

## Deployment Notes

Immediate deployment uses selective deploy for create/modify actions. Delete with immediate deploy uses quick deploy on the selected zone.

In development BAM environments, deployment may return `400 Bad Request` if no deployable DNS servers or deployment roles exist there. Record create/modify/delete can still be valid in that case; check the **Logs** tab for the detailed BlueCat error response.

Scheduled deployment is disabled in the lightweight JSONL version.
