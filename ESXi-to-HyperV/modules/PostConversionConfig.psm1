#Requires -Version 5.1
<#
.SYNOPSIS
    Post-conversion configuration for migrated VMs.
.DESCRIPTION
    Enables Guest Services integration and configures high availability
    (failover clustering) for VMs after V2V conversion. Uses module-qualified
    Hyper-V cmdlet calls to avoid conflicts with PowerCLI.
#>

function Enable-GuestServices {
    <#
    .SYNOPSIS
        Enables the Guest Service Interface integration service on a Hyper-V VM.
    .DESCRIPTION
        Uses the Hyper-V module-qualified call to avoid conflicts with PowerCLI.
        The Guest Service Interface allows file copy operations between host and guest.
    .PARAMETER VMName
        Name of the VM.
    .PARAMETER ComputerName
        FQDN of the Hyper-V host where the VM resides.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    if (-not $PSCmdlet.ShouldProcess($VMName, "Enable Guest Service Interface on $ComputerName")) {
        return [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
    }

    try {
        # Check if already enabled
        $guestSvc = Hyper-V\Get-VMIntegrationService -VMName $VMName -ComputerName $ComputerName |
                    Where-Object { $_.Name -eq 'Guest Service Interface' }

        if ($guestSvc.Enabled) {
            return [PSCustomObject]@{
                Success      = $true
                ErrorMessage = $null
                Note         = 'Guest Service Interface was already enabled.'
            }
        }

        Hyper-V\Enable-VMIntegrationService -VMName $VMName `
                                            -Name 'Guest Service Interface' `
                                            -ComputerName $ComputerName `
                                            -ErrorAction Stop

        [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }
    catch {
        [PSCustomObject]@{
            Success      = $false
            ErrorMessage = "Failed to enable Guest Services on '$VMName': $_"
        }
    }
}

function Add-HighAvailability {
    <#
    .SYNOPSIS
        Registers a VM as a highly available clustered resource.
    .DESCRIPTION
        Adds the VM as a clustered virtual machine role using FailoverClusters.
        Since the VM is already on Cluster Shared Volume (CSV) storage,
        no additional migration is needed - it just registers the cluster resource.
    .PARAMETER VMName
        Name of the VM.
    .PARAMETER ComputerName
        FQDN of the Hyper-V cluster node where the VM resides.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$ComputerName
    )

    if (-not $PSCmdlet.ShouldProcess($VMName, "Add as highly available VM on $ComputerName")) {
        return [PSCustomObject]@{ Success = $true; ErrorMessage = $null }
    }

    try {
        # Check if already clustered
        $existing = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            Get-ClusterResource -ErrorAction SilentlyContinue |
            Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.OwnerGroup -like "*$using:VMName*" }
        } -ErrorAction Stop

        if ($existing) {
            return [PSCustomObject]@{
                Success      = $true
                ErrorMessage = $null
                Note         = "VM '$VMName' is already a clustered resource."
            }
        }

        # Add the VM as a cluster resource
        Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            Add-ClusterVirtualMachineRole -VMName $using:VMName -ErrorAction Stop
        } -ErrorAction Stop

        [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }
    catch {
        [PSCustomObject]@{
            Success      = $false
            ErrorMessage = "Failed to make '$VMName' highly available: $_"
        }
    }
}

function Test-PostConversion {
    <#
    .SYNOPSIS
        Verifies post-conversion configuration is correct.
    .PARAMETER VMName
        Name of the VM.
    .PARAMETER ComputerName
        FQDN of the Hyper-V host.
    .PARAMETER VMMServer
        FQDN of the VMM server (used to verify SCVMM-level NIC config).
    .PARAMETER ExpectedNICs
        Array of NIC configuration hashtables with Switch and VLAN keys.
        Used to verify each adapter's switch and VLAN assignment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$VMMServer,

        [array]$ExpectedNICs = @()
    )

    $issues = @()

    # Verify Guest Services
    try {
        $guestSvc = Hyper-V\Get-VMIntegrationService -VMName $VMName -ComputerName $ComputerName |
                    Where-Object { $_.Name -eq 'Guest Service Interface' }
        if (-not $guestSvc.Enabled) {
            $issues += 'Guest Service Interface is not enabled.'
        }
    }
    catch {
        $issues += "Cannot verify Guest Services: $_"
    }

    # Verify HA clustering
    try {
        $clustered = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
            Get-ClusterResource -ErrorAction SilentlyContinue |
            Where-Object { $_.ResourceType -eq 'Virtual Machine' -and $_.OwnerGroup -like "*$using:VMName*" }
        } -ErrorAction Stop
        if (-not $clustered) {
            $issues += 'VM is not registered as a cluster resource.'
        }
    }
    catch {
        $issues += "Cannot verify cluster status: $_"
    }

    # Verify NIC count and VLAN/switch assignments via SCVMM
    if ($ExpectedNICs.Count -gt 0) {
        try {
            $scAdapters = @(Get-SCVirtualNetworkAdapter -VMMServer $VMMServer -VM $VMName)

            if ($scAdapters.Count -ne $ExpectedNICs.Count) {
                $issues += "Expected $($ExpectedNICs.Count) NICs, found $($scAdapters.Count)."
            }

            foreach ($expected in $ExpectedNICs) {
                $matchedAdapter = $scAdapters | Where-Object {
                    $_.VirtualNetworkAdapterVLan -and $_.VirtualNetworkAdapterVLan.VLanID -eq $expected.VLAN
                }
                if (-not $matchedAdapter) {
                    $issues += "No adapter found with VLAN $($expected.VLAN) (expected switch: $($expected.TargetSwitch))."
                    continue
                }

                # Verify the adapter is connected to the correct virtual switch
                $connectedSwitch = $matchedAdapter.VirtualNetwork
                if ($connectedSwitch -and $connectedSwitch.Name -ne $expected.TargetSwitch) {
                    $issues += "VLAN $($expected.VLAN): connected to '$($connectedSwitch.Name)', expected '$($expected.TargetSwitch)'."
                }
            }
        }
        catch {
            $issues += "Cannot verify NIC configuration: $_"
        }
    }

    # Report results
    if ($issues.Count -gt 0) {
        [PSCustomObject]@{
            Success      = $false
            ErrorMessage = $issues -join '; '
        }
    }
    else {
        [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }
}

Export-ModuleMember -Function Enable-GuestServices, Add-HighAvailability, Test-PostConversion
