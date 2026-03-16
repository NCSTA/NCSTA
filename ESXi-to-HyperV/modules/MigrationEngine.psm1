#Requires -Version 5.1
<#
.SYNOPSIS
    SCVMM V2V conversion engine for ESXi-to-HyperV migrations.
.DESCRIPTION
    Wraps the SCVMM V2V wizard cmdlets into reusable functions.
    Uses the JobGroup pattern from SCVMM to configure NICs before
    triggering the final conversion.

    All SCVMM objects (VM, adapters, networks) are resolved by NAME
    at runtime — no SCVMM IDs required in the CSV input. This allows
    the CSV to be built from VMware/PowerCLI data before the VM
    exists as an SCVMM object.
#>

function Invoke-V2VConversion {
    <#
    .SYNOPSIS
        Performs a V2V conversion of an ESXi VM to Hyper-V via SCVMM.
    .DESCRIPTION
        Replicates the SCVMM V2V wizard flow:
        1. Create a JobGroup GUID for the conversion batch
        2. Resolve all SCVMM objects by name (VM, host, networks, adapters)
        3. Configure each NIC via New-SCV2V (non-trigger calls)
        4. Execute the final New-SCV2V with -Trigger to start conversion
        5. Monitor the SCVMM job until completion
    .PARAMETER VMMServer
        FQDN of the VMM management server.
    .PARAMETER VMName
        Name of the VM to convert.
    .PARAMETER SourceHost
        FQDN of the ESXi host where the VM currently resides.
    .PARAMETER TargetHost
        FQDN of the destination Hyper-V host.
    .PARAMETER StoragePath
        Cluster storage path for the converted VM (e.g., C:\ClusterStorage\Volume5).
    .PARAMETER CPUCount
        Number of virtual CPUs.
    .PARAMETER MemoryMB
        Memory allocation in MB.
    .PARAMETER Generation
        VM generation (1 or 2).
    .PARAMETER DelayedStartSec
        Delayed auto-start in seconds.
    .PARAMETER NICs
        Array of NIC configuration hashtables. Each must contain:
          TargetSwitch  - SCVMM virtual switch name on the target host
          TargetVMNetwork - SCVMM VM network name
          VLAN          - VLAN ID
        Optional:
          SourcePortGroup - VMware port group name (informational, logged but not used by SCVMM)
    .PARAMETER JobTimeoutMinutes
        Maximum time to wait for the SCVMM job. Defaults to 240 (4 hours).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer,

        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$SourceHost,

        [Parameter(Mandatory)]
        [string]$TargetHost,

        [Parameter(Mandatory)]
        [string]$StoragePath,

        [Parameter(Mandatory)]
        [int]$CPUCount,

        [Parameter(Mandatory)]
        [int]$MemoryMB,

        [ValidateSet(1, 2)]
        [int]$Generation = 2,

        [int]$DelayedStartSec = 0,

        [Parameter(Mandatory)]
        [array]$NICs,

        [int]$JobTimeoutMinutes = 240
    )

    if (-not $PSCmdlet.ShouldProcess($VMName, "V2V conversion from $SourceHost to $TargetHost")) {
        return
    }

    # Generate a unique JobGroup ID for this conversion batch
    $jobGroupId = [guid]::NewGuid().ToString()

    # ── Resolve SCVMM objects by name ─────────────────────────────────────────

    # Target Hyper-V host
    $vmHost = Get-SCVMHost -VMMServer $VMMServer |
              Where-Object { $_.Name -eq $TargetHost }
    if (-not $vmHost) { throw "Target host '$TargetHost' not found in SCVMM." }

    # Source VM on ESXi (SCVMM sees VMware VMs once the ESXi host is managed)
    $vm = Get-SCVirtualMachine -VMMServer $VMMServer -Name $VMName |
          Where-Object { $_.VMHost.Name -eq $SourceHost }
    if (-not $vm) {
        throw "Source VM '$VMName' not found on host '$SourceHost' in SCVMM. Ensure the ESXi host is managed by SCVMM."
    }

    # Get all network adapters for the source VM from SCVMM (wrap in array for single-NIC VMs)
    $scAdapters = @(Get-SCVirtualNetworkAdapter -VMMServer $VMMServer -VM $vm)
    if ($scAdapters.Count -eq 0) {
        throw "No network adapters found for VM '$VMName' in SCVMM."
    }

    # ── Configure each NIC via non-trigger New-SCV2V calls (JobGroup pattern) ─

    for ($i = 0; $i -lt $NICs.Count; $i++) {
        $nic = $NICs[$i]

        # Resolve the target virtual switch on the Hyper-V host
        $vNetwork = Get-SCVirtualNetwork -VMMServer $VMMServer -Name $nic.TargetSwitch |
                    Where-Object { $_.VMHostID -eq $vmHost.ID }
        if (-not $vNetwork) {
            throw "Virtual switch '$($nic.TargetSwitch)' not found on target host '$TargetHost'."
        }

        # Match the source adapter by index (adapter order from SCVMM inventory)
        if ($i -ge $scAdapters.Count) {
            throw "NIC index $($i + 1) specified but VM only has $($scAdapters.Count) adapter(s) in SCVMM."
        }
        $vAdapter = $scAdapters[$i]

        # Resolve the target VM network by name
        $vmNetwork = Get-SCVMNetwork -VMMServer $VMMServer -Name $nic.TargetVMNetwork
        if (-not $vmNetwork) {
            throw "VM network '$($nic.TargetVMNetwork)' not found in SCVMM."
        }
        # If multiple VM networks share a name, pick the first match
        if ($vmNetwork.Count -gt 1) {
            $vmNetwork = $vmNetwork | Select-Object -First 1
            Write-Warning "Multiple VM networks named '$($nic.TargetVMNetwork)' found. Using first match (ID: $($vmNetwork.ID))."
        }

        $srcInfo = if ($nic.SourcePortGroup) { " (VMware: $($nic.SourcePortGroup))" } else { '' }
        Write-Host "  NIC $($i + 1): VLAN $($nic.VLAN) -> $($nic.TargetSwitch) / $($nic.TargetVMNetwork)$srcInfo" -ForegroundColor Gray

        New-SCV2V -VMMServer $VMMServer `
                  -VMHost $vmHost `
                  -RunAsynchronously `
                  -JobGroup $jobGroupId `
                  -VM $vm `
                  -VirtualNetwork $vNetwork `
                  -VirtualNetworkAdapter $vAdapter `
                  -VMNetwork $vmNetwork `
                  -VLanEnabled $true `
                  -VLanId $nic.VLAN
    }

    # ── Final trigger call - starts the actual V2V conversion ─────────────────

    $v2vJob = New-SCV2V -VM $vm `
                        -VMHost $vmHost `
                        -Path $StoragePath `
                        -Name $VMName `
                        -Description '' `
                        -RunAsynchronously `
                        -JobGroup $jobGroupId `
                        -Trigger `
                        -Generation $Generation `
                        -CPUCount $CPUCount `
                        -MemoryMB $MemoryMB `
                        -DelayStartSeconds $DelayedStartSec

    # Monitor the SCVMM job until completion or timeout
    # New-SCV2V with -RunAsynchronously returns the job object directly
    $jobResult = Wait-SCVMMJob -VMMServer $VMMServer -Job $v2vJob -JobTimeout $JobTimeoutMinutes

    return $jobResult
}

function Wait-SCVMMJob {
    <#
    .SYNOPSIS
        Monitors an SCVMM job until completion or timeout.
    .PARAMETER VMMServer
        FQDN of the VMM server.
    .PARAMETER Job
        The SCVMM job object returned by the async cmdlet (e.g., New-SCV2V).
    .PARAMETER JobTimeout
        Timeout in minutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer,

        [Parameter(Mandatory)]
        $Job,

        [int]$JobTimeout = 240
    )

    $deadline = (Get-Date).AddMinutes($JobTimeout)
    $pollInterval = 30  # seconds

    if (-not $Job) {
        return [PSCustomObject]@{
            Success      = $true
            Status       = 'Completed'
            ErrorMessage = $null
        }
    }

    # Store the job ID as a single Guid to avoid array conversion errors
    [Guid]$jobId = $Job.ID

    while ($Job.Status -eq 'Running') {
        if ((Get-Date) -gt $deadline) {
            return [PSCustomObject]@{
                Success      = $false
                Status       = 'Timeout'
                ErrorMessage = "SCVMM job timed out after $JobTimeout minutes."
            }
        }

        $progress = if ($Job.Progress) { $Job.Progress } else { 0 }
        Write-Host "  V2V job progress: $progress% ..." -ForegroundColor Gray
        Start-Sleep -Seconds $pollInterval

        # Refresh job status using the stored Guid
        $Job = Get-SCJob -VMMServer $VMMServer -ID $jobId
    }

    if ($Job.Status -eq 'Completed') {
        [PSCustomObject]@{
            Success      = $true
            Status       = 'Completed'
            ErrorMessage = $null
        }
    }
    else {
        [PSCustomObject]@{
            Success      = $false
            Status       = $Job.Status
            ErrorMessage = "SCVMM job ended with status: $($Job.Status). $($Job.ErrorInfo)"
        }
    }
}

Export-ModuleMember -Function Invoke-V2VConversion, Wait-SCVMMJob
