# Template Patching

PowerCLI scripts for the monthly patch cycle of VMware templates, and for finding template folders left behind on datastores.

| Script | Purpose |
|---|---|
| `Invoke-TemplatePatching.ps1` | Clones, patches and promotes each template, keeping last month's copy as a rollback |
| `Find-OrphanedTemplates.ps1` | Read-only scan for VM and template folders that are no longer registered in inventory |

## Requirements

- Windows PowerShell 5.1
- VMware PowerCLI (`VMware.VimAutomation.Core`)
- vCenter rights to clone, convert, rename and remove templates (patching), or read-only datastore browse rights (orphan scan)

Both scripts are written to be pasted into an unsaved PowerShell ISE script pane. Edit the CONFIGURATION block at the top and press F5.

Settings in the CONFIGURATION block are written `Name = value`, without a `$` in front of the name. A line such as `$VCenters = @(...)` inside the block fails with "A null key is not allowed in a hash literal", and the script stops before connecting to anything.

## Invoke-TemplatePatching.ps1

For each template listed in the templates CSV:

1. Clones `<name>` to `<name>_patching` and waits for the clone task.
2. Converts the clone to a VM, powers it on, records an Appx baseline, and copies this month's patches and the guest patch-cycle script in.
3. Registers the patch-cycle scheduled task and reboots the guest.
4. Waits for the patch cycle to finish. The guest always powers itself off when done.
5. Powers on, checks the patch-cycle status, shows the latest hotfixes, runs the Appx sysprep check and pauses for operator review.
6. Seals the guest (SCCM client cleanup) and shuts it down, stamps the notes and promotes:
   - `<name>_unpatch` is removed (last month's rollback)
   - `<name>` becomes `<name>_unpatch`
   - `<name>_patching` becomes `<name>`

Each template is tracked independently. A template that fails any step is skipped for the rest of the run and is never promoted, so its production template and rollback copy are left untouched. A summary table is printed at the end, and `$jobs` stays in the session for inspection.

### Guest patch cycle

The script that runs inside the guest is embedded in `Invoke-TemplatePatching.ps1` and copied into each VM on every run, so nothing has to be kept on the templates. It replaces the old `LoopingPatch.ps1`, `logoff.ps1` and `TriggerLoopingPatch.ps1`.

It runs at each boot as SYSTEM from the `TemplatePatchCycle` scheduled task and:

- Installs only `.cab` and `.msu` files from `C:\temp\Patches`, smallest first, and restarts only when a package needs it.
- Skips packages that are not applicable (superseded or for another OS).
- Stops retrying a package after `GuestPatchMaxAttempts` failures and moves it to a `Failed` folder, so a bad package cannot cause a reboot loop.
- Writes its progress to `C:\temp\PatchCycle\status.json` and `patchcycle.log`.
- Always ends with a forced shutdown, whether it succeeded or failed.

When the VM is powered on for validation, the orchestrator reads the status file. If a package failed, or the cycle did not finish, the template fails and the log shows the reason and the end of `patchcycle.log`.

### Seal

The SCCM client cleanup runs as the very last thing before the final shutdown: stop `CcmExec`, remove `SMSCFG.INI`, and remove the SMS certificates. The VM is not booted again after that. A cleared client that starts up again creates a new client identity, which would then be baked into the template. If any part of the cleanup cannot be confirmed, the VM is left running and the template is not promoted.

### Retiring the old template scripts

The old scripts on the templates (`logoff.ps1`, `LoopingPatch.ps1` and `TriggerLoopingPatch.ps1` on the Administrator desktop) are no longer used. They are left in place until the new patch cycle has completed a successful run. After that, set `RemoveLegacyGuestScripts = $true`, and the seal step deletes them from each template on the next run. The paths are listed in `LegacyGuestScripts`.

### Appx sysprep check

Sysprep, run by the VMware customization spec when a VM is deployed from the template, fails when an Appx package is installed for a user but not provisioned for all users. It also fails when a user's copy is newer than the provisioned version. Patching can cause this, for example when an Edge update registers a package for Administrator.

- **Before patching**, the script records the installed and provisioned packages. Templates that already have a blocking package are flagged in the log.
- **After patching**, it logs which packages were added or removed, then looks for blocking packages. Framework, resource and system packages are ignored, as are packages installed for all users through provisioning.
- Each blocking package is removed with `Remove-AppxPackage -AllUsers`, and the check runs again. Set `AppxAutoRemove = $false` to only report.
- Anything still present fails the template: it is not promoted and its `_patching` VM is left powered on. The packages, users and removal errors are printed and written to `appx_manual_intervention_<timestamp>.csv` in the log directory.

The guest account must be able to run elevated without a UAC prompt. The built-in Administrator account can; other local admin accounts get a filtered token and the check fails with "requires elevation".

### Resuming a run

Progress is saved after every step to `template_patching_state.json` in the log directory. To continue after a failure, for example once you have removed an Appx package by hand, or after the ISE was closed mid-run:

1. Fix the cause. Leave the `_patching` VM in place.
2. Set `Resume = $true` in the configuration and run the script again.

Each unfinished template continues at the step it failed or stopped on. Completed steps are skipped and finished templates are left alone. The template list comes from the state file, not the CSV. Set `ResumeTemplates = @('2022_Std_Core')` to resume only some templates; the others stay as they are and can be resumed later.

On resume the script also:

- Powers the `_patching` VM back on if the next step runs inside the guest.
- Starts a template over from the clone if its `_patching` VM or template no longer exists, for example because you deleted it to start again.
- Finishes a partly done promotion. If production was already renamed to `_unpatch`, that copy is kept as the rollback and is not deleted.

A new run (`Resume = $false`) renames the old state file to `template_patching_state_replaced_<timestamp>.json` before starting. It refuses to touch any template that still has a `_patching` VM or template, so an unfinished run cannot be overwritten by accident.

### Templates CSV

| Column | Required | Purpose |
|---|---|---|
| `templateName` | Yes | Must start with the OS year, for example `2022_Std_Core` |
| `DataStoreCluster` | Yes | Datastore cluster to place the clone on |
| `vCenter` | No | Pins the template to one vCenter when the same name exists on several |

### Configuration

Set the vCenter list, credential file paths, file share paths and the per-OS-year test servers whose `ccmcache` holds that month's patches. Credentials are stored with `Export-Clixml`, so they only decrypt for the same user on the same machine.

## Find-OrphanedTemplates.ps1

Nothing is deleted or modified.

1. Connects to every vCenter in the configuration.
2. Collects the folders used by every registered VM and template. Datastores shared between vCenters are matched by datastore URL.
3. Browses each datastore once and flags any folder holding a `.vmtx` or `.vmx` file that nothing registered uses.
4. Reports each orphan's name, datastore and date deleted. The date comes from the matching vCenter removal event when it is still within event retention; otherwise the config file's last-modified time is used and marked with `*`.

A table is printed and a CSV with path, size, vCenter and date source is written to the Documents folder. `$orphans` stays in the session for further filtering.

Expect false positives for VMs registered on hosts or vCenters not in the list, and for anything else that keeps `.vmx` files outside inventory, such as replication targets. Check each folder before deleting it.
