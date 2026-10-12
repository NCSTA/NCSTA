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

## Invoke-TemplatePatching.ps1

For each template listed in the templates CSV:

1. Clones `<name>` to `<name>_patching` and waits for the clone task.
2. Converts the clone to a VM, powers it on and copies this month's patches in.
3. Registers the `LoopingPatch` scheduled task and reboots the guest.
4. Waits for the patch cycle to finish. The guest powers itself off when done.
5. Powers on, shows the latest hotfixes and pauses for operator review.
6. Shuts down, stamps the notes and promotes:
   - `<name>_unpatch` is removed (last month's rollback)
   - `<name>` becomes `<name>_unpatch`
   - `<name>_patching` becomes `<name>`

Each template is tracked independently. A template that fails any step is skipped for the rest of the run and is never promoted, so its production template and rollback copy are left untouched. A summary table is printed at the end, and `$jobs` stays in the session for inspection.

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
