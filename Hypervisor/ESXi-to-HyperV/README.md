# ESXi to Hyper-V Migration Toolkit

Two scripts that carry a Windows VM's network identity across an ESXi to Hyper-V migration. The first records the configuration while the VM is still on VMware; the second reapplies it after the VM has been restored on Hyper-V.

| Script | When | Purpose |
|---|---|---|
| `Collect-VMwareMigrationData.ps1` | Before migration | Collects CPU, memory and production NIC settings from vCenter and the guest, and writes one JSON file per VM |
| `Configure-HyperVMigrationNic.ps1` | After migration | Reads that JSON, configures the VM's network adapter in SCVMM, then sets the static IP, gateway and DNS inside the guest |

## Requirements

- Windows PowerShell 5.1
- VMware PowerCLI (collection)
- `VirtualMachineManager` module on the management server (configuration)
- Hyper-V module and PowerShell Direct on each Hyper-V host (configuration)
- PowerShell remoting to the Windows guests (collection)

## Usage

Collect before the migration:

```powershell
.\Collect-VMwareMigrationData.ps1 -VMListPath .\vms.txt -vCenterServer vcenter.domain.com
```

Configure after the VMs are restored on Hyper-V:

```powershell
.\Configure-HyperVMigrationNic.ps1 -VMListPath .\vms.txt -VMMServer scvmm01.domain.com
```

Both scripts accept `-VMName` for individual VMs instead of a list file. The list holds one FQDN per line; the short name before the first dot is used for vCenter and SCVMM lookups.

### Key parameters

| Parameter | Script | Default | Purpose |
|---|---|---|---|
| `-OutputDirectory` / `-DataDirectory` | Collect / Configure | `C:\MigrationData` | Where the per-VM JSON is written and read |
| `-LogDirectory` | Both | `C:\MigrationLogs` | Log location |
| `-MigrationAccountUserName` | Both | `Hypervmigrate` | Temporary local account created in the guest and used after migration |
| `-SkipMigrationAccountCreation` | Collect | off | Collect data without creating the local account |
| `-ProductionSwitchName` | Configure | `Production Switch` | Hyper-V virtual switch for the production NIC |
| `-GuestBootWaitSeconds` | Configure | `120` | Wait for the guest to boot before configuring it |

## Notes

- Back-side management NICs are excluded. An adapter is treated as back-side when any of its IPv4 addresses matches `172.25.*.*` or `169.*.*.*`. Change the pattern in both scripts if your management range differs.
- Guest configuration after migration uses PowerShell Direct from the Hyper-V host, so it works before the guest has network connectivity.

## Documentation

See [docs](docs/README.md) for the detailed pre-migration and post-migration flows and a code map.
