<#
.SYNOPSIS
    Applies post-migration Hyper-V and guest NIC configuration for restored VMs.

.DESCRIPTION
    Loads per-VM JSON created by Collect-VMwareMigrationData.ps1, locates the
    restored VM in SCVMM, configures the production virtual NIC VLAN/VM network,
    and then uses PowerShell Direct from the Hyper-V host to set the Windows
    guest static IP, gateway, DNS servers, DNS registration setting, and optional
    adapter name.

    Back-side management NICs are excluded when any IPv4 address on the adapter
    matches 172.25.*.* or 169.*.*.* unless the NIC is matched by the collected
    source MAC address.

.NOTES
    PowerShell 5.1 compatible.
    Requires the VirtualMachineManager module on the management server.
    Requires the Hyper-V module and PowerShell Direct support on each Hyper-V host.
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VMListPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer = $env:COMPUTERNAME,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataDirectory = 'C:\MigrationData',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = 'C:\MigrationLogs',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ProductionSwitchName = 'Production Switch',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$MigrationAccountUserName = 'Hypervmigrate',

    [Parameter()]
    [System.Management.Automation.PSCredential]$SCVMMCredential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$HostCredential,

    [Parameter()]
    [switch]$DisableHyperVFallback
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:LogPath = $null

function Initialize-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Initialize-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    Initialize-Directory -Path $Directory
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogPath = Join-Path -Path $Directory -ChildPath ("Script2_{0}.log" -f $timestamp)
    New-Item -Path $script:LogPath -ItemType File -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $line
    }
}

function Resolve-VMNameList {
    param(
        [string[]]$Names,
        [string]$Path
    )

    if ($Path) {
        $Names = Get-Content -LiteralPath $Path | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*'
        } | ForEach-Object { $_.Trim() }
    }

    $resolved = @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($resolved.Count -eq 0) {
        throw 'No VM names were supplied.'
    }

    return $resolved
}

function ConvertTo-NormalizedMacAddress {
    param(
        [AllowNull()]
        [string]$MacAddress
    )

    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        return $null
    }

    return (($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant())
}

function Test-IsLocalComputerName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    $shortName = $ComputerName.Split('.')[0]
    return ($ComputerName -ieq $env:COMPUTERNAME -or $shortName -ieq $env:COMPUTERNAME -or $ComputerName -ieq 'localhost' -or $ComputerName -eq '.')
}

function ConvertTo-PrefixLength {
    param(
        [AllowNull()]
        [string]$SubnetMask
    )

    if ([string]::IsNullOrWhiteSpace($SubnetMask)) {
        return $null
    }

    $parts = @($SubnetMask.Split('.'))
    if ($parts.Count -ne 4) {
        throw "Invalid subnet mask '$SubnetMask'."
    }

    $binary = ''
    foreach ($part in $parts) {
        $number = [int]$part
        if ($number -lt 0 -or $number -gt 255) {
            throw "Invalid subnet mask '$SubnetMask'."
        }

        $binary += [Convert]::ToString($number, 2).PadLeft(8, '0')
    }

    if ($binary -notmatch '^1*0*$') {
        throw "Subnet mask '$SubnetMask' is not contiguous."
    }

    return ($binary.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function New-MigrationAccountCredential {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    # Character codes for the fixed migration account password requested for this migration workflow.
    $passwordPlain = -join ([char[]](77,105,103,114,97,116,101,49,51,53,33))
    $securePassword = ConvertTo-SecureString $passwordPlain -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential (".\$UserName", $securePassword)
}

function Get-MigrationData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $path = Join-Path -Path $Directory -ChildPath ('{0}_MigrationData.json' -f $Name)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Migration data file was not found: $path"
    }

    $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $frontSideNics = @()

    if ($data.PSObject.Properties.Name -contains 'FrontSideNics') {
        $frontSideNics = @($data.FrontSideNics)
    }
    elseif ($data.PSObject.Properties.Name -contains 'FrontSideNic') {
        $frontSideNics = @($data.FrontSideNic)
    }

    if ($frontSideNics.Count -eq 0) {
        throw "Migration data file '$path' does not contain any front-side NIC records."
    }

    return [pscustomobject]@{
        Path          = $path
        VMName        = $data.VMName
        Raw           = $data
        FrontSideNics = @($frontSideNics)
    }
}

function Get-SCVirtualMachineStrict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        $VMMServerObject
    )

    $matches = @(Get-SCVirtualMachine -VMMServer $VMMServerObject -Name $Name -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($matches.Count -eq 0) {
        throw "VM '$Name' was not found in SCVMM."
    }

    if ($matches.Count -gt 1) {
        throw "More than one VM named '$Name' was found in SCVMM."
    }

    return $matches[0]
}

function Get-SCVmHostName {
    param(
        [Parameter(Mandatory = $true)]
        $SCVirtualMachine
    )

    $hostObject = $SCVirtualMachine.VMHost
    if (-not $hostObject) {
        throw ("SCVMM VM '{0}' does not have a VMHost assigned." -f $SCVirtualMachine.Name)
    }

    foreach ($propertyName in @('ComputerName', 'FullyQualifiedDomainName', 'FQDN', 'Name')) {
        if ($hostObject.PSObject.Properties.Name -contains $propertyName) {
            $value = $hostObject.$propertyName
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                return [string]$value
            }
        }
    }

    throw ("Unable to determine Hyper-V host name for SCVMM VM '{0}'." -f $SCVirtualMachine.Name)
}

function Get-SCVirtualNetworkAdaptersForVM {
    param(
        [Parameter(Mandatory = $true)]
        $SCVirtualMachine
    )

    try {
        return @(Get-SCVirtualNetworkAdapter -VM $SCVirtualMachine -ErrorAction Stop)
    }
    catch {
        if ($SCVirtualMachine.PSObject.Properties.Name -contains 'VirtualNetworkAdapters') {
            return @($SCVirtualMachine.VirtualNetworkAdapters)
        }

        throw
    }
}

function Get-SCVirtualAdapterNetworkNames {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    $names = @()
    foreach ($propertyName in @('Name', 'ConnectionName', 'VirtualNetwork', 'VMNetwork', 'LogicalNetwork', 'VMSubnet', 'PortClassification', 'NetworkLocation')) {
        if ($Adapter.PSObject.Properties.Name -contains $propertyName) {
            $value = $Adapter.$propertyName
            if ($null -eq $value) {
                continue
            }

            if ($value -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $names += $value
                }
            }
            elseif ($value.PSObject.Properties.Name -contains 'Name') {
                if (-not [string]::IsNullOrWhiteSpace([string]$value.Name)) {
                    $names += [string]$value.Name
                }
            }
        }
    }

    return @($names | Select-Object -Unique)
}

function Find-SCVirtualAdapterForNic {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$SCAdapters,

        [Parameter(Mandatory = $true)]
        $NicRecord,

        [Parameter()]
        $HyperVAdapter,

        [Parameter(Mandatory = $true)]
        [int]$FrontSideNicCount
    )

    $targetMacs = @()
    if ($NicRecord.MacAddress) {
        $targetMacs += (ConvertTo-NormalizedMacAddress -MacAddress $NicRecord.MacAddress)
    }

    if ($HyperVAdapter -and $HyperVAdapter.MacAddress) {
        $targetMacs += (ConvertTo-NormalizedMacAddress -MacAddress $HyperVAdapter.MacAddress)
    }

    $targetMacs = @($targetMacs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    foreach ($targetMac in $targetMacs) {
        $match = @($SCAdapters | Where-Object {
            $adapterMac = $null
            foreach ($propertyName in @('MACAddress', 'MacAddress', 'PhysicalAddress')) {
                if ($_.PSObject.Properties.Name -contains $propertyName) {
                    $adapterMac = $_.$propertyName
                    break
                }
            }

            (ConvertTo-NormalizedMacAddress -MacAddress $adapterMac) -eq $targetMac
        } | Select-Object -First 1)

        if ($match.Count -gt 0) {
            return $match[0]
        }
    }

    if ($HyperVAdapter -and $HyperVAdapter.Name) {
        $nameMatch = @($SCAdapters | Where-Object { $_.Name -eq $HyperVAdapter.Name } | Select-Object -First 1)
        if ($nameMatch.Count -gt 0) {
            return $nameMatch[0]
        }
    }

    if ($NicRecord.PortGroupName) {
        $networkMatch = @($SCAdapters | Where-Object {
            $adapterNames = @(Get-SCVirtualAdapterNetworkNames -Adapter $_)
            $adapterNames -contains $NicRecord.PortGroupName
        } | Select-Object -First 1)

        if ($networkMatch.Count -gt 0) {
            return $networkMatch[0]
        }
    }

    if ($SCAdapters.Count -eq 1 -and $FrontSideNicCount -eq 1) {
        return $SCAdapters[0]
    }

    return $null
}

function Confirm-SCVirtualAdapterNetwork {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [AllowNull()]
        [string]$PortGroupName,

        [Parameter(Mandatory = $true)]
        $VMMServerObject
    )

    if ([string]::IsNullOrWhiteSpace($PortGroupName)) {
        return $true
    }

    $currentNames = @(Get-SCVirtualAdapterNetworkNames -Adapter $Adapter)
    if ($currentNames -contains $PortGroupName) {
        Write-Log -Message ("SCVMM adapter '{0}' is already connected to '{1}'." -f $Adapter.Name, $PortGroupName)
        return $true
    }

    Write-Log -Level WARN -Message ("SCVMM adapter '{0}' current networks are '{1}', expected '{2}'." -f $Adapter.Name, ($currentNames -join ', '), $PortGroupName)

    try {
        $vmNetwork = @(Get-SCVMNetwork -VMMServer $VMMServerObject -ErrorAction Stop | Where-Object { $_.Name -eq $PortGroupName } | Select-Object -First 1)
        if ($vmNetwork.Count -gt 0) {
            Write-Log -Message ("Setting SCVMM adapter '{0}' VM network to '{1}'." -f $Adapter.Name, $PortGroupName)
            Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $Adapter -VMNetwork $vmNetwork[0] -ErrorAction Stop | Out-Null
            return $true
        }
    }
    catch {
        Write-Log -Level WARN -Message ("Unable to set SCVMM VM network '{0}' on adapter '{1}': {2}" -f $PortGroupName, $Adapter.Name, $_.Exception.Message)
    }

    return $false
}

function Set-SCVirtualAdapterVlan {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [Parameter()]
        [AllowNull()]
        $VlanId
    )

    if ($null -eq $VlanId -or [string]::IsNullOrWhiteSpace([string]$VlanId)) {
        throw ("No VLAN ID was present in the migration data for adapter '{0}'." -f $Adapter.Name)
    }

    $numericVlanId = [int]$VlanId
    if ($numericVlanId -le 0) {
        Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $Adapter -VLanEnabled $false -ErrorAction Stop | Out-Null
    }
    else {
        Set-SCVirtualNetworkAdapter -VirtualNetworkAdapter $Adapter -VLanEnabled $true -VLanID $numericVlanId -ErrorAction Stop | Out-Null
    }
}

function Invoke-OnHyperVHost {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [object[]]$ArgumentList = @(),

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    if (Test-IsLocalComputerName -ComputerName $HostName) {
        return & $ScriptBlock @ArgumentList
    }

    if ($Credential) {
        return Invoke-Command -ComputerName $HostName -Credential $Credential -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }

    return Invoke-Command -ComputerName $HostName -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
}

function Get-HyperVNetworkAdapters {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptBlock = {
        param(
            [string]$VmName
        )

        Import-Module Hyper-V -ErrorAction Stop
        Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop |
            Select-Object -Property Name, SwitchName, MacAddress, Status, IsLegacy, IPAddresses
    }

    return @(Invoke-OnHyperVHost -HostName $HostName -Credential $Credential -ScriptBlock $scriptBlock -ArgumentList @($Name))
}

function Find-HyperVAdapterForNic {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$HyperVAdapters,

        [Parameter(Mandatory = $true)]
        $NicRecord,

        [Parameter(Mandatory = $true)]
        [string]$ProductionSwitchName,

        [Parameter(Mandatory = $true)]
        [int]$FrontSideNicCount
    )

    $targetMac = ConvertTo-NormalizedMacAddress -MacAddress $NicRecord.MacAddress
    if ($targetMac) {
        $macMatch = @($HyperVAdapters | Where-Object {
            (ConvertTo-NormalizedMacAddress -MacAddress $_.MacAddress) -eq $targetMac
        } | Select-Object -First 1)

        if ($macMatch.Count -gt 0) {
            return $macMatch[0]
        }
    }

    $productionMatches = @($HyperVAdapters | Where-Object { $_.SwitchName -eq $ProductionSwitchName })
    if ($productionMatches.Count -eq 1) {
        return $productionMatches[0]
    }

    if ($HyperVAdapters.Count -eq 1 -and $FrontSideNicCount -eq 1) {
        return $HyperVAdapters[0]
    }

    return $null
}

function Ensure-HyperVAdapterSwitch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$AdapterName,

        [Parameter(Mandatory = $true)]
        [string]$ProductionSwitchName,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptBlock = {
        param(
            [string]$VmName,
            [string]$VmNetworkAdapterName,
            [string]$SwitchName
        )

        Import-Module Hyper-V -ErrorAction Stop
        $adapter = Get-VMNetworkAdapter -VMName $VmName -Name $VmNetworkAdapterName -ErrorAction Stop
        if ($adapter.SwitchName -ne $SwitchName) {
            Connect-VMNetworkAdapter -VMName $VmName -Name $VmNetworkAdapterName -SwitchName $SwitchName -ErrorAction Stop
        }
    }

    Invoke-OnHyperVHost -HostName $HostName -Credential $Credential -ScriptBlock $scriptBlock -ArgumentList @($Name, $AdapterName, $ProductionSwitchName) | Out-Null
}

function Set-HyperVAdapterVlan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$AdapterName,

        [Parameter()]
        [AllowNull()]
        $VlanId,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    if ($null -eq $VlanId -or [string]::IsNullOrWhiteSpace([string]$VlanId)) {
        throw ("No VLAN ID was present in the migration data for Hyper-V adapter '{0}'." -f $AdapterName)
    }

    $scriptBlock = {
        param(
            [string]$VmName,
            [string]$VmNetworkAdapterName,
            [int]$NumericVlanId
        )

        Import-Module Hyper-V -ErrorAction Stop
        if ($NumericVlanId -le 0) {
            Set-VMNetworkAdapterVlan -VMName $VmName -VMNetworkAdapterName $VmNetworkAdapterName -Untagged -ErrorAction Stop
        }
        else {
            Set-VMNetworkAdapterVlan -VMName $VmName -VMNetworkAdapterName $VmNetworkAdapterName -Access -VlanId $NumericVlanId -ErrorAction Stop
        }
    }

    Invoke-OnHyperVHost -HostName $HostName -Credential $Credential -ScriptBlock $scriptBlock -ArgumentList @($Name, $AdapterName, [int]$VlanId) | Out-Null
}

function Get-GuestNicConfigurationScriptText {
    return @'
param(
    [Parameter(Mandatory = $true)]
    [string]$NicJson
)

$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedMacAddress {
    param([AllowNull()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) {
        return $null
    }

    return (($MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant())
}

function Test-BackSideIPv4Address {
    param([AllowNull()][string]$IPAddress)
    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return $false
    }

    return ($IPAddress -like '172.25.*' -or $IPAddress -like '169.*')
}

function ConvertTo-PrefixLength {
    param([AllowNull()][string]$SubnetMask)
    if ([string]::IsNullOrWhiteSpace($SubnetMask)) {
        return $null
    }

    $parts = @($SubnetMask.Split('.'))
    if ($parts.Count -ne 4) {
        throw "Invalid subnet mask '$SubnetMask'."
    }

    $binary = ''
    foreach ($part in $parts) {
        $number = [int]$part
        if ($number -lt 0 -or $number -gt 255) {
            throw "Invalid subnet mask '$SubnetMask'."
        }

        $binary += [Convert]::ToString($number, 2).PadLeft(8, '0')
    }

    if ($binary -notmatch '^1*0*$') {
        throw "Subnet mask '$SubnetMask' is not contiguous."
    }

    return ($binary.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Get-AdapterIPv4Addresses {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    return @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike '127.*' })
}

function Test-AdapterIsBackSide {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    $addresses = @(Get-AdapterIPv4Addresses -Adapter $Adapter)
    foreach ($address in $addresses) {
        if (Test-BackSideIPv4Address -IPAddress $address.IPAddress) {
            return $true
        }
    }

    return $false
}

function Find-TargetAdapter {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Adapters,

        [Parameter(Mandatory = $true)]
        $Target,

        [Parameter(Mandatory = $true)]
        [int]$TargetIndex,

        [Parameter(Mandatory = $true)]
        [int]$TargetCount
    )

    $targetMac = ConvertTo-NormalizedMacAddress -MacAddress $Target.MacAddress
    if ($targetMac) {
        $macMatch = @($Adapters | Where-Object {
            (ConvertTo-NormalizedMacAddress -MacAddress $_.MacAddress) -eq $targetMac
        } | Select-Object -First 1)

        if ($macMatch.Count -gt 0) {
            return $macMatch[0]
        }
    }

    foreach ($nameProperty in @('AdapterName', 'InterfaceAlias')) {
        if ($Target.PSObject.Properties.Name -contains $nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$Target.$nameProperty)) {
            $nameMatch = @($Adapters | Where-Object { $_.Name -eq $Target.$nameProperty } | Select-Object -First 1)
            if ($nameMatch.Count -gt 0 -and -not (Test-AdapterIsBackSide -Adapter $nameMatch[0])) {
                return $nameMatch[0]
            }
        }
    }

    $eligibleAdapters = @($Adapters | Where-Object { -not (Test-AdapterIsBackSide -Adapter $_) })
    if ($eligibleAdapters.Count -eq 1) {
        return $eligibleAdapters[0]
    }

    if ($eligibleAdapters.Count -eq $TargetCount -and $TargetIndex -lt $eligibleAdapters.Count) {
        return $eligibleAdapters[$TargetIndex]
    }

    return $null
}

function Clear-IPv4Configuration {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter
    )

    Set-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue

    $routes = @(Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
    foreach ($route in $routes) {
        Remove-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix $route.DestinationPrefix -NextHop $route.NextHop -Confirm:$false -ErrorAction SilentlyContinue
    }

    $addresses = @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike '127.*' })
    foreach ($address in $addresses) {
        Remove-NetIPAddress -InterfaceIndex $Adapter.ifIndex -IPAddress $address.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Set-TargetAdapterName {
    param(
        [Parameter(Mandatory = $true)]
        $Adapter,

        [Parameter(Mandatory = $true)]
        $Target
    )

    $desiredName = $null
    foreach ($propertyName in @('AdapterName', 'InterfaceAlias')) {
        if ($Target.PSObject.Properties.Name -contains $propertyName -and -not [string]::IsNullOrWhiteSpace([string]$Target.$propertyName)) {
            $desiredName = [string]$Target.$propertyName
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($desiredName) -or $Adapter.Name -eq $desiredName) {
        return $Adapter.Name
    }

    $existing = Get-NetAdapter -Name $desiredName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Rename-NetAdapter -Name $Adapter.Name -NewName $desiredName -ErrorAction Stop
        return $desiredName
    }

    return $Adapter.Name
}

$targets = @(ConvertFrom-Json -InputObject $NicJson)
$adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.MacAddress })
$results = @()

for ($i = 0; $i -lt $targets.Count; $i++) {
    $target = $targets[$i]
    $adapter = Find-TargetAdapter -Adapters $adapters -Target $target -TargetIndex $i -TargetCount $targets.Count
    if (-not $adapter) {
        $results += [pscustomobject]@{
            AdapterName = $null
            IPAddress   = $target.IPAddress
            Success     = $false
            Message     = 'No eligible guest adapter was found.'
        }
        continue
    }

    try {
        $prefixLength = $target.PrefixLength
        if (($null -eq $prefixLength -or [string]::IsNullOrWhiteSpace([string]$prefixLength)) -and $target.SubnetMask) {
            $prefixLength = ConvertTo-PrefixLength -SubnetMask $target.SubnetMask
        }

        if ($null -eq $prefixLength -or [string]::IsNullOrWhiteSpace([string]$prefixLength)) {
            throw ("No prefix length or subnet mask was supplied for IP address {0}." -f $target.IPAddress)
        }

        Clear-IPv4Configuration -Adapter $adapter

        $newIpParams = @{
            InterfaceIndex = $adapter.ifIndex
            IPAddress      = [string]$target.IPAddress
            PrefixLength   = [int]$prefixLength
            ErrorAction    = 'Stop'
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$target.DefaultGateway)) {
            $newIpParams.DefaultGateway = [string]$target.DefaultGateway
        }

        New-NetIPAddress @newIpParams | Out-Null

        $dnsServers = @($target.DNSServers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($dnsServers.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServers -ErrorAction Stop
        }
        else {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
        }

        if ($target.PSObject.Properties.Name -contains 'RegisterDnsClient' -and $null -ne $target.RegisterDnsClient -and -not [string]::IsNullOrWhiteSpace([string]$target.RegisterDnsClient)) {
            $registerDnsClient = [System.Convert]::ToBoolean($target.RegisterDnsClient)
            Set-DnsClient -InterfaceIndex $adapter.ifIndex -RegisterThisConnectionsAddress $registerDnsClient -ErrorAction Stop
        }

        $finalAdapterName = Set-TargetAdapterName -Adapter $adapter -Target $target

        $results += [pscustomobject]@{
            AdapterName = $finalAdapterName
            IPAddress   = [string]$target.IPAddress
            Success     = $true
            Message     = 'Configured'
        }
    }
    catch {
        $results += [pscustomobject]@{
            AdapterName = $adapter.Name
            IPAddress   = $target.IPAddress
            Success     = $false
            Message     = $_.Exception.Message
        }
    }
}

return $results
'@
}

function Invoke-GuestNicConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object[]]$FrontSideNics,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$GuestCredential,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    $nicJson = ConvertTo-Json -InputObject @($FrontSideNics) -Depth 10 -Compress
    $guestScriptText = Get-GuestNicConfigurationScriptText

    $hostScriptBlock = {
        param(
            [string]$VmName,
            [System.Management.Automation.PSCredential]$VmCredential,
            [string]$Payload,
            [string]$ScriptText
        )

        Import-Module Hyper-V -ErrorAction Stop
        $guestScriptBlock = [scriptblock]::Create($ScriptText)
        Invoke-Command -VMName $VmName -Credential $VmCredential -ScriptBlock $guestScriptBlock -ArgumentList $Payload -ErrorAction Stop
    }

    return @(Invoke-OnHyperVHost -HostName $HostName -Credential $Credential -ScriptBlock $hostScriptBlock -ArgumentList @($Name, $GuestCredential, $nicJson, $guestScriptText))
}

Initialize-Log -Directory $LogDirectory

Write-Log -Message 'Starting post-migration Hyper-V NIC configuration.'
Write-Log -Message ("Data directory: {0}" -f $DataDirectory)
Write-Log -Message ("Log file: {0}" -f $script:LogPath)

if (-not (Test-Path -LiteralPath $DataDirectory -PathType Container)) {
    throw "Migration data directory was not found: $DataDirectory"
}

try {
    Import-Module VirtualMachineManager -ErrorAction Stop
}
catch {
    Write-Log -Level ERROR -Message ("VirtualMachineManager module could not be imported: {0}" -f $_.Exception.Message)
    throw
}

if (-not $SCVMMCredential) {
    $SCVMMCredential = Get-Credential -Message ("Enter credentials for SCVMM server '{0}'" -f $VMMServer)
}

$guestCredential = New-MigrationAccountCredential -UserName $MigrationAccountUserName
$vmNames = Resolve-VMNameList -Names $VMName -Path $VMListPath
$summary = @()

Write-Log -Message ("Connecting to SCVMM server {0}." -f $VMMServer)
$vmmServerObject = Get-SCVMMServer -ComputerName $VMMServer -Credential $SCVMMCredential -ErrorAction Stop

foreach ($name in $vmNames) {
    $vlanSet = $false
    $ipConfigured = $false
    $status = 'Success'

    Write-Log -Message ("Processing VM '{0}'." -f $name)

    try {
        $migrationData = Get-MigrationData -Name $name -Directory $DataDirectory
        Write-Log -Message ("Loaded migration data from '{0}'." -f $migrationData.Path)

        $scVm = Get-SCVirtualMachineStrict -Name $name -VMMServerObject $vmmServerObject
        $hostName = Get-SCVmHostName -SCVirtualMachine $scVm
        Write-Log -Message ("SCVMM reports VM '{0}' on Hyper-V host '{1}'." -f $name, $hostName)

        $scAdapters = @(Get-SCVirtualNetworkAdaptersForVM -SCVirtualMachine $scVm)
        $hyperVAdapters = @(Get-HyperVNetworkAdapters -HostName $hostName -Name $name -Credential $HostCredential)

        $vlanFailures = @()
        foreach ($nicRecord in @($migrationData.FrontSideNics)) {
            $hyperVAdapter = Find-HyperVAdapterForNic -HyperVAdapters $hyperVAdapters -NicRecord $nicRecord -ProductionSwitchName $ProductionSwitchName -FrontSideNicCount $migrationData.FrontSideNics.Count
            if ($hyperVAdapter) {
                Write-Log -Message ("Matched Hyper-V adapter '{0}' on switch '{1}' for VM '{2}'." -f $hyperVAdapter.Name, $hyperVAdapter.SwitchName, $name)
                if ($hyperVAdapter.SwitchName -ne $ProductionSwitchName) {
                    Write-Log -Level WARN -Message ("Hyper-V adapter '{0}' is connected to '{1}', expected '{2}'." -f $hyperVAdapter.Name, $hyperVAdapter.SwitchName, $ProductionSwitchName)
                    if (-not $DisableHyperVFallback) {
                        Ensure-HyperVAdapterSwitch -HostName $hostName -Name $name -AdapterName $hyperVAdapter.Name -ProductionSwitchName $ProductionSwitchName -Credential $HostCredential
                        Write-Log -Message ("Connected Hyper-V adapter '{0}' to switch '{1}'." -f $hyperVAdapter.Name, $ProductionSwitchName)
                    }
                }
            }
            else {
                Write-Log -Level WARN -Message ("Unable to match a Hyper-V virtual NIC for VM '{0}' and target IP '{1}'." -f $name, $nicRecord.IPAddress)
            }

            $scAdapter = Find-SCVirtualAdapterForNic -SCAdapters $scAdapters -NicRecord $nicRecord -HyperVAdapter $hyperVAdapter -FrontSideNicCount $migrationData.FrontSideNics.Count
            if ($scAdapter) {
                $networkConfirmed = Confirm-SCVirtualAdapterNetwork -Adapter $scAdapter -PortGroupName $nicRecord.PortGroupName -VMMServerObject $vmmServerObject
                if (-not $networkConfirmed) {
                    Write-Log -Level WARN -Message ("Could not confirm or set SCVMM network '{0}' on adapter '{1}'." -f $nicRecord.PortGroupName, $scAdapter.Name)
                }

                try {
                    Set-SCVirtualAdapterVlan -Adapter $scAdapter -VlanId $nicRecord.VLANID
                    Write-Log -Message ("Set SCVMM VLAN '{0}' on adapter '{1}' for VM '{2}'." -f $nicRecord.VLANID, $scAdapter.Name, $name)
                    $vlanSet = $true
                }
                catch {
                    Write-Log -Level WARN -Message ("SCVMM VLAN set failed for adapter '{0}' on VM '{1}': {2}" -f $scAdapter.Name, $name, $_.Exception.Message)
                    $vlanFailures += $_.Exception.Message

                    if (-not $DisableHyperVFallback -and $hyperVAdapter) {
                        Set-HyperVAdapterVlan -HostName $hostName -Name $name -AdapterName $hyperVAdapter.Name -VlanId $nicRecord.VLANID -Credential $HostCredential
                        Write-Log -Message ("Set Hyper-V VLAN '{0}' on adapter '{1}' for VM '{2}'." -f $nicRecord.VLANID, $hyperVAdapter.Name, $name)
                        $vlanSet = $true
                    }
                }
            }
            elseif (-not $DisableHyperVFallback -and $hyperVAdapter) {
                Write-Log -Level WARN -Message ("No SCVMM adapter match was found for VM '{0}'. Applying VLAN by Hyper-V cmdlet fallback." -f $name)
                Set-HyperVAdapterVlan -HostName $hostName -Name $name -AdapterName $hyperVAdapter.Name -VlanId $nicRecord.VLANID -Credential $HostCredential
                Write-Log -Message ("Set Hyper-V VLAN '{0}' on adapter '{1}' for VM '{2}'." -f $nicRecord.VLANID, $hyperVAdapter.Name, $name)
                $vlanSet = $true
            }
            else {
                throw ("Unable to identify a SCVMM virtual NIC for VM '{0}' target IP '{1}'." -f $name, $nicRecord.IPAddress)
            }
        }

        Write-Log -Message ("Configuring guest NIC settings for VM '{0}' through PowerShell Direct on host '{1}'." -f $name, $hostName)
        $guestResults = @(Invoke-GuestNicConfiguration -HostName $hostName -Name $name -FrontSideNics $migrationData.FrontSideNics -GuestCredential $guestCredential -Credential $HostCredential)
        foreach ($guestResult in $guestResults) {
            $level = if ($guestResult.Success) { 'INFO' } else { 'ERROR' }
            Write-Log -Level $level -Message ("Guest NIC result for VM '{0}': Adapter='{1}' IP='{2}' Success='{3}' Message='{4}'" -f $name, $guestResult.AdapterName, $guestResult.IPAddress, $guestResult.Success, $guestResult.Message)
        }

        $failedGuestResults = @($guestResults | Where-Object { -not $_.Success })
        if ($failedGuestResults.Count -gt 0) {
            throw ("One or more guest NIC configurations failed for VM '{0}'." -f $name)
        }

        $ipConfigured = $true

        if (-not $vlanSet) {
            throw ("VLAN was not set for VM '{0}'." -f $name)
        }
    }
    catch {
        $status = 'Failed: {0}' -f $_.Exception.Message
        Write-Log -Level ERROR -Message ("Failed processing VM '{0}': {1}" -f $name, $_.Exception.Message)
    }

    $summary += [pscustomobject]@{
        VMName       = $name
        VLANSet     = $vlanSet
        IPConfigured = $ipConfigured
        Status       = $status
    }
}

$summaryText = $summary | Format-Table -AutoSize | Out-String
Write-Host $summaryText
Add-Content -Path $script:LogPath -Value ''
Add-Content -Path $script:LogPath -Value 'Summary'
Add-Content -Path $script:LogPath -Value $summaryText

Write-Log -Message 'Post-migration Hyper-V NIC configuration complete.'
