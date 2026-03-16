#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-flight validation for ESXi-to-HyperV migrations.
.DESCRIPTION
    Validates module availability, connectivity, and resource existence
    before attempting V2V conversion. All lookups are name-based — no
    SCVMM IDs required.
#>

function Test-RequiredModules {
    <#
    .SYNOPSIS
        Verifies that required PowerShell modules are available.
    .OUTPUTS
        PSCustomObject with Success and missing module details.
    #>
    [CmdletBinding()]
    param()

    $required = @('VirtualMachineManager', 'Hyper-V', 'FailoverClusters')
    $missing  = @()

    foreach ($mod in $required) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }

    if ($missing.Count -gt 0) {
        [PSCustomObject]@{
            Success      = $false
            ErrorMessage = "Missing required modules: $($missing -join ', ')"
        }
    }
    else {
        [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }
}

function Test-VMMServerConnection {
    <#
    .SYNOPSIS
        Tests connectivity to the SCVMM server.
    .PARAMETER VMMServer
        FQDN of the VMM server.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer
    )

    try {
        $vmmConn = Get-SCVMMServer -ComputerName $VMMServer -ErrorAction Stop
        [PSCustomObject]@{
            Success      = $true
            Data         = $vmmConn
            ErrorMessage = $null
        }
    }
    catch {
        [PSCustomObject]@{
            Success      = $false
            Data         = $null
            ErrorMessage = "Failed to connect to VMM server '$VMMServer': $_"
        }
    }
}

function Test-TargetHost {
    <#
    .SYNOPSIS
        Validates the target Hyper-V host is managed and responding in SCVMM.
    .PARAMETER VMMServer
        FQDN of the VMM server.
    .PARAMETER TargetHost
        FQDN of the target Hyper-V host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer,

        [Parameter(Mandatory)]
        [string]$TargetHost
    )

    try {
        $vmHost = Get-SCVMHost -VMMServer $VMMServer |
                  Where-Object { $_.Name -eq $TargetHost }

        if (-not $vmHost) {
            return [PSCustomObject]@{
                Success      = $false
                Data         = $null
                ErrorMessage = "Target host '$TargetHost' not found in SCVMM."
            }
        }

        if ($vmHost.OverallState -ne 'OK') {
            return [PSCustomObject]@{
                Success      = $false
                Data         = $vmHost
                ErrorMessage = "Target host '$TargetHost' state is '$($vmHost.OverallState)', expected 'OK'."
            }
        }

        [PSCustomObject]@{
            Success      = $true
            Data         = $vmHost
            ErrorMessage = $null
        }
    }
    catch {
        [PSCustomObject]@{
            Success      = $false
            Data         = $null
            ErrorMessage = "Failed to validate target host '$TargetHost': $_"
        }
    }
}

function Test-SourceVM {
    <#
    .SYNOPSIS
        Validates the source VM exists on the ESXi host via SCVMM.
    .PARAMETER VMMServer
        FQDN of the VMM server.
    .PARAMETER VMName
        Name of the VM to migrate.
    .PARAMETER SourceHost
        FQDN of the ESXi source host.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer,

        [Parameter(Mandatory)]
        [string]$VMName,

        [Parameter(Mandatory)]
        [string]$SourceHost
    )

    try {
        $vm = Get-SCVirtualMachine -VMMServer $VMMServer -Name $VMName |
              Where-Object { $_.VMHost.Name -eq $SourceHost }

        if (-not $vm) {
            return [PSCustomObject]@{
                Success      = $false
                Data         = $null
                ErrorMessage = "VM '$VMName' not found on host '$SourceHost'. Ensure the ESXi host is managed by SCVMM."
            }
        }

        [PSCustomObject]@{
            Success      = $true
            Data         = $vm
            ErrorMessage = $null
        }
    }
    catch {
        [PSCustomObject]@{
            Success      = $false
            Data         = $null
            ErrorMessage = "Failed to validate source VM '$VMName': $_"
        }
    }
}

function Test-TargetResources {
    <#
    .SYNOPSIS
        Validates that target virtual switches, VM networks, and storage path exist.
    .PARAMETER VMMServer
        FQDN of the VMM server.
    .PARAMETER TargetHost
        FQDN of the target Hyper-V host.
    .PARAMETER TargetHostID
        VMHostID of the target host (used to filter virtual networks).
    .PARAMETER StoragePath
        Cluster storage path on the target host.
    .PARAMETER NICs
        Array of NIC configuration hashtables with TargetSwitch, TargetVMNetwork, VLAN keys.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VMMServer,

        [Parameter(Mandatory)]
        [string]$TargetHost,

        [Parameter(Mandatory)]
        [string]$TargetHostID,

        [Parameter(Mandatory)]
        [string]$StoragePath,

        [Parameter(Mandatory)]
        [array]$NICs
    )

    $errors = @()

    # Validate storage path exists on target
    try {
        $pathExists = Invoke-Command -ComputerName $TargetHost -ScriptBlock {
            Test-Path $using:StoragePath
        } -ErrorAction Stop
        if (-not $pathExists) {
            $errors += "Storage path '$StoragePath' does not exist on '$TargetHost'."
        }
    }
    catch {
        $errors += "Cannot verify storage path on '$TargetHost': $_"
    }

    # Validate each NIC's target virtual switch and VM network by name
    foreach ($nic in $NICs) {
        try {
            $vSwitch = Get-SCVirtualNetwork -VMMServer $VMMServer -Name $nic.TargetSwitch |
                       Where-Object { $_.VMHostID -eq $TargetHostID }
            if (-not $vSwitch) {
                $errors += "Virtual switch '$($nic.TargetSwitch)' not found on target host."
            }
        }
        catch {
            $errors += "Cannot validate virtual switch '$($nic.TargetSwitch)': $_"
        }

        try {
            $vmNetwork = Get-SCVMNetwork -VMMServer $VMMServer -Name $nic.TargetVMNetwork
            if (-not $vmNetwork) {
                $errors += "VM network '$($nic.TargetVMNetwork)' not found in SCVMM."
            }
        }
        catch {
            $errors += "Cannot validate VM network '$($nic.TargetVMNetwork)': $_"
        }
    }

    if ($errors.Count -gt 0) {
        [PSCustomObject]@{
            Success      = $false
            ErrorMessage = $errors -join '; '
        }
    }
    else {
        [PSCustomObject]@{
            Success      = $true
            ErrorMessage = $null
        }
    }
}

Export-ModuleMember -Function Test-RequiredModules, Test-VMMServerConnection,
                              Test-TargetHost, Test-SourceVM, Test-TargetResources
