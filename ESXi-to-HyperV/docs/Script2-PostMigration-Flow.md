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
4. On the Hyper-V host, attempt to enable Secure Boot.
5. On the Hyper-V host, enable the Guest Service Interface integration service.
6. Power on the VM if it is not already running.
7. Read SCVMM virtual adapters.
8. Read Hyper-V VM network adapters from the host.
9. Match the target production NIC by MAC, adapter name, or network/port group
   where possible.
10. Confirm or update VM network by normalized network key.
11. Set VLAN through SCVMM.
12. Fall back to Hyper-V VLAN cmdlets only when needed and not disabled.

## VM Network Matching

VMware and SCVMM network names can use different suffixes:

```text
VMware: 10.1.1.x dvswitch
SCVMM:  10.1.1.x Network
```

Script 1 stores `NetworkMatchKey`, such as `10.1.1.x`. Script 2 uses that key
to match and select the SCVMM VM network.

If the JSON does not contain `NetworkMatchKey`, Script 2 derives it from
`PortGroupName`.

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
- `NetworkMatchKey`
- `VLANID`

## Boot Wait

After SCVMM/Hyper-V-side NIC work, the script waits before running PowerShell
Direct guest configuration. The default is:

```powershell
-GuestBootWaitSeconds 120
```

Set it to `0` to skip the wait.

## Logging

Logs are written to:

```text
C:\MigrationLogs\Script2_<timestamp>.log
```

The script writes a final table with:

```text
VMName | VLANSet | IPConfigured | Status
```
