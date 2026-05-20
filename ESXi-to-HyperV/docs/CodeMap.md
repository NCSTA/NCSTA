# Code Map

This map lists the main script areas and the functions most likely to matter
when debugging or extending the toolkit.

## Collect-VMwareMigrationData.ps1

### Input and Logging

- `Resolve-VMImportEntry`
  - Reads VM FQDN input from `-VMName`, `-VMListPath`, or a prompt.
  - Splits FQDN into short vCenter VM name and guest FQDN.
- `Initialize-Log`
- `Write-Log`

### Guest Remoting and JSON Parsing

- `Invoke-GuestPowerShellRemoting`
  - Runs guest script blocks through `Invoke-Command -ComputerName`.
- `Get-GuestNetworkDiscoveryScript`
  - Builds the remote guest script text.
- `Get-GuestNetworkInfo`
  - Runs guest discovery and parses the returned JSON.
- `ConvertFrom-GuestJson`
- `Expand-ObjectArray`
  - Flattens nested arrays from PowerShell JSON/remoting behavior.

### Address and NIC Classification

- `Test-BackSideIPv4Address`
  - Identifies `172.25.*.*` and `169.*.*.*`.
- `Get-FirstNonBackSideIPv4Entry`
- `Get-FirstBackSideIPv4Entry`
- `Test-GuestNicIsFrontSide`
- `Test-GuestNicIsBackSide`

### VMware NIC Mapping

- `Resolve-GuestNetworkAdapterMatch`
  - Matches guest NIC data to VMware NICs by MAC first.
- `Get-PortGroupVlanId`
  - Resolves port group name/type and VLAN ID.
- `Get-PortGroupVlanSpecText`

### JSON NIC Records

- `ConvertTo-NicRecord`
- `ConvertTo-FrontSideNicRecord`
- `ConvertTo-BackSideNicRecord`
- `Get-FrontSideNicRecord`
- `Get-BackSideNicRecord`

### Local Migration Account

- `Get-MigrationPasswordCodeLiteral`
- `Get-MigrationLocalAccountScriptText`
- `Invoke-MigrationLocalAccountSetup`

### Output

- `Write-MigrationDataFile`

## Configure-HyperVMigrationNic.ps1

### Input and JSON Loading

- `Resolve-VMNameList`
- `Get-MigrationData`

### SCVMM

- `Get-SCVirtualMachineStrict`
- `Get-SCVmHostName`
- `Get-SCVirtualNetworkAdaptersForVM`
- `Get-SCVirtualAdapterNetworkName`
- `Find-SCVirtualAdapterForNic`
- `Confirm-SCVirtualAdapterNetwork`
- `Invoke-SCVirtualAdapterVlanUpdate`

### Hyper-V Host

- `Invoke-OnHyperVHost`
- `Get-HyperVNetworkAdapter`
- `Find-HyperVAdapterForNic`
- `Invoke-HyperVAdapterSwitchConnection`
- `Invoke-HyperVAdapterVlanUpdate`

### PowerShell Direct Guest Configuration

- `Get-GuestNicConfigurationScriptText`
- `Invoke-GuestNicConfiguration`

Important embedded guest functions:

- `Find-TargetAdapter`
- `Clear-IPv4Configuration`
- `Set-TargetAdapterName`

## Common Search Commands

```powershell
rg -n "FrontInterface|BackSideInterface|FrontSideNics" .
rg -n "Invoke-Command|Invoke-VMScript|PowerShell Direct" .
rg -n "VLANID|PortGroupName|Set-SCVirtualNetworkAdapter" .
rg -n "Get-NetIPAddress|Get-NetIPConfiguration|Get-DnsClient" .
```
