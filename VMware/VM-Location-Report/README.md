# VM Location Report

Generates an HTML report showing where Windows Server VMs run across every cluster and host in one or more vCenters, alongside each host's CPU socket and core counts.

It is useful for Windows Server licensing reviews, where the physical cores of every host that runs a Windows Server VM need to be known.

The script only performs read-only PowerCLI inventory queries. It does not modify vCenter, clusters, hosts or VMs.

## Requirements

- Windows PowerShell 5.1
- VMware PowerCLI
- Read-only access to each vCenter

## Usage

Set the values at the top of `Export-WindowsServerVMLocationReport.ps1`:

```powershell
$outputDir = "C:\Temp"
$vCenters  = @(
    "your_vcenter_server"
)
```

Then run the script. If saved scripts are blocked by execution policy, paste the whole file into a PowerShell ISE script pane and press F5.

## Output

`Windows_Server_VM_Location_Report_<timestamp>.html` in the output folder, containing:

- A host summary table: vCenter, cluster, hostname, CPU sockets, cores per socket, total cores and Windows VM count
- A section per cluster and host listing each Windows Server VM with its power state, vCPU, memory and detected OS

Templates are excluded. A VM counts as Windows Server when its guest ID or guest OS name identifies it as one.

## Testing without vCenter

`Test-WindowsServerVMLocationReportSample.ps1` mocks the PowerCLI inventory commands with sample data and runs the report script, so the HTML can be checked without connecting to vCenter. Its output goes to a `SampleReports` folder, which is ignored by git.

```powershell
.\Test-WindowsServerVMLocationReportSample.ps1
```
