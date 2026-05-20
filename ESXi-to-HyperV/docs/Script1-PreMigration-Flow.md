# Script 1: VMware Pre-Migration Data Collection

Entry point: `Collect-VMwareMigrationData.ps1`

## Purpose

Script 1 gathers source-side data before Commvault restores the VM to Hyper-V.
It writes one JSON file per VM and creates or updates the temporary local
migration account inside the guest.

## Input Flow

1. The script prompts for vCenter credentials if `-vCenterCredential` is not
   supplied.
2. VM input can be supplied by:
   - `-VMName server01.domain.com,server02.domain.com`
   - `-VMListPath C:\Path\vmimport.txt`
   - interactive prompt when neither is supplied
3. Each VM import entry is expected to be an FQDN.
4. The short host name before the first dot is used for PowerCLI lookup.
5. The full FQDN is used for guest `Invoke-Command`.

Example:

```powershell
server01.domain.com
```

Becomes:

```text
PowerCLI VM name: server01
Guest remoting target: server01.domain.com
```

## vCenter Collection

The script connects to vCenter with PowerCLI and retrieves:

- VM name
- vCPU count
- memory in MB
- VMware virtual NICs
- port group name
- VLAN ID

The guest NIC data and VMware NIC data are matched by MAC address where
possible.

## Guest Collection

Guest data is collected over PowerShell remoting:

```powershell
Invoke-Command -ComputerName <FQDN>
```

If `-GuestCredential` is supplied, it is passed to `Invoke-Command`. Otherwise,
the current console/admin context is used.

Guest cmdlets used by the remote script block include:

- `Get-NetAdapter`
- `Get-NetIPAddress`
- `Get-NetIPConfiguration`
- `Get-DnsClientServerAddress`
- `Get-DnsClient`

## NIC Classification

Back-side addresses are:

```text
172.25.*.*
169.*.*.*
```

Front-side NIC records are built from NICs that have at least one IPv4 address
outside those ranges.

Back-side NIC records are built from NICs that have at least one IPv4 address in
those ranges.

This means the JSON can keep front-side and back-side interface data separate.

## JSON Shape

The output file is:

```text
<VMName>_MigrationData.json
```

The main NIC sections are:

```json
{
  "FrontInterface": [],
  "BackSideInterface": [],
  "FrontSideNics": [],
  "BackSideNics": []
}
```

`FrontSideNics` remains for Script 2 compatibility.

Each NIC record includes fields such as:

- `InterfaceRole`
- `AdapterName`
- `InterfaceAlias`
- `InterfaceIndex`
- `InterfaceGuid`
- `InterfaceDescription`
- `VirtualAdapterName`
- `MacAddress`
- `IPAddress`
- `IPv4Addresses`
- `PrefixLength`
- `SubnetMask`
- `DefaultGateway`
- `DNSServers`
- `RegisterDnsClient`
- `PortGroupName`
- `PortGroupType`
- `VLANID`
- `VlanDescription`

## Local Migration Account

The account name defaults to:

```text
Hypervmigrate
```

The fixed password is stored as character codes inside the scripts rather than
as a literal plaintext string.

The account is created or updated over PowerShell remoting and added to local
Administrators.

## Logging

Logs are written to:

```text
C:\MigrationLogs\Script1_<timestamp>.log
```

The script also writes a summary table at the end.
