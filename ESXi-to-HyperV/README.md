# ESXi-to-HyperV Migration Tool

CSV-driven batch migration tool for converting ESXi VMs to Hyper-V via SCVMM V2V, with post-conversion Guest Services enablement and high availability clustering.

## Environment

| Component | Details |
|---|---|
| SCVMM | Server 2025 |
| Hyper-V | Server 2025 Core |
| Management Point | Has PowerCLI, Hyper-V, VirtualMachineManager, and FailoverClusters modules installed |

## Project Structure

```
ESXi-to-HyperV/
├── Convert-EsxiToHyperV.ps1          # Main migration orchestrator (CSV input)
├── Export-MigrationCsv.ps1            # Pulls VM data from VMware via PowerCLI
├── README.md
├── configs/
│   └── sample-migration.csv           # Example CSV with pre-filled data
├── modules/
│   ├── MigrationLogger.psm1           # Structured logging with transcript
│   ├── PreFlightValidator.psm1        # Pre-conversion validation checks
│   ├── MigrationEngine.psm1           # SCVMM V2V conversion logic
│   └── PostConversionConfig.psm1      # Guest Services + HA clustering
└── logs/                              # Runtime log output
```

## Handling Module Conflicts (PowerCLI vs Hyper-V)

PowerCLI and Hyper-V modules share cmdlet names (e.g., `Get-VM`, `Get-VMNetworkAdapter`). This project uses **module-qualified calls** to avoid ambiguity:

```powershell
# PowerCLI
VMware.VimAutomation.Core\Get-VM -Name $vmName
VMware.VimAutomation.Core\Get-NetworkAdapter -VM $vm

# Hyper-V
Hyper-V\Get-VM -VMName $vmName
Hyper-V\Enable-VMIntegrationService -VMName $vmName -Name 'Guest Service Interface'

# SCVMM (no conflict — all cmdlets are prefixed with SC)
Get-SCVirtualMachine -Name $vmName
Get-SCVMHost -VMMServer $server
New-SCV2V -VM $vm -VMHost $host
```

This approach requires no `Import-Module` gymnastics and makes every call self-documenting about which hypervisor it targets.

## Workflow

### Step 1: Export VM Data from VMware

Pull VM configuration from vCenter/ESXi using PowerCLI:

```powershell
C:\Scripts\ESXi-to-HyperV\Export-MigrationCsv.ps1 -VIServer vcenter.domain.local `
    -VMName "sample-vm01" `
    -TargetHost "hyperv-host01.domain.local" `
    -StoragePath "C:\ClusterStorage\Volume1"
```

This connects to VMware and exports each VM's CPU, memory, NIC port groups, and VLAN IDs into the CSV format. The output CSV defaults to `configs\migration-export.csv` relative to the script directory.

All paths are resolved to absolute internally - relative paths are supported but full paths are recommended.

#### Using a Network Map

To auto-populate the SCVMM target columns (TargetSwitch, TargetVMNetwork), provide a `-NetworkMap`:

```powershell
$netMap = @{
    'VLAN_100_Production' = @{ Switch = 'Production Switch'; VMNetwork = '10.0.1.x Network' }
    'VLAN_200_Management'        = @{ Switch = 'Management Switch';        VMNetwork = '10.0.2.x Network' }
}

C:\Scripts\ESXi-to-HyperV\Export-MigrationCsv.ps1 -VIServer vcenter.domain.local `
    -VMName "sample-vm*" `
    -TargetHost "hyperv-host01.domain.local" `
    -StoragePath "C:\ClusterStorage\Volume1" `
    -NetworkMap $netMap
```

Without `-NetworkMap`, the TargetSwitch and TargetVMNetwork columns are left blank for manual entry.

#### Exporting Multiple VMs

```powershell
# Wildcard
C:\Scripts\ESXi-to-HyperV\Export-MigrationCsv.ps1 -VIServer vcenter.domain.local `
    -VMName "sample-vm*" `
    -TargetHost "hyperv-host01.domain.local" `
    -StoragePath "C:\ClusterStorage\Volume1"

# Specific list
C:\Scripts\ESXi-to-HyperV\Export-MigrationCsv.ps1 -VIServer vcenter.domain.local `
    -VMName "server01v","server02v","server03v" `
    -TargetHost "hyperv-host01.domain.local" `
    -StoragePath "C:\ClusterStorage\Volume1"

# Append to existing CSV (e.g., different target hosts)
C:\Scripts\ESXi-to-HyperV\Export-MigrationCsv.ps1 -VIServer vcenter.domain.local `
    -VMName "server04v" `
    -TargetHost "hyperv-host02.domain.local" `
    -StoragePath "C:\ClusterStorage\Volume1" -Append
```

#### Export Parameters

| Parameter | Required | Description |
|---|---|---|
| `-VIServer` | Yes | vCenter or ESXi host FQDN |
| `-VMName` | Yes | VM name(s), supports wildcards |
| `-TargetHost` | Yes | Destination Hyper-V host FQDN |
| `-StoragePath` | Yes | Cluster storage path on target (e.g., `C:\ClusterStorage\Volume1`) |
| `-Credential` | No | PSCredential for vCenter auth (prompts if omitted) |
| `-Generation` | No | VM generation (default: 2) |
| `-DelayedStartSec` | No | Auto-start delay in seconds (default: 120) |
| `-NetworkMap` | No | Hashtable mapping VMware port groups to SCVMM networks |
| `-OutputPath` | No | Output CSV full path (default: `<script-dir>\configs\migration-export.csv`) |
| `-Append` | No | Append to existing CSV |

### Step 2: Review the CSV

Open the exported CSV and verify:

- **TargetSwitch** and **TargetVMNetwork** columns are filled in (required for conversion)
- CPU, memory, and generation values are correct for the target environment
- Storage path has sufficient space

#### CSV Columns

| Column | Source | Description |
|---|---|---|
| `VMName` | PowerCLI | VM name |
| `SourceHost` | PowerCLI | ESXi host FQDN |
| `TargetHost` | Parameter | Hyper-V host FQDN |
| `StoragePath` | Parameter | Cluster storage path |
| `CPUCount` | PowerCLI | Number of vCPUs |
| `MemoryMB` | PowerCLI | Memory in MB |
| `Generation` | Parameter | VM generation (1 or 2) |
| `DelayedStartSec` | Parameter | Auto-start delay |
| `NICx_SourcePortGroup` | PowerCLI | VMware port group name |
| `NICx_VLAN` | PowerCLI | VLAN ID |
| `NICx_TargetSwitch` | NetworkMap/Manual | SCVMM virtual switch name |
| `NICx_TargetVMNetwork` | NetworkMap/Manual | SCVMM VM network name |

Up to 4 NICs per VM (NIC1 through NIC4). Empty NIC columns are skipped.

### Step 3: Run the Migration

```powershell
# Dry run - validates CSV, modules, connectivity, and resources without converting
C:\Scripts\ESXi-to-HyperV\Convert-EsxiToHyperV.ps1 `
    -CsvPath "C:\Scripts\ESXi-to-HyperV\configs\migration-export.csv" `
    -VMMServer vmm-server.domain.local -WhatIf

# Execute the migration
C:\Scripts\ESXi-to-HyperV\Convert-EsxiToHyperV.ps1 `
    -CsvPath "C:\Scripts\ESXi-to-HyperV\configs\migration-export.csv" `
    -VMMServer vmm-server.domain.local
```

#### Conversion Parameters

| Parameter | Required | Description |
|---|---|---|
| `-CsvPath` | Yes | Full path to the migration CSV |
| `-VMMServer` | Yes | SCVMM management server FQDN |
| `-WhatIf` | No | Dry run (pre-flight only, no conversion) |

## What the Migration Does

For each VM in the CSV, the script executes these phases:

### Phase 1: Pre-Flight Validation
- Verifies required PowerShell modules are installed
- Tests SCVMM server connectivity
- Validates the target Hyper-V host is managed and responding
- Confirms the source VM exists on the ESXi host (via SCVMM)
- Validates storage path exists on the target
- Confirms virtual switches and VM networks exist in SCVMM

### Phase 2: V2V Conversion
- Resolves all SCVMM objects by name at runtime (no hardcoded IDs)
- Configures each NIC with its target virtual switch, VM network, and VLAN using the SCVMM JobGroup pattern
- Triggers the V2V conversion via `New-SCV2V`
- SCVMM handles power state management during conversion
- Monitors the SCVMM job with progress updates (polls every 30s, 4-hour timeout)

### Phase 3: Post-Conversion
- **Guest Services**: Enables the Guest Service Interface integration service via `Hyper-V\Enable-VMIntegrationService`
- **High Availability**: Registers the VM as a clustered resource via `Add-ClusterVirtualMachineRole` — since storage is already on CSV (Cluster Shared Volume), no additional migration is needed

### Phase 4: Verification
- Confirms Guest Services are enabled
- Confirms the VM is registered as a cluster resource
- Validates NIC count and VLAN/switch assignments match the CSV

## Error Handling

- **Batch resilience**: If one VM fails, the script logs the error and continues to the next VM
- **Phase tracking**: Failures are tagged with the phase where they occurred (PreFlight, V2V-Conversion, PostConversion-GuestServices, PostConversion-HA)
- **Summary table**: At completion, displays a pass/fail summary for all VMs with duration and error details

## Logging

All operations are logged to `logs/` with both a transcript and structured CSV:

```
logs/
├── Migration-20260316-140000.log            # Full transcript
└── Migration-20260316-140000-entries.csv     # Structured log entries
```

Log entries include timestamps, severity levels (Info/Warning/Error/Success), and VM names.

## Prerequisites

### Required Modules on Management Point

| Module | Purpose |
|---|---|
| `VMware.PowerCLI` | Export VM data from vCenter/ESXi |
| `VirtualMachineManager` | SCVMM V2V conversion |
| `Hyper-V` | Post-conversion Guest Services |
| `FailoverClusters` | High availability clustering |

### Infrastructure Requirements

- ESXi hosts must be managed by SCVMM (added as VMware hosts) before running the conversion
- Target Hyper-V hosts must be managed by SCVMM and in a responding state
- Target storage path must exist (Cluster Shared Volume)
- Virtual switches and VM networks must be configured in SCVMM
- WinRM must be enabled on Hyper-V hosts for remote commands
