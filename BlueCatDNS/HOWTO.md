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

## Create / Modify Tab

The **Create / Modify** tab is used to find records in a selected zone, create new records, and load existing records for modification.

### Select a Zone

Use the **Zone** list in the upper-right corner to select the zone where the record exists or will be created.

Select the exact target zone. For example, select `domain.com`, not only the parent `com`, when working with `server1.domain.com`.

Changing the selected zone clears the search results and resets the record form.

### Existing Records in Selected Zone

| Control | Function |
|---|---|
| **Search** | Enter a record name or FQDN. Leave it empty to request the first records in the zone. |
| **Search Records** | Loads matching records from the selected zone. |
| **New Record** | Clears the selected search result and resets the form for a new record. It does not create or save anything. |
| **?** | Opens the built-in Create / Modify quick guide. |
| Results grid | Displays record ID, API type, FQDN, value, and TTL. Select a row to load it into the form for modification. |

Search behavior:

- A short value such as `server1` searches the record `name` field.
- A value containing a period, such as `server1.domain.com`, searches `absoluteName`.
- The current API request returns at most 100 records.

Selecting a result automatically:

- Loads the record type, relative name, current value, and TTL.
- Loads the current reverse-record setting for A/Host records.
- Enables **Modify Selected Record**.
- Copies the record entity ID to the **Deploy Tools** tab.

Click **New Record** before creating an unrelated record so an existing search result is not left selected.

### Record Details Controls

| Control | Function |
|---|---|
| **Record Type** | Selects the BlueCat resource-record type and controls the expected value format. |
| **TTL** | Time to live in seconds. The default is `300`; enter a whole number. |
| **Record Name** | Name relative to the selected zone, such as `server1`, `alias`, or `_https._tcp`. Existing zone-apex records display as `@`. |
| **Value / Target** | Record data. Its required format depends on the selected record type. |
| **Task ID** | Ticket, task, or change number. It is sent to BAM as the change-control comment and written to the local activity log. |
| **Deploy immediately after save** | After a successful create or modify, submits a selective deployment for that record entity. |
| **Reverse (PTR) record** | Available only for A/Host records. Controls whether the associated reverse record should be created or retained. |
| **Scheduled deploy disabled** | Informational only. Date and time scheduling controls are disabled in the current JSONL version. |
| **Create Record** | Creates a new record using the current form values. |
| **Modify Selected Record** | Updates the record selected in the results grid after confirmation. |

The reverse-record option is enabled and selected by default for a new A/Host record. Clear it when a PTR record is not required. It is disabled for all other record types.

### Record Type Reference

#### A / Host Record

Creates a BlueCat `HostRecord`.

| Field | Example |
|---|---|
| **Record Name** | `server1` |
| **Value / Target** | `192.0.2.10` |
| **TTL** | `300` |

Use **Reverse (PTR) record** when BAM should also create or maintain the reverse DNS entry for the address.

To create `server1.domain.com`:

1. Select zone `domain.com`.
2. Click **New Record**.
3. Select **A / Host Record**.
4. Enter `server1` in **Record Name**.
5. Enter `192.0.2.10` in **Value / Target**.
6. Confirm the TTL, Task ID, reverse-record choice, and deployment choice.
7. Click **Create Record**.

#### CNAME

Creates a BlueCat `AliasRecord`. A new CNAME must link to an existing record returned by the search grid.

| Field | Example |
|---|---|
| **Record Name** | `alias` |
| **Value / Target** | `server1.domain.com` |
| **TTL** | `300` |

To create `alias.domain.com` pointing to `server1.domain.com`:

1. Select the zone where the alias will be created.
2. Search for `server1.domain.com`.
3. Select the exact target record in **Existing Records in Selected Zone**.
4. Change **Record Type** to **CNAME**.
5. Enter `alias` in **Record Name**.
6. Keep **Value / Target** set to the selected target FQDN.
7. Enter the Task ID and choose whether to deploy immediately.
8. Click **Create Record**.

The create request uses the selected target record ID and type as the BlueCat `linkedRecord`. The tool will reject a CNAME create if the selected row does not match **Value / Target**.

#### MX

Creates a BlueCat `MXRecord`.

| Field | Example |
|---|---|
| **Record Name** | `@` or the mail-enabled name |
| **Value / Target** | `10 mail.domain.com` |
| **TTL** | `300` |

Enter the preference/priority first, followed by one space and the mail-server FQDN. Lower priority numbers are preferred by mail senders.

#### TXT

Creates a BlueCat `TXTRecord`.

| Field | Example |
|---|---|
| **Record Name** | `@`, `_dmarc`, or another relative name |
| **Value / Target** | `v=spf1 include:example.net -all` |
| **TTL** | `300` |

Enter the TXT content in **Value / Target**. Do not add extra surrounding quotation marks unless they are intended to be part of the value.

#### SRV

Creates a BlueCat `SRVRecord`.

| Field | Example |
|---|---|
| **Record Name** | `_https._tcp` |
| **Value / Target** | `10 5 443 server1.domain.com` |
| **TTL** | `300` |

Enter four space-separated values in this order:

```text
priority weight port target
```

The target should be the service host FQDN.

#### Generic

Creates a BlueCat `GenericRecord` for record data that does not have a dedicated option in the GUI.

| Field | Example |
|---|---|
| **Record Name** | Relative record name |
| **Value / Target** | Raw RDATA expected by BAM |
| **TTL** | `300` |

The operator is responsible for supplying valid raw RDATA for the intended record type and BAM version.

### Creating a Record

1. Select the exact zone.
2. Click **New Record** to clear any selected record, except when following the CNAME workflow that requires a selected target.
3. Select the record type.
4. Enter the record name, value, TTL, and Task ID.
5. Review **Reverse (PTR) record** when creating an A/Host record.
6. Select **Deploy immediately after save** only when the record should be deployed now.
7. Click **Create Record**.

Record name and value are required. A successful save displays the new entity ID in the status bar and writes a `CreateRecord` entry to the JSONL activity log.

When immediate deployment is selected, record creation completes first and the tool then submits a selective deployment. If deployment fails, the record may still exist in BAM as an undeployed change; read the error message and Logs tab before retrying.

### Modifying a Record

1. Select the record's exact zone.
2. Search for the record.
3. Select the exact result row.
4. Review the values loaded into **Record Details**.
5. Change the record name, value, TTL, Task ID, or reverse-record setting as needed.
6. Select **Deploy immediately after save** when appropriate.
7. Click **Modify Selected Record**.
8. Review the record ID and new value in the confirmation dialog, then click **Yes**.

The existing record is updated in place; a new record is not created. The modification is written to the JSONL log with the selected entity ID.

For MX and SRV records, keep **Value / Target** in the same documented space-separated format. BlueCat record schemas can differ by BAM release, so verify these modifications in the Logs tab and in BAM before deployment.

When immediate deployment is selected, the update completes first and selective deployment is submitted second. A deployment error does not automatically undo the record modification.

### Create / Modify Safety Notes

- Confirm the selected configuration, view, and zone before saving.
- Use a meaningful Task ID so BAM history and the local log can be correlated.
- Search results show API record types such as `HostRecord` and `AliasRecord`.
- **Create Record** always performs a create, even if a search result remains selected.
- **Modify Selected Record** always updates the selected entity ID.
- Modifying a record preserves its existing API type. Changing the **Record Type** list does not convert the selected record to another type.
- Quick deploy is not used by this tab for create or modify; immediate deployment is selective to the saved entity.
- Scheduled deployment is unavailable. Leave the record undeployed and use **Deploy Tools** when a later manual deployment is required.

## Logs

The old SQLite-backed staging view has been removed. The **Logs** tab now shows recent local action/error logs.

Logs are written to:

```text
.\logs\bluecat-dns-manager-YYYYMMDD.jsonl
```

Use **Refresh Logs** to reload entries, **Clear View** to clear only the visible grid, and **Open Log Folder** to browse the log files.

## Deployment Notes

Immediate deployment uses selective deploy for create/modify actions. Delete with immediate deploy uses quick deploy on the selected zone.

In **Deploy Tools**, select a server from the **Server** list and click **Recent Server Deployments**. The tool loads its newest 50 deployment records, matching the information shown in Integrity under **Servers > [server] > Deployments**. The server list is refreshed whenever the selected configuration changes.

The application account requires permission to read deployment history. Use a returned deployment ID in **Event / Deployment ID** and click **Check ID** to retrieve its current details.

In development BAM environments, deployment may return `400 Bad Request` if no deployable DNS servers or deployment roles exist there. Record create/modify/delete can still be valid in that case; check the **Logs** tab for the detailed BlueCat error response.

Scheduled deployment is disabled in the lightweight JSONL version.
