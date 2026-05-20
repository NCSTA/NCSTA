# Script 2: Post-Migration Hyper-V NIC Configuration

Entry point: `Configure-HyperVMigrationNic.ps1`

## Purpose

Script 2 runs after Commvault restores the VM to Hyper-V. It reads the JSON from
Script 1, configures the restored VM virtual NIC at the host/SCVMM layer, and
then configures the Windows guest NIC through PowerShell Direct.

## Input Flow

VMs can be supplied by:

- `-VMName VM01,VM02`
- `-VMListPath C:\Path\vms.txt`

For each VM, the script loads:

```text
<VMName>_MigrationData.json
```

from `-DataDirectory`.

## SCVMM and Hyper-V Flow

1. Connect to SCVMM with `Get-SCVMMServer`.
2. Locate the restored VM by name with `Get-SCVirtualMachine`.
3. Determine the Hyper-V host from the SCVMM VM object.
4. Read SCVMM virtual adapters.
5. Read Hyper-V VM network adapters from the host.
6. Match the target production NIC by MAC, adapter name, or network/port group
   where possible.
7. Confirm or update VM network/port group by name.
8. Set VLAN through SCVMM.
9. Fall back to Hyper-V VLAN cmdlets only when needed and not disabled.

## Guest Configuration Flow

Guest NIC configuration is pushed from the Hyper-V host using PowerShell Direct:

```powershell
Invoke-Command -VMName <VMName> -Credential .\Hypervmigrate
```

Inside the guest, the script:

1. Loads front-side NIC records from JSON.
2. Finds target guest adapters.
3. Clears stale IPv4 addresses and default routes.
4. Disables DHCP for IPv4.
5. Assigns static IP, prefix length, and default gateway.
6. Sets DNS servers.
7. Sets DNS registration behavior.
8. Renames the adapter when an original adapter name is available and safe.

## JSON Fields Used

Script 2 currently consumes `FrontSideNics` for compatibility. Script 1 also
writes `FrontInterface`, which has the same front-side NIC records in a clearer
section.

Important fields:

- `IPAddress`
- `PrefixLength`
- `SubnetMask`
- `DefaultGateway`
- `DNSServers`
- `RegisterDnsClient`
- `MacAddress`
- `AdapterName`
- `InterfaceAlias`
- `PortGroupName`
- `VLANID`

## Logging

Logs are written to:

```text
C:\MigrationLogs\Script2_<timestamp>.log
```

The script writes a final table with:

```text
VMName | VLANSet | IPConfigured | Status
```
