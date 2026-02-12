# BlueCat DNS Manager - User Guide

## Table of Contents

1. [First-Time Setup](#first-time-setup)
2. [Launching the Application](#launching-the-application)
3. [Connecting to BlueCat Address Manager](#connecting-to-bluecat-address-manager)
4. [Ad-Hoc Deploy: Push a Single Record Without Affecting Staged Batches](#ad-hoc-deploy-push-a-single-record-without-affecting-staged-batches)
5. [Ad-Hoc Remove: Delete a Single Record Without Affecting Staged Batches](#ad-hoc-remove-delete-a-single-record-without-affecting-staged-batches)
6. [Creating a DNS Record](#creating-a-dns-record)
7. [Modifying an Existing DNS Record](#modifying-an-existing-dns-record)
8. [Deleting a DNS Record](#deleting-a-dns-record)
9. [Viewing Staged Items](#viewing-staged-items)
10. [Scheduling a Future Deployment](#scheduling-a-future-deployment)
11. [Using Deploy Tools](#using-deploy-tools)
12. [Setting Up the Scheduled Task Processor](#setting-up-the-scheduled-task-processor)
13. [Deploying to Windows Server 2022](#deploying-to-windows-server-2022)
14. [Troubleshooting](#troubleshooting)

---

## First-Time Setup

Before using the application for the first time, you need to download a required
dependency (System.Data.SQLite).

### Steps

1. Open PowerShell as your normal user (admin is not required)

2. Navigate to the project folder:
   ```powershell
   cd C:\Path\To\BlueCat-DNS-Manager
   ```

3. Run the setup script:
   ```powershell
   .\scripts\Setup.ps1
   ```

4. The script will:
   - Create the `lib\`, `data\`, and `logs\` directories
   - Download `System.Data.SQLite.dll` from NuGet
   - Copy it and the native interop DLL to `.\lib\`

5. You should see all `[OK]` checks at the end:
   ```
   Verification:
     [OK] System.Data.SQLite.dll
     [OK] data\ directory
     [OK] logs\ directory
   ```

> **If the auto-download fails** (e.g. no internet access on the jumpbox), see
> the [Manual SQLite Install](#manual-sqlite-install) section in Troubleshooting.

---

## Launching the Application

### Option A: Double-click the batch file

Navigate to the project folder in File Explorer and double-click:

- **`Launch-BlueCatDnsManager.bat`** for normal use
- **`Launch-BlueCatDnsManager-SkipCert.bat`** if your BAM uses a self-signed certificate

### Option B: From PowerShell

```powershell
# Normal launch
.\BlueCatDnsManager-GUI.ps1

# With self-signed cert bypass
.\BlueCatDnsManager-GUI.ps1 -SkipCertCheck

# Pre-fill the server field
.\BlueCatDnsManager-GUI.ps1 -BamServer bam.corp.local -SkipCertCheck
```

---

## Connecting to BlueCat Address Manager

1. In the top bar, enter your **BAM server hostname or IP** in the Server field
   (e.g. `bam.corp.local` or `10.0.1.50`)

2. Click **Connect**

3. A Windows credential prompt will appear. Enter your **BAM username and
   password** (the same credentials you use to log into the BAM web UI)

4. On successful connection:
   - The status light turns **green**
   - The **Configuration** dropdown populates automatically
   - Select your configuration (most environments have one)
   - The **View** dropdown populates after selecting a configuration
   - Select your view
   - Zones load automatically into all zone dropdowns throughout the app

5. To disconnect, click **Disconnect** (the button toggles)

> **Tip:** If you get a connection error mentioning TLS or certificate, relaunch
> using `Launch-BlueCatDnsManager-SkipCert.bat` instead.

---

## Ad-Hoc Deploy: Push a Single Record Without Affecting Staged Batches

This is the primary use case for this tool. Your team stages DNS changes
throughout the day and waits for the scheduled deployment window. But sometimes
you need a record live **right now** for an incident, a migration, or a cutover
and you cannot afford to push everything in the staging queue.

### How it works

BlueCat Address Manager has two separate deployment mechanisms:

| Method | What it pushes | API endpoint |
|---|---|---|
| **Scheduled / Full Deploy** | Everything staged for a server | `POST /api/v2/servers/{id}/deployments` |
| **Selective Deploy** | Only the single record you specify (plus its related dependencies) | `POST /api/v2/deployments` |

This tool uses **selective deploy**. When you create or modify a record with
"Deploy immediately" checked, it calls the selective deploy endpoint targeting
only that specific record's entity ID. All other records sitting in the staging
queue are left completely untouched.

### Walkthrough: Create a new record and push it to prod immediately

**Scenario:** An incident requires a new CNAME `failover.corp.local` pointing
to `backup-lb.corp.local` and it needs to be live in seconds, not at the next
deployment window.

1. Open the app, connect to BAM (see [Connecting](#connecting-to-bluecat-address-manager))

2. Go to the **Create / Modify** tab

3. Fill in the form:
   - **Record Type:** CNAME
   - **Record Name:** `failover`
   - **Zone:** `corp.local`
   - **Value / Target:** `backup-lb.corp.local`
   - **TTL:** `60` (low TTL for an incident)

4. Make sure **"Deploy immediately after save"** is **checked**

5. Click **Create Record**

6. The tool does two API calls back-to-back:
   - `POST /api/v2/zones/{zoneId}/resourceRecords` - creates the record in BAM
   - `POST /api/v2/deployments` with the new record's entity ID - pushes ONLY
     this record to the DNS servers

7. The status bar shows: **"Record created and deployed (Entity: 12345)"**

8. The record is now live on your DNS servers. Nothing else in the staging
   queue was touched.

### Walkthrough: Modify an existing record and push only that change

**Scenario:** `app.corp.local` currently points to `10.0.1.50` but you need to
swing it to `10.0.1.75` immediately for a migration. There are 30 other records
staged that should NOT go out yet.

1. Go to the **Create / Modify** tab

2. Select the zone `corp.local` from the **Zone** dropdown

3. Type `app` in the search box and click **Search Zone Records**

4. Click on the `app.corp.local` row in the record grid

5. In the **Value / Target** field, enter `10.0.1.75`

6. Make sure **"Deploy immediately after save"** is **checked**

7. Click **Modify Selected Record** and confirm

8. The tool calls:
   - `PUT /api/v2/resourceRecords/{id}` - updates the record value
   - `POST /api/v2/deployments` - selectively deploys ONLY this record

9. Done. The 30 other staged records remain staged and will go out at their
   normal deployment window.

### What if I do NOT want to deploy yet?

Simply **uncheck** "Deploy immediately after save" before clicking Create or
Modify. The record will be created/modified in BAM (it becomes part of the
normal staging queue) and tracked in your local Staged Items view. You can
deploy it later from the **Staged Items** tab by selecting it and clicking
**Deploy Selected Now**.

### Verifying it worked

After any deployment, go to the **Deploy Tools** tab and enter the deployment ID
shown in the status bar. Click **Check Status** to see the deployment result
JSON from BAM.

---

## Ad-Hoc Remove: Delete a Single Record Without Affecting Staged Batches

Deleting a record follows a similar pattern, but with one key difference in how
deployment works.

### The deletion deployment difference

When you delete a record in BAM, the entity ID ceases to exist. That means
selective deploy (which targets a specific entity ID) cannot be used after a
delete. Instead, the tool uses **quick deploy on the zone**, which pushes all
pending changes in that specific zone to the DNS servers.

> **Important:** If you have other staged changes **in the same zone** that you
> do not want pushed yet, see [Safe deletion when other changes are staged in
> the same zone](#safe-deletion-when-other-changes-are-staged-in-the-same-zone)
> below.

### Walkthrough: Delete a record and push the deletion immediately

**Scenario:** A decommissioned server still has a DNS record `oldserver.corp.local`
pointing to `10.0.1.30`. It needs to be removed now because it is causing
connectivity issues.

1. Go to the **Delete Record** tab

2. Select zone `corp.local` from the dropdown

3. Type `oldserver` in the search box and click **Search**

4. Click on the `oldserver.corp.local` row in the grid

5. Enter a **Comment** (e.g. "Removing decom'd server - ticket INC-4421")

6. Make sure **"Deploy immediately after delete"** is **checked**

7. Click **Delete Selected Record** (the red button)

8. Confirm the deletion in the warning dialog

9. The tool does:
   - `DELETE /api/v2/resourceRecords/{id}` - removes the record from BAM
   - `POST /api/v2/zones/{zoneId}/deployments` - quick deploys the zone so the
     deletion takes effect on the DNS servers

10. The status bar shows: **"Record deleted and zone deployed"**

### Safe deletion when other changes are staged in the same zone

If you know there are other pending changes in `corp.local` that you do NOT
want deployed yet:

1. **Uncheck** "Deploy immediately after delete"

2. Click **Delete Selected Record** and confirm

3. The record is removed from BAM but the zone is NOT deployed. The deletion
   sits in the staging queue alongside other changes.

4. You now have two options to deploy just the deletion:

   **Option A: Wait for the normal deployment window.** The deletion will go out
   with the next full deploy along with everything else staged.

   **Option B: Use selective deploy from Deploy Tools.** Go to the **Deploy
   Tools** tab, enter the entity ID of the deleted record (shown in the Staged
   Items tab), and click **Selective Deploy**. Note: this may or may not work
   depending on BAM version and timing - the entity may already be gone.

   **Option C: Coordinate with your team.** Confirm that all changes in the zone
   are ready, then use **Quick Deploy Zone** from the Deploy Tools tab to push
   the entire zone.

### Summary: When staged batches are safe

| Action | Deploy method used | Other staged records affected? |
|---|---|---|
| Create + Deploy immediately | Selective deploy (entity ID) | **No** - only the new record is pushed |
| Modify + Deploy immediately | Selective deploy (entity ID) | **No** - only the modified record is pushed |
| Delete + Deploy immediately | Quick deploy (zone) | **Yes** - all pending changes in that zone are pushed |
| Delete + Deploy UNchecked | Nothing deployed | **No** - deletion sits in staging queue |
| Deploy from Staged Items tab | Selective deploy (entity ID) | **No** - only the selected record is pushed |
| Quick Deploy from Deploy Tools | Quick deploy (zone) | **Yes** - all pending changes in that zone are pushed |

---

## Creating a DNS Record

Use the **Create / Modify** tab.

### Steps

1. Select the **Record Type** from the dropdown:
   - **A / Host Record** - maps a hostname to an IP address
   - **CNAME** - alias pointing to another hostname
   - **MX** - mail exchange record
   - **TXT** - text record (SPF, DKIM, etc.)
   - **SRV** - service locator record
   - **Generic** - raw record with custom rdata

2. Enter the **Record Name** (the short name, not the FQDN).
   For example, to create `webserver.corp.local`, enter just `webserver`

3. Select the **Zone** from the dropdown (e.g. `corp.local`)

4. Enter the **Value / Target**:

   | Record Type | What to enter in Value | Example |
   |---|---|---|
   | A / Host Record | IP address | `10.0.1.100` |
   | CNAME | Target FQDN | `webserver.corp.local` |
   | MX | Priority + mail server | `10 mail.corp.local` |
   | TXT | Text content | `v=spf1 include:corp.local ~all` |
   | SRV | Priority Weight Port Target | `10 60 5060 sip.corp.local` |
   | Generic | Raw rdata | (depends on record type) |

5. Set the **TTL** (time-to-live in seconds, default 300 = 5 minutes)

6. (Optional) Enter a **Comment** for change tracking

7. Choose your deployment option:
   - **"Deploy immediately after save"** (checked by default) - creates the
     record AND pushes it to the DNS servers right away via selective deploy.
     This does NOT affect any other staged records.
   - **Uncheck it** to create the record in BAM only (it will sit in the staged
     queue until the next scheduled deployment or until you manually deploy it)

8. (Optional) Check **"Create reverse (PTR) record"** for A records if you want
   the PTR created automatically

9. Click **Create Record**

10. The status bar at the bottom will confirm success and show the entity ID

### What happens behind the scenes

- The record is created via `POST /api/v2/zones/{zoneId}/resourceRecords`
- If "Deploy immediately" is checked, a selective deploy fires via
  `POST /api/v2/deployments` targeting ONLY that record
- The action is logged to the local staging database with your username,
  timestamp, and deployment status

---

## Modifying an Existing DNS Record

Use the **Create / Modify** tab.

### Steps

1. Select the **Zone** containing the record you want to modify

2. In the **Existing Records in Zone** section at the bottom, optionally type a
   search term in the search box

3. Click **Search Zone Records** to load records from BAM

4. **Click on the record** you want to modify in the grid to select it

5. In the form fields above, enter the **new value** you want and/or adjust the TTL

6. Make sure "Deploy immediately" is checked if you want the change live right away

7. Click **Modify Selected Record**

8. Confirm the modification in the popup dialog

> **Important:** The modify operation updates the record in BAM and then uses
> selective deploy to push ONLY that change. Your other staged records remain
> untouched.

---

## Deleting a DNS Record

Use the **Delete Record** tab.

### Steps

1. Select the **Zone** from the dropdown

2. (Optional) Enter a search term to filter records

3. Click **Search** to load records

4. **Click on the record** you want to delete in the grid

5. (Optional) Enter a **Comment** explaining the deletion

6. Make sure **"Deploy immediately after delete"** is checked if you want the
   deletion live right away

7. Click **Delete Selected Record** (red button)

8. Confirm the deletion in the warning dialog

> **Note:** For delete + deploy, the tool uses a **quick deploy on the zone**
> rather than selective deploy, because the entity no longer exists after
> deletion. This will deploy all pending changes in that specific zone. If you
> have other staged changes in the same zone that you do not want deployed yet,
> uncheck "Deploy immediately" and handle the deployment separately.

---

## Viewing Staged Items

Use the **Staged Items** tab.

This tab shows every DNS change made through this tool, along with who made it
and its current status.

### Column descriptions

| Column | Description |
|---|---|
| ID | Internal staging database ID |
| Action | `create`, `modify`, or `delete` |
| Type | Record type (HostRecord, AliasRecord, etc.) |
| Name | Record name that was changed |
| Zone | Zone the record belongs to |
| Value | Record value (IP, target, text, etc.) |
| Deploy | `immediate`, `manual`, or `scheduled` |
| Scheduled | Date/time if this is a scheduled deployment |
| Status | `pending`, `deploying`, `deployed`, `failed`, or `cancelled` |
| Created By | BAM username who made the change |
| Created | Timestamp when the change was made |
| Deployed | Timestamp when it was deployed (if applicable) |
| Error | Error message if deployment failed |

### Filtering

Use the **Filter** dropdown to narrow the view:
- **All** - shows everything
- **Pending** - changes waiting to be deployed
- **Deployed** - successfully deployed changes
- **Failed** - changes that failed to deploy
- **Scheduled** - future scheduled deployments

Click **Refresh** to reload the data.

### Actions

- **Cancel Selected** - cancels a pending or failed item (sets status to
  `cancelled`). The record change in BAM is NOT reverted, it just will not be
  deployed through this tool.
- **Deploy Selected Now** - takes a pending item and deploys it immediately via
  selective deploy.

---

## Scheduling a Future Deployment

Use the **Create / Modify** tab with the Schedule section.

### Steps

1. Fill in the record details as you would for a normal create

2. Check **"Schedule deployment for:"**

3. Select the **date** using the date picker

4. Select the **time** from the dropdown or type a custom time, then choose
   **AM** or **PM**

5. Click **Create Record**

The record will be created in BAM immediately but will NOT be deployed. Instead,
it is logged to the staging database with a `scheduled` deploy mode and the
specified date/time.

### How scheduled records get deployed

A separate background process (`ScheduledDeploy.ps1`) runs on a timer via
Windows Task Scheduler. Every 5 minutes (configurable), it:

1. Checks the staging database for any scheduled jobs whose time has arrived
2. Connects to BAM using pre-stored credentials
3. Deploys each due record via selective deploy
4. Updates the staging database with success/failure status
5. Writes a log file to `.\logs\`

See [Setting Up the Scheduled Task Processor](#setting-up-the-scheduled-task-processor)
for setup instructions.

---

## Using Deploy Tools

The **Deploy Tools** tab provides direct access to BlueCat deployment operations.

### Selective Deploy

Deploys a single entity (record) and its related records without pushing
anything else that is staged.

1. Enter the **Entity ID** (the BAM resource record ID - visible in the record
   grids on other tabs)
2. Click **Selective Deploy**
3. Results appear in the output box below

**When to use:** After making a change in the BAM UI or via another tool, and
you want to push just that one record.

### Quick Deploy (Zone)

Deploys ALL pending changes in the selected zone.

1. Select a **Zone** from the dropdown
2. Click **Quick Deploy Zone**
3. Confirm the warning dialog
4. Results appear in the output box

**When to use:** When you want to push everything staged in one zone but not
in other zones.

> **Warning:** Quick deploy pushes ALL changes in the zone, not just yours.

### Deployment Status Check

Check the progress of any deployment.

1. Enter the **Deployment ID** (returned by selective or quick deploy operations)
2. Click **Check Status**
3. The deployment status JSON appears in the output box

---

## Setting Up the Scheduled Task Processor

This is a one-time setup to enable the scheduled deployment feature.

### Step 1: Create an encrypted credential file

Open PowerShell in the project directory and run:

```powershell
Get-Credential | Export-Clixml .\data\cred.xml
```

Enter the BAM username and password that the scheduled task should use. This is
typically a service account with API access.

> **Security note:** The credential file is encrypted using Windows DPAPI, tied
> to your user profile on this specific machine. It cannot be read by other
> users or on other machines.

### Step 2: Register the scheduled task

```powershell
.\scripts\Register-ScheduledTask.ps1 -BamServer bam.corp.local
```

Optional parameters:
- `-IntervalMinutes 10` - check every 10 minutes instead of the default 5
- `-SkipCertCheck` - if your BAM uses a self-signed certificate

### Step 3: Verify

Open Task Scheduler (`taskschd.msc`) and look for a task named
**BlueCat-DNS-ScheduledDeploy**. It should show as Ready.

### Viewing logs

Scheduled deployment logs are written to `.\logs\` with timestamps:
```
.\logs\scheduled_deploy_20250610_030005.log
```

---

## Deploying to Windows Server 2022

### Requirements

Windows Server 2022 works if installed with **Desktop Experience** (the default
GUI installation option). This is the same edition you use when you RDP into a
server and see a desktop with Start menu.

If your jumpboxes have a desktop and you can open PowerShell ISE, you have
Desktop Experience and the tool will work with no changes.

### What does NOT work

- **Server Core** (no GUI) cannot run the WPF GUI. However, the scheduled
  deployment processor (`ScheduledDeploy.ps1`) works fine on Server Core.

### Deployment steps

1. Copy the entire project folder to the server

2. Run setup to install the SQLite dependency:
   ```powershell
   .\scripts\Setup.ps1
   ```

3. Make sure the `System.Data.SQLite.dll` in `.\lib\` is the **64-bit** build
   (Server 2022 PowerShell runs 64-bit by default). The setup script handles
   this automatically, but if you copied files from a 32-bit system you may
   need to re-run setup.

4. Launch the GUI as normal:
   ```powershell
   .\BlueCatDnsManager-GUI.ps1 -SkipCertCheck
   ```

### Running the scheduled task on a headless server

If you want to run only the scheduled deployment processor on a server (no GUI
needed):

1. Copy these files to the server:
   ```
   modules\BlueCatApi.psm1
   modules\StagingDb.psm1
   scripts\ScheduledDeploy.ps1
   scripts\Register-ScheduledTask.ps1
   lib\System.Data.SQLite.dll
   lib\SQLite.Interop.dll  (if present)
   data\staging.db          (copy from the machine running the GUI)
   ```

2. Create the credential file on the server:
   ```powershell
   Get-Credential | Export-Clixml .\data\cred.xml
   ```

3. Register the scheduled task:
   ```powershell
   .\scripts\Register-ScheduledTask.ps1 -BamServer bam.corp.local
   ```

> **Note:** The `staging.db` file must be the same database used by the GUI. If
> the GUI and the scheduled processor run on different machines, you will need
> to share or sync this file (e.g. place it on a network share).

---

## Troubleshooting

### "SQLite library not found"

Run `.\scripts\Setup.ps1` to download the dependency. If auto-download fails:

1. Go to https://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki
2. Download **"Precompiled Binaries for .NET Framework 4.6"** (choose the
   64-bit package for 64-bit PowerShell, which is the default on modern Windows)
3. Extract `System.Data.SQLite.dll` and `SQLite.Interop.dll` to the `.\lib\` folder

### "SQLite Architecture Mismatch"

This means the DLL is 32-bit but PowerShell is running 64-bit (or vice versa).

To check your PowerShell architecture:
```powershell
[IntPtr]::Size    # Returns 8 for 64-bit, 4 for 32-bit
```

Download the matching SQLite build from the link above.

### Manual SQLite Install

If NuGet is blocked or your jumpbox has no internet:

1. On a machine with internet access, download from:
   https://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki

2. Get the package labeled:
   **"Precompiled Binaries for .NET Framework 4.6 (x64)"**
   (file will be named something like `sqlite-netFx46-binary-x64-2015-1.0.118.0.zip`)

3. Extract the zip and copy these files to the `.\lib\` folder on your jumpbox:
   - `System.Data.SQLite.dll`
   - `SQLite.Interop.dll`

### TLS / Certificate errors on connect

If your BAM uses a self-signed or internal CA certificate:

- Use `Launch-BlueCatDnsManager-SkipCert.bat`
- Or launch with: `.\BlueCatDnsManager-GUI.ps1 -SkipCertCheck`

### "401 Unauthorized"

- Verify the username and password are correct
- Confirm the account has API access in BAM (Administration > User Management)
- Check that the v2 API is enabled on your BAM (it is by default on 9.5+)

### "Access to the path is denied" when opening staging DB

- Ensure the `.\data\` folder exists and your user has write access
- If the tool was extracted from a zip, right-click the project folder >
  Properties > Security tab, and ensure your user has Modify permissions

### Selective deploy fails

- A full deployment must have been performed at least once on the target DNS
  server before selective deploy can work
- Check that the DNS server has a deployment role configured in BAM

### Window closes immediately on launch

- Open PowerShell manually and run:
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\BlueCatDnsManager-GUI.ps1
  ```
- Check the error message in the console. Common causes:
  - Missing SQLite DLL (run Setup.ps1 first)
  - Execution policy blocking the script (the batch launchers handle this with
    `-ExecutionPolicy Bypass`)

### Setup.ps1 window closes with no output

Run the setup script from an existing PowerShell window instead of
double-clicking it:
```powershell
cd C:\Path\To\BlueCat-DNS-Manager
.\scripts\Setup.ps1
```

This way the window stays open and you can see any error messages.
