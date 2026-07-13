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

The report script inventories Windows Server VMs only and creates a self-contained HTML dashboard with:

- Clickable dashboard cards for total, current, outdated, below minimum, not running, not installed, powered off, and hardware below VM version 21.
- Search box across all visible data.
- Cluster and power-state filters.
- Sortable table headers.
- CSV export of the current filtered view.
- Hardware version and scheduled hardware upgrade fields.
- Configurable output path and minimum VMware Tools major version.

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

The script waits for the reconfiguration task, refreshes the VM view, and verifies that the scheduled upgrade policy and target version were actually set.

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
