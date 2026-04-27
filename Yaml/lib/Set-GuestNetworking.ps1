<#
.SYNOPSIS
    Configures network adapters and routing inside a Hyper-V guest via PowerShell Direct.
.DESCRIPTION
    This script is loaded as a ScriptBlock and injected into the guest VM using
    Invoke-Command -VMName (PowerShell Direct over VMBus — no network required).

    NIC identification uses MAC address matching since Hyper-V synthetic adapter
    descriptions are not unique inside the guest.

    Call pattern from the Hyper-V host:
        $script    = [ScriptBlock]::Create((Get-Content ".\lib\Set-GuestNetworking.ps1" -Raw))
        $frontCfg  = @{ MAC = "001122334455"; IP = "10.0.1.10"; Prefix = 24; Gateway = "10.0.1.1"; DNS = @("10.0.0.1","10.0.0.2") }
        $backCfg   = @{ MAC = "001122334466"; IP = "192.168.10.10"; Prefix = 24; Gateway = "" }
        $routes    = @( @{ Destination="10.0.0.0"; PrefixLength=8; NextHop="192.168.10.254" } )
        Invoke-Command -VMName $vmName -Credential $lapsCred -ScriptBlock $script -ArgumentList $frontCfg, $backCfg, $routes
#>
param(
    [Parameter(Mandatory)] [hashtable] $FrontNIC,
    [Parameter(Mandatory)] [hashtable] $BackNIC,
    [Parameter(Mandatory)] [hashtable[]] $Routes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Normalize-Mac ([string]$mac) {
    # Hyper-V host returns MAC without delimiters; guest uses dashes. Normalize to uppercase no-delimiter.
    return $mac.ToUpper() -replace '[:\-]', ''
}

function Get-AdapterByMac ([string]$mac) {
    $normalMac = Normalize-Mac $mac
    $adapter = Get-NetAdapter | Where-Object { (Normalize-Mac $_.MacAddress) -eq $normalMac }
    if (-not $adapter) {
        throw "No adapter found matching MAC $mac"
    }
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

    # Remove existing IP configuration
    $existing = Get-NetIPAddress -InterfaceAlias $AdapterName -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($existing) {
        $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }

    $existingGW = Get-NetRoute -InterfaceAlias $AdapterName -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
    if ($existingGW) {
        $existingGW | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Set new IP
    $ipParams = @{
        InterfaceAlias = $AdapterName
        IPAddress      = $IPAddress
        PrefixLength   = $PrefixLength
        AddressFamily  = 'IPv4'
    }

    if (-not [string]::IsNullOrWhiteSpace($Gateway)) {
        $ipParams['DefaultGateway'] = $Gateway
    }

    New-NetIPAddress @ipParams -ErrorAction Stop | Out-Null

    # Set DNS
    if ($DNS -and $DNS.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceAlias $AdapterName -ServerAddresses $DNS -ErrorAction Stop
    }

    Write-Output "  Configured $AdapterName : $IPAddress/$PrefixLength $(if($Gateway){"GW $Gateway"})"
}

# --- Front NIC ---
Write-Output "Configuring Front NIC (MAC: $($FrontNIC.MAC))..."
$frontAdapter = Get-AdapterByMac -mac $FrontNIC.MAC
Rename-NetAdapter -Name $frontAdapter.Name -NewName 'Front' -ErrorAction SilentlyContinue

Set-AdapterIPConfig `
    -AdapterName  'Front' `
    -IPAddress    $FrontNIC.IP `
    -PrefixLength $FrontNIC.Prefix `
    -Gateway      $FrontNIC.Gateway `
    -DNS          $FrontNIC.DNS

# --- Back NIC ---
Write-Output "Configuring Back NIC (MAC: $($BackNIC.MAC))..."
$backAdapter = Get-AdapterByMac -mac $BackNIC.MAC
Rename-NetAdapter -Name $backAdapter.Name -NewName 'Back' -ErrorAction SilentlyContinue

Set-AdapterIPConfig `
    -AdapterName  'Back' `
    -IPAddress    $BackNIC.IP `
    -PrefixLength $BackNIC.Prefix `
    -Gateway      $BackNIC.Gateway `
    -DNS          @()

# --- Custom Routes (Back interface) ---
Write-Output "Applying custom routes..."

<#
    USER-DEFINED ROUTE BLOCK
    ========================
    Replace this comment block with your custom route resolution function.
    $Routes is an array of hashtables: @{ Destination; PrefixLength; NextHop }
    The Back NIC is already renamed to 'Back' above.

    Example structure:
        foreach ($route in $Routes) {
            New-NetRoute -InterfaceAlias 'Back' `
                         -DestinationPrefix "$($route.Destination)/$($route.PrefixLength)" `
                         -NextHop           $route.NextHop `
                         -ErrorAction Stop | Out-Null
            Write-Output "  Added route: $($route.Destination)/$($route.PrefixLength) via $($route.NextHop)"
        }
#>

Write-Output "Guest networking configuration complete."
