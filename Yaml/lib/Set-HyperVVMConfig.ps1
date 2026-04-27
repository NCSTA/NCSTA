function Set-HyperVVMConfig {
    <#
    .SYNOPSIS
        Configures Hyper-V VM hardware post-Commvault restore. Runs on the Hyper-V host.
    .DESCRIPTION
        Intended to be called via Invoke-Command targeting the Hyper-V host.
        Performs:
          - Removes all existing vNICs (Commvault-created adapters with no correct config)
          - Adds NIC1 and NIC2 to their respective vSwitches with VLAN tagging
          - Enables Secure Boot (Gen 2 VMs)
          - Enables Guest Services integration component
        Returns a hashtable with the assigned MAC addresses for both NICs.
    .PARAMETER VMName
        Short VM name as it appears on the Hyper-V host.
    .PARAMETER NIC1Switch
        Hyper-V virtual switch name for NIC1 (matches portgroup name from VMware).
    .PARAMETER NIC1VLAN
        VLAN ID for NIC1.
    .PARAMETER NIC2Switch
        Hyper-V virtual switch name for NIC2 (matches portgroup name from VMware).
    .PARAMETER NIC2VLAN
        VLAN ID for NIC2.
    .OUTPUTS
        [hashtable] @{ NIC1MAC = "001122334455"; NIC2MAC = "001122334466" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $NIC1Switch,
        [Parameter(Mandatory)] [int]    $NIC1VLAN,
        [Parameter(Mandatory)] [string] $NIC2Switch,
        [Parameter(Mandatory)] [int]    $NIC2VLAN
    )

    $ErrorActionPreference = 'Stop'

    $vm = Get-VM -Name $VMName -ErrorAction Stop

    # --- Remove all existing vNICs ---
    Write-Verbose "[$VMName] Removing existing network adapters..."
    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter -Confirm:$false

    # --- Add NIC1 ---
    Write-Verbose "[$VMName] Adding NIC1 → $NIC1Switch (VLAN $NIC1VLAN)..."
    Add-VMNetworkAdapter -VM $vm -Name 'NIC1' -SwitchName $NIC1Switch -ErrorAction Stop
    Set-VMNetworkAdapterVlan -VM $vm -VMNetworkAdapterName 'NIC1' -Access -VlanId $NIC1VLAN
    $nic1MAC = (Get-VMNetworkAdapter -VM $vm -Name 'NIC1').MacAddress

    # --- Add NIC2 ---
    Write-Verbose "[$VMName] Adding NIC2 → $NIC2Switch (VLAN $NIC2VLAN)..."
    Add-VMNetworkAdapter -VM $vm -Name 'NIC2' -SwitchName $NIC2Switch -ErrorAction Stop
    Set-VMNetworkAdapterVlan -VM $vm -VMNetworkAdapterName 'NIC2' -Access -VlanId $NIC2VLAN
    $nic2MAC = (Get-VMNetworkAdapter -VM $vm -Name 'NIC2').MacAddress

    # --- Enable Secure Boot ---
    Write-Verbose "[$VMName] Enabling Secure Boot..."
    try {
        Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows' -ErrorAction Stop
    }
    catch {
        Write-Warning "[$VMName] Secure Boot skipped (likely Gen 1 VM): $($_.Exception.Message)"
    }

    # --- Enable Guest Services ---
    Write-Verbose "[$VMName] Enabling Guest Services integration component..."
    Enable-VMIntegrationService -VM $vm -Name 'Guest Service Interface' -ErrorAction Stop

    Write-Verbose "[$VMName] Hardware configuration complete."

    return @{
        NIC1MAC = $nic1MAC
        NIC2MAC = $nic2MAC
    }
}
