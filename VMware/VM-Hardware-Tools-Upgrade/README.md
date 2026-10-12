# PowerCLI VM Hardware and VMware Tools Utilities

This project contains two paste-ready PowerShell scripts for a VMware vSphere 8.0 / PowerCLI workflow:

- `scripts/Get-WindowsServerVMwareToolsHtmlReport.ScriptPane.ps1`
- `scripts/Stage-VMHardwareVersion21.ScriptPane.ps1`

Both scripts are designed to be pasted into the PowerShell ISE or VS Code PowerShell script pane and run with F5. They do not require `param()` blocks, execution-policy changes, or saved `.ps1` whitelisting.

## Prerequisites

- VMware PowerCLI installed.
- An active vCenter session created with `Connect-VIServer`.
- vCenter permissions to read VM inventory and VMware Tools status.
- For hardware staging, the account needs `VirtualMachine.Config.UpgradeVirtualHardware`.
- A local output folder such as `C:\Temp` or another writable path.

Example connection:

```powershell
Connect-VIServer vcenter01.contoso.com
```

## Script 1: Windows Server VMware Tools HTML Report

File:

```text
scripts/Get-WindowsServerVMwareToolsHtmlReport.ScriptPane.ps1
```

The report script inventories Windows Server VMs only and creates a self-contained dark-mode HTML dashboard with:

- Clickable dashboard cards for total, below minimum, not running, not installed, powered off, and hardware below VM version 21.
- Donut charts for VM hardware version 21 coverage and scheduled hardware upgrade policy `always`; each chart can also filter the table.
- Search box across all visible data.
- Cluster and power-state filters.
- Sortable and drag-resizable table headers.
- A Columns menu with per-column visibility, Show all, and Reset controls.
- A synchronized horizontal scrollbar fixed to the bottom of the browser while the table is visible.
- Interactive inventory breakdown charts grouped by cluster, operating system, or exact VMware Tools version. Selecting a bar filters the table.
- Named saved views containing the current search, filters, grouping, sort order, and column layout when the browser permits local storage.
- A details drawer for each VM, opened by selecting its table row.
- CSV export for either the visible columns or every available field in the current filtered view.
- Full inventory snapshot export to JSON and comparison against an earlier snapshot or enhanced HTML report.
- A print layout for the current filtered rows and visible columns, including browser Print to PDF support.
- Hardware version and scheduled hardware upgrade fields.
- Configurable output path and minimum VMware Tools major version.

The generated report uses HTML5 with embedded custom CSS and vanilla JavaScript. It does not use W3.CSS, Bootstrap, external JavaScript packages, or CDN-hosted assets, so the report remains a portable single file that works offline.

VMware Tools versions are read from vCenter through `Guest.ToolsVersion`; no guest credentials or `Invoke-VMScript` calls are used. The internal value is decoded using VMware's `1024 * major + 32 * minor + patch` format, so internal version `13322` is displayed as `13.0.10 (13322)`. The semantic and raw internal versions are both retained in CSV exports.

Edit these values at the top before running:

```powershell
$OutputPath = "C:\Temp\VMwareTools-WindowsServer-$((Get-Date).ToString('yyyyMMdd-HHmmss')).html"
$MinimumToolsMajorVersion = 13
$OpenReport = $true
```

Run from a script pane:

1. Paste the script into PowerShell ISE or VS Code.
2. Edit the settings at the top.
3. Confirm you are connected to vCenter.
4. Press F5.

### Report Views and Exports

Use **Views** to save the current report layout. A saved view includes:

- Search text, cluster, power state, and selected dashboard status.
- Inventory chart grouping and selected chart value.
- Sort field and direction.
- Visible columns and adjusted column widths.

Saved views are stored by the browser, not in vCenter or in the HTML file. Some browsers restrict local storage for files opened directly from disk; the rest of the report remains available if view persistence is blocked.

Use **Export** for:

- **Visible columns CSV**: current filtered rows with only the columns shown in the table.
- **Full filtered CSV**: current filtered rows with every report field.
- **Inventory snapshot JSON**: the complete unfiltered inventory used as a historical baseline.

Use **Compare** in a newer report and select an earlier snapshot JSON or an earlier enhanced HTML report. The comparison identifies added and removed VMs plus changes to VMware Tools version/state, Tools running status, VM hardware version, scheduled hardware upgrade policy, and scheduled target version.

Use **Print** to print the current filtered report or select a PDF printer in the browser. Hidden columns remain hidden in printed output.

## Script 2: Stage VM Hardware Version 21

File:

```text
scripts/Stage-VMHardwareVersion21.ScriptPane.ps1
```

The staging script uses an editable VM-name array and schedules eligible VMs for VM hardware version 21 (`vmx-21`) on the next qualifying power cycle. It does not reboot any VM.

It skips VMs when:

- VMware Tools is missing or vCenter cannot determine the version.
- VMware Tools numeric version is below the configured minimum, defaulting to 13.0 generation.
- VMware Tools is not running.
- The VM is already at or above the target hardware version.
- The VM is not identified as Windows Server.
- The VM is a template.
- Multiple VMs match the same inventory name.

Edit these values at the top before running:

```powershell
$ApplyChanges = $false
$TargetHardwareVersion = 'vmx-21'
$MinimumToolsMajorVersion = 13
$OutputDirectory = 'C:\Temp\VMHardwareUpgradeResults'
$VerificationTimeoutSeconds = 120

$ServerNames = @(
    'SERVER01',
    'SERVER02',
    'SERVER03'
)
```

Preview mode:

```powershell
$ApplyChanges = $false
```

In preview mode, no vCenter changes are made. Eligible VMs are written to `$PreviewVMs` and CSV output.

Apply mode:

```powershell
$ApplyChanges = $true
```

In apply mode, eligible VMs are reconfigured with:

```powershell
ScheduledHardwareUpgradeInfo.UpgradePolicy = 'always'
ScheduledHardwareUpgradeInfo.VersionKey = 'vmx-21'
```

The script polls the VM configuration and verifies that the scheduled upgrade policy is `always` and the target version is `vmx-21`. Completed vCenter task objects can disappear before `Get-Task` can retrieve them, so a missing task object is treated as diagnostic information rather than a failure. The scheduled VM configuration is the authoritative success check.

## Audit Outputs

The staging script creates timestamped CSV files in the configured output directory when data exists:

- `Preview-*.csv`
- `Scheduled-*.csv`
- `Skipped-All-*.csv`
- `Skipped-OldTools-*.csv`
- `Skipped-MissingTools-*.csv`
- `Skipped-ToolsNotRunning-*.csv`
- `Skipped-Other-*.csv`
- `Failed-*.csv`
- `NotFound-*.csv`
- `Combined-*.csv`

The same result arrays remain available in the PowerShell session after script-pane execution:

```powershell
$PreviewVMs
$ScheduledVMs
$SkippedVMs
$SkippedOldToolsVMs
$SkippedMissingToolsVMs
$SkippedToolsNotRunningVMs
$SkippedOtherVMs
$FailedVMs
$NotFoundVMs
```

## Safety Notes

- Start with `$ApplyChanges = $false` and review the preview and skip CSV files.
- The staging script does not reboot, shut down, or power on any VM.
- The hardware upgrade happens later during a qualifying power cycle, such as the reboot caused by Microsoft monthly patching.
- Upgrade VMware Tools before staging virtual hardware upgrades where possible.
- Confirm cluster, DR, backup, and restore targets support VM hardware version 21.
- Exclude special systems such as vCenter, VMware appliances, backup proxies, appliances, VMs using unsupported recovery workflows, pRDM systems, and any VM class your operations team wants to pilot separately.
- Once a VM reaches `vmx-21`, later reboots do not re-upgrade it. The scheduled policy may still show `always`, but there is no lower hardware version left to upgrade from.

## Typical Workflow

1. Connect to vCenter:

```powershell
Connect-VIServer vcenter01.contoso.com
```

2. Run the VMware Tools report and review old or non-running Tools.
3. Paste the target server names into the staging script.
4. Run the staging script with `$ApplyChanges = $false`.
5. Review `Preview-*.csv` and skip files.
6. Change `$ApplyChanges = $true`.
7. Run the staging script again to schedule eligible VMs for `vmx-21`.
8. Let the normal monthly patching reboot trigger the hardware upgrade.
