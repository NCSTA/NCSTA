<#
.SYNOPSIS
    Configures network adapters and routing inside a Hyper-V guest via PowerShell Direct.
.DESCRIPTION
    This script is loaded as a ScriptBlock and injected into the guest VM using
    Invoke-Command -VMName (PowerShell Direct over VMBus — no network required).

    NIC identification uses MAC address matching since Hyper-V synthetic adapter
    descriptions are not unique inside the guest.

    Call pattern from the Hyper-V host:
        $script  = [ScriptBlock]::Create((Get-Content ".\lib\Set-GuestNetworking.ps1" -Raw))
        $nic1Cfg = @{ MAC = "001122334455"; IP = "192.168.1.10"; Prefix = 24; Gateway = "192.168.1.1"; DNS = @("10.0.0.1","10.0.0.2") }
        $nic2Cfg = @{ MAC = "001122334466"; IP = "10.0.1.10";   Prefix = 24; Gateway = ""; DNS = @() }
        $routes  = @( @{ Destination="10.0.0.0"; PrefixLength=8; NextHop="10.0.1.254" } )
        Invoke-Command -VMName $vmName -Credential $lapsCred -ScriptBlock $script -ArgumentList $nic1Cfg, $nic2Cfg, $routes
#>
param(
    [Parameter(Mandatory)] [hashtable]  $NIC1,
    [Parameter(Mandatory)] [hashtable]  $NIC2,
    [Parameter(Mandatory)] [hashtable[]] $Routes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Mac ([string]$mac) {
    return $mac.ToUpper() -replace '[:\-]', ''
}

function Get-AdapterByMac ([string]$mac) {
    $normalMac = Normalize-Mac $mac
    $adapter   = Get-NetAdapter | Where-Object { (Normalize-Mac $_.MacAddress) -eq $normalMac }
    if (-not $adapter) { throw "No adapter found matching MAC $mac" }
    return $adapter
}

function Set-AdapterIPConfig {
    param(
        [string]   $AdapterName,
        [string]   $IPAddress,
        [int]      $PrefixLength,
        [string]   $Gateway,
        [string[]] $DNS
    )

    $existing = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($existing) { $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue }

    $existingGW = Get-NetRoute -InterfaceAlias $AdapterName -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($existingGW) { $existingGW | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue }

    $ipParams = @{
        InterfaceAlias = $AdapterName
        IPAddress      = $IPAddress
        PrefixLength   = $PrefixLength
        AddressFamily  = 'IPv4'
    }
    if (-not [string]::IsNullOrWhiteSpace($Gateway)) { $ipParams['DefaultGateway'] = $Gateway }

    New-NetIPAddress @ipParams -ErrorAction Stop | Out-Null

    if ($DNS -and $DNS.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $DNS -ErrorAction Stop
    }

    Write-Output "  Configured $AdapterName : $IPAddress/$PrefixLength $(if($Gateway){"GW $Gateway"})"
}

# --- NIC1 ---
Write-Output "Configuring NIC1 (MAC: $($NIC1.MAC))..."
$adapter1 = Get-AdapterByMac -mac $NIC1.MAC
Rename-NetAdapter -Name $adapter1.Name -NewName 'NIC1' -ErrorAction SilentlyContinue
Set-AdapterIPConfig -AdapterName 'NIC1' -IPAddress $NIC1.IP -PrefixLength $NIC1.Prefix -Gateway $NIC1.Gateway -DNS $NIC1.DNS

# --- NIC2 ---
Write-Output "Configuring NIC2 (MAC: $($NIC2.MAC))..."
$adapter2 = Get-AdapterByMac -mac $NIC2.MAC
Rename-NetAdapter -Name $adapter2.Name -NewName 'NIC2' -ErrorAction SilentlyContinue
Set-AdapterIPConfig -AdapterName 'NIC2' -IPAddress $NIC2.IP -PrefixLength $NIC2.Prefix -Gateway $NIC2.Gateway -DNS $NIC2.DNS

# --- Custom Routes (applied to NIC2) ---
Write-Output "Applying custom routes to NIC2..."

<#
    USER-DEFINED ROUTE BLOCK
    ========================
    Replace this comment block with your custom route resolution function.
    $Routes is an array of hashtables: @{ Destination; PrefixLength; NextHop }
    NIC2 is already renamed above and available as alias 'NIC2'.

    Example structure:
        foreach ($route in $Routes) {
            New-NetRoute -InterfaceAlias 'NIC2' `
                         -DestinationPrefix "$($route.Destination)/$($route.PrefixLength)" `
                         -NextHop           $route.NextHop `
                         -ErrorAction Stop | Out-Null
            Write-Output "  Added route: $($route.Destination)/$($route.PrefixLength) via $($route.NextHop)"
        }
#>

Write-Output "Guest networking configuration complete."
