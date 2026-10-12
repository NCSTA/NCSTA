# SCVMM V2V with High Availability

Converts a single VMware VM to Hyper-V through SCVMM V2V, then makes the converted VM highly available on the destination cluster.

## Requirements

- Windows PowerShell 5.1
- `VirtualMachineManager` module, run from a machine that can reach the VMM server
- PowerShell remoting to the source guest (for VMware Tools removal)
- The source ESXi host and destination Hyper-V host both managed by SCVMM

## Configuration

All settings are in the `$Config` and `$NetworkMappings` blocks at the top of the script. The values in the repository are placeholders.

| Setting | Purpose |
|---|---|
| `VmmServerName` | SCVMM server |
| `SourceVmName`, `SourceVmId`, `SourceVmHostName` | Identify the VMware VM in SCVMM |
| `DestinationVmHostName`, `DestinationPath`, `DestinationVmName` | Hyper-V host, storage path and name for the converted VM |
| `Generation`, `CPUCount`, `MemoryMB`, `DelayStartSeconds` | Hardware profile of the converted VM |
| `HAVMPriority` | Cluster priority applied when HA is enabled |
| `GuestComputerName`, `GuestCredential` | Guest to remove VMware Tools from |
| `RestartGuestAfterToolsRemove`, `RestartTimeoutMinutes` | Whether to reboot the guest after removal, and how long to wait |
| `LogRoot` | Folder for the log and transcript |

Each entry in `$NetworkMappings` maps one source adapter to a Hyper-V virtual switch, VM network and VLAN. The IDs can be read from SCVMM with `Get-SCVirtualNetwork`, `Get-SCVirtualNetworkAdapter` and `Get-SCVMNetwork`.

## Usage

```powershell
.\Invoke-SCVmmV2VHighAvailability.ps1
```

## What it does

1. Connects to the guest and uninstalls VMware Tools. The run stops if this step fails.
2. Connects to SCVMM and resolves the destination host and source VM. Each lookup must return exactly one result.
3. Queues a network mapping for every adapter under one VMM job group.
4. Submits the V2V conversion and polls the VMM job until it completes or fails.
5. Enables high availability on the converted VM with the configured priority.

## Output

A log and a transcript per run under `LogRoot`, named after the destination VM and a timestamp.
