function Set-HyperVVMConfig {
    <#
    .SYNOPSIS
        Configures Hyper-V VM hardware post-Commvault restore. Runs on the Hyper-V host.
    .DESCRIPTION
        Intended to be called via Invoke-Command targeting the Hyper-V host.
        Performs:
          - Removes all existing vNICs (Commvault-created adapters with no correct config)
          - Adds Front and Back vNICs to the correct vSwitch with VLAN tagging
          - Enables Secure Boot (Gen 2 VMs)
          - Enables Guest Services integration component
        Returns a hashtable with the assigned MAC addresses for both NICs.
    .PARAMETER VMName
        Short VM name as it appears on the Hyper-V host.
    .PARAMETER FrontSwitch
        Name of the Hyper-V virtual switch for the front (external) interface.
    .PARAMETER FrontVLAN
        VLAN ID for the front interface.
    .PARAMETER BackSwitch
        Name of the Hyper-V virtual switch for the back (internal) interface.
    .PARAMETER BackVLAN
        VLAN ID for the back interface.
    .OUTPUTS
        [hashtable] @{ FrontMAC = "001122334455"; BackMAC = "001122334466" }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $FrontSwitch,
        [Parameter(Mandatory)] [int]    $FrontVLAN,
        [Parameter(Mandatory)] [string] $BackSwitch,
        [Parameter(Mandatory)] [int]    $BackVLAN
    )

    $ErrorActionPreference = 'Stop'

    $vm = Get-VM -Name $VMName -ErrorAction Stop

    # --- Remove all existing vNICs ---
    Write-Verbose "[$VMName] Removing existing network adapters..."
    Get-VMNetworkAdapter -VM $vm | Remove-VMNetworkAdapter -Confirm:$false

    # --- Add Front NIC ---
    Write-Verbose "[$VMName] Adding Front NIC → $FrontSwitch (VLAN $FrontVLAN)..."
    Add-VMNetworkAdapter -VM $vm -Name 'Front' -SwitchName $FrontSwitch -ErrorAction Stop
    Set-VMNetworkAdapterVlan -VM $vm -VMNetworkAdapterName 'Front' -Access -VlanId $FrontVLAN
    $frontMAC = (Get-VMNetworkAdapter -VM $vm -Name 'Front').MacAddress

    # --- Add Back NIC ---
    Write-Verbose "[$VMName] Adding Back NIC → $BackSwitch (VLAN $BackVLAN)..."
    Add-VMNetworkAdapter -VM $vm -Name 'Back' -SwitchName $BackSwitch -ErrorAction Stop
    Set-VMNetworkAdapterVlan -VM $vm -VMNetworkAdapterName 'Back' -Access -VlanId $BackVLAN
    $backMAC = (Get-VMNetworkAdapter -VM $vm -Name 'Back').MacAddress

    # --- Enable Secure Boot ---
    Write-Verbose "[$VMName] Enabling Secure Boot..."
    # Only applies to Gen 2 VMs; Gen 1 will throw — catch and warn
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
        FrontMAC = $frontMAC
        BackMAC  = $backMAC
    }
}
