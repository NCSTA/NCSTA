<#
.SYNOPSIS
    Collects VMware VM configuration data for ESXi-to-Hyper-V migrations.

.DESCRIPTION
    Connects to vCenter with VMware PowerCLI, collects CPU, memory, and
    front-side Windows NIC configuration for one or more VMs, creates the
    temporary local migration account inside each guest through PowerShell remoting,
    and writes one JSON file per VM for the post-migration script.

    Back-side management NICs are excluded when any IPv4 address on the adapter
    matches 172.25.*.* or 169.*.*.*.

    Windows guest operations are pushed over PowerShell remoting to the FQDN
    supplied in the VM import list. The short host name before the first dot is
    used for PowerCLI lookups. The current console user is used by default;
    provide -GuestCredential only when you want Invoke-Command to use a
    different Windows administrator account for guest NIC discovery and local
    account creation.

.NOTES
    PowerShell 5.1 compatible.
    Requires VMware.PowerCLI.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMName,

    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VMListPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$vCenterServer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'C:\MigrationData',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = 'C:\MigrationLogs',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$MigrationAccountUserName = 'Hypervmigrate',

    [Parameter()]
    [System.Management.Automation.PSCredential]$vCenterCredential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [switch]$SkipMigrationAccountCreation,

    [Parameter()]
    [switch]$IgnoreInvalidCertificate
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
    $script:LogPath = Join-Path -Path $Directory -ChildPath ("Script1_{0}.log" -f $timestamp)
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
    Write-Information -MessageData $line -InformationAction Continue
    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $line
    }
}

function Resolve-VMImportEntry {
    param(
        [string[]]$Names,
        [string]$Path
    )

    if ($Names -and $Path) {
        throw 'Use either -VMName or -VMListPath, not both.'
    }

    if (-not $Names -and -not $Path) {
        $Path = Read-Host -Prompt 'Enter path to VM import file with one VM FQDN per line'
        if ([string]::IsNullOrWhiteSpace($Path)) {
            throw 'No VM import file path was supplied.'
        }
    }

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "VM import file was not found: $Path"
        }

        $Names = Get-Content -LiteralPath $Path | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimStart() -notlike '#*'
        } | ForEach-Object { $_.Trim() }
    }

    $resolved = @()
    foreach ($entry in @($Names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Select-Object -Unique)) {
        $shortName = ($entry -split '\.')[0]
        if ([string]::IsNullOrWhiteSpace($shortName)) {
            continue
        }

        $resolved += [pscustomobject]@{
            ImportName         = $entry
            VMName             = $shortName
            GuestComputerName  = $entry
        }
    }

    if ($resolved.Count -eq 0) {
        throw 'No VM import entries were supplied.'
    }

    return @($resolved)
}

function ConvertTo-PowerShellLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return '$null'
    }

    return "'{0}'" -f ($Value -replace "'", "''")
}

function Get-MigrationPasswordCodeLiteral {
    # Character codes for the fixed migration account password requested for this migration workflow.
    return '65,35,50,63,52,97,99,101,65,35,50,63,52,97,99,101'
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

function Get-NetworkMatchKey {
    param(
        [AllowNull()]
        [string]$NetworkName
    )

    if ([string]::IsNullOrWhiteSpace($NetworkName)) {
        return $null
    }

    $match = [regex]::Match($NetworkName, '\b\d{1,3}(?:\.\d{1,3}){2}\.(?:\d{1,3}|x)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return $match.Value.ToLowerInvariant()
    }

    return $NetworkName.Trim().ToLowerInvariant()
}

function Test-BackSideIPv4Address {
    param(
        [AllowNull()]
        [string]$IPAddress
    )

    if ([string]::IsNullOrWhiteSpace($IPAddress)) {
        return $false
    }

    return ($IPAddress -like '172.25.*' -or $IPAddress -like '169.*')
}

function ConvertTo-SubnetMask {
    param(
        [AllowNull()]
        [Nullable[int]]$PrefixLength
    )

    if ($null -eq $PrefixLength) {
        return $null
    }

    if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
        throw "Invalid IPv4 prefix length: $PrefixLength"
    }

    $mask = [uint32]0
    for ($i = 0; $i -lt $PrefixLength; $i++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $i))
    }

    $octets = New-Object byte[] 4
    $octets[0] = [byte](($mask -shr 24) -band 0xFF)
    $octets[1] = [byte](($mask -shr 16) -band 0xFF)
    $octets[2] = [byte](($mask -shr 8) -band 0xFF)
    $octets[3] = [byte]($mask -band 0xFF)

    return ($octets -join '.')
}

function ConvertFrom-GuestJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $trimmed = $Text.Trim()
    $arrayStart = $trimmed.IndexOf('[')
    $objectStart = $trimmed.IndexOf('{')

    if ($arrayStart -lt 0 -and $objectStart -lt 0) {
        throw "Guest script did not return JSON. Output: $trimmed"
    }

    if ($arrayStart -ge 0 -and ($objectStart -lt 0 -or $arrayStart -lt $objectStart)) {
        $start = $arrayStart
    }
    else {
        $start = $objectStart
    }

    $json = $trimmed.Substring($start)
    return $json | ConvertFrom-Json
}

function Expand-ObjectArray {
    param(
        [AllowNull()]
        $InputObject
    )

    $items = @()
    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [System.Array]) {
            $items += @(Expand-ObjectArray -InputObject $item)
            continue
        }

        $items += $item
    }

    return @($items)
}

function Invoke-GuestPowerShellRemoting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$ScriptText,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptBlock = [scriptblock]::Create($ScriptText)

    if ($Credential) {
        return Invoke-Command -ComputerName $ComputerName -Credential $Credential -ScriptBlock $scriptBlock -ErrorAction Stop
    }

    return Invoke-Command -ComputerName $ComputerName -ScriptBlock $scriptBlock -ErrorAction Stop
}

function Get-GuestNetworkDiscoveryScript {
    return @'
$ErrorActionPreference = 'Stop'
$items = @()

$adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.MacAddress })

foreach ($adapter in $adapters) {
    $ipv4Items = @()
    $defaultGateway = $null
    $dnsServers = @()
    $registerDnsClient = $null
    $primaryAddress = $null
    $primaryPrefix = $null

    $ipv4 = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike '127.*' } |
        Sort-Object -Property PrefixOrigin, SuffixOrigin, IPAddress)

    foreach ($address in $ipv4) {
        $ipv4Items += [pscustomobject]@{
            IPAddress     = $address.IPAddress
            PrefixLength  = [int]$address.PrefixLength
            PrefixOrigin  = [string]$address.PrefixOrigin
            AddressState  = [string]$address.AddressState
        }
    }

    $firstUsable = @($ipv4 | Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -notlike '172.25.*' } | Select-Object -First 1)
    if ($firstUsable.Count -gt 0) {
        $primaryAddress = $firstUsable[0].IPAddress
        $primaryPrefix = [int]$firstUsable[0].PrefixLength
    }
    elseif ($ipv4.Count -gt 0) {
        $primaryAddress = $ipv4[0].IPAddress
        $primaryPrefix = [int]$ipv4[0].PrefixLength
    }

    try {
        $ipConfig = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
        if ($ipConfig.IPv4DefaultGateway) {
            $defaultGateway = @($ipConfig.IPv4DefaultGateway | Select-Object -ExpandProperty NextHop | Select-Object -First 1)[0]
        }
    }
    catch {
        $defaultGateway = $null
    }

    try {
        $dnsConfig = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop
        $dnsServers = @($dnsConfig.ServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        $dnsServers = @()
    }

    try {
        $dnsClient = Get-DnsClient -InterfaceIndex $adapter.ifIndex -ErrorAction Stop
        $registerDnsClient = [bool]$dnsClient.RegisterThisConnectionsAddress
    }
    catch {
        $registerDnsClient = $null
    }

    $items += [pscustomobject]@{
        AdapterName        = $adapter.Name
        InterfaceAlias     = $adapter.Name
        InterfaceIndex     = [int]$adapter.ifIndex
        InterfaceGuid      = [string]$adapter.InterfaceGuid
        InterfaceDescription = $adapter.InterfaceDescription
        MacAddress         = $adapter.MacAddress
        Status             = [string]$adapter.Status
        LinkSpeed          = [string]$adapter.LinkSpeed
        PrimaryIPAddress   = $primaryAddress
        PrefixLength       = $primaryPrefix
        DefaultGateway     = $defaultGateway
        DNSServers         = @($dnsServers)
        RegisterDnsClient  = $registerDnsClient
        IPv4Addresses      = @($ipv4Items)
    }
}

ConvertTo-Json -InputObject @($items) -Depth 6 -Compress
'@
}

function Get-GuestNetworkInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential
    )

    $scriptText = Get-GuestNetworkDiscoveryScript
    $result = Invoke-GuestPowerShellRemoting -ComputerName $ComputerName -Credential $Credential -ScriptText $scriptText
    $outputText = (@($result) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    return @(Expand-ObjectArray -InputObject (ConvertFrom-GuestJson -Text $outputText))
}

function Get-GuestNetworkInfoFromVmInventory {
    param(
        [Parameter(Mandatory = $true)]
        $VM
    )

    $guestNics = @()
    $guestNet = @($VM.ExtensionData.Guest.Net)

    foreach ($net in $guestNet) {
        $ipv4Items = @()
        $ipv4Addresses = @($net.IpAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })

        foreach ($address in $ipv4Addresses) {
            $ipv4Items += [pscustomobject]@{
                IPAddress     = $address
                PrefixLength  = $null
                PrefixOrigin  = $null
                AddressState  = $null
            }
        }

        $primaryAddress = @($ipv4Addresses | Where-Object { -not (Test-BackSideIPv4Address -IPAddress $_) } | Select-Object -First 1)
        if ($primaryAddress.Count -eq 0 -and $ipv4Addresses.Count -gt 0) {
            $primaryAddress = @($ipv4Addresses | Select-Object -First 1)
        }

        $guestNics += [pscustomobject]@{
            AdapterName        = $net.Network
            InterfaceAlias     = $net.Network
            InterfaceIndex     = $null
            InterfaceGuid      = $null
            InterfaceDescription = $null
            MacAddress         = $net.MacAddress
            Status             = $null
            LinkSpeed          = $null
            PrimaryIPAddress   = if ($primaryAddress.Count -gt 0) { $primaryAddress[0] } else { $null }
            PrefixLength       = $null
            DefaultGateway     = $null
            DNSServers         = @()
            RegisterDnsClient  = $null
            IPv4Addresses      = @($ipv4Items)
        }
    }

    return @($guestNics)
}

function Get-PortGroupVlanSpecText {
    param(
        [AllowNull()]
        $VlanSpec
    )

    if ($null -eq $VlanSpec) {
        return $null
    }

    $properties = $VlanSpec.PSObject.Properties.Name
    if ($properties -contains 'VlanId') {
        $vlanId = $VlanSpec.VlanId
        if ($vlanId -is [System.Array]) {
            return ($vlanId | ForEach-Object { $_.ToString() }) -join ','
        }

        return [string]$vlanId
    }

    if ($properties -contains 'PvlanId') {
        return [string]$VlanSpec.PvlanId
    }

    return $VlanSpec.GetType().Name
}

function Get-PortGroupVlanId {
    param(
        [Parameter(Mandatory = $true)]
        $NetworkAdapter,

        [Parameter(Mandatory = $true)]
        $VMHost
    )

    $networkName = $NetworkAdapter.NetworkName
    $vlanId = $null
    $portGroupType = $null
    $vlanDescription = $null

    try {
        $backing = $NetworkAdapter.ExtensionData.Backing
        $backingHasPort = ($backing -and ($backing.PSObject.Properties.Name -contains 'Port') -and $backing.Port)
        if ($backingHasPort -and ($backing.Port.PSObject.Properties.Name -contains 'PortgroupKey') -and $backing.Port.PortgroupKey) {
            $portGroupKey = [string]$backing.Port.PortgroupKey
            $pgView = Get-View -ViewType DistributedVirtualPortgroup -Property Name,Key,Config -Filter @{ 'Key' = $portGroupKey } -ErrorAction Stop | Select-Object -First 1
            if ($pgView) {
                $networkName = $pgView.Name
                $portGroupType = 'Distributed'
                $vlanSpec = $pgView.Config.DefaultPortConfig.Vlan
                $vlanDescription = Get-PortGroupVlanSpecText -VlanSpec $vlanSpec
                if ($vlanSpec -and ($vlanSpec.PSObject.Properties.Name -contains 'VlanId') -and -not ($vlanSpec.VlanId -is [System.Array])) {
                    $vlanId = [int]$vlanSpec.VlanId
                }
            }
        }
    }
    catch {
        Write-Log -Level WARN -Message ("Unable to resolve distributed port group VLAN for adapter '{0}': {1}" -f $NetworkAdapter.Name, $_.Exception.Message)
    }

    if ($null -eq $vlanId -and [string]::IsNullOrWhiteSpace($portGroupType)) {
        try {
            $standardPortGroup = Get-VirtualPortGroup -VMHost $VMHost -Name $NetworkAdapter.NetworkName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($standardPortGroup) {
                $networkName = $standardPortGroup.Name
                $portGroupType = 'Standard'
                $vlanId = [int]$standardPortGroup.VLanId
                $vlanDescription = [string]$standardPortGroup.VLanId
            }
        }
        catch {
            Write-Log -Level WARN -Message ("Unable to resolve standard port group VLAN for adapter '{0}': {1}" -f $NetworkAdapter.Name, $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        PortGroupName   = $networkName
        PortGroupType   = $portGroupType
        VLANID          = $vlanId
        VlanDescription = $vlanDescription
    }
}

function Get-FirstNonBackSideIPv4Entry {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic
    )

    $entries = @($GuestNic.IPv4Addresses)
    foreach ($entry in $entries) {
        $ip = $entry.IPAddress
        if (-not [string]::IsNullOrWhiteSpace($ip) -and -not (Test-BackSideIPv4Address -IPAddress $ip)) {
            return $entry
        }
    }

    return $null
}

function Get-FirstBackSideIPv4Entry {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic
    )

    $entries = @($GuestNic.IPv4Addresses)
    foreach ($entry in $entries) {
        $ip = $entry.IPAddress
        if (-not [string]::IsNullOrWhiteSpace($ip) -and (Test-BackSideIPv4Address -IPAddress $ip)) {
            return $entry
        }
    }

    return $null
}

function Test-GuestNicIsFrontSide {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic
    )

    return ($null -ne (Get-FirstNonBackSideIPv4Entry -GuestNic $GuestNic))
}

function Test-GuestNicIsBackSide {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic
    )

    return ($null -ne (Get-FirstBackSideIPv4Entry -GuestNic $GuestNic))
}

function Resolve-GuestNetworkAdapterMatch {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic,

        [Parameter(Mandatory = $true)]
        [object[]]$VMAdapters
    )

    $guestMac = ConvertTo-NormalizedMacAddress -MacAddress $GuestNic.MacAddress
    $matchingAdapter = $null
    if ($guestMac) {
        $matchingAdapter = @($VMAdapters | Where-Object {
            (ConvertTo-NormalizedMacAddress -MacAddress $_.MacAddress) -eq $guestMac
        } | Select-Object -First 1)
        if ($matchingAdapter.Count -gt 0) {
            return $matchingAdapter[0]
        }
    }

    if ($GuestNic.AdapterName) {
        $matchingAdapter = @($VMAdapters | Where-Object { $_.NetworkName -eq $GuestNic.AdapterName } | Select-Object -First 1)
        if ($matchingAdapter.Count -gt 0) {
            return $matchingAdapter[0]
        }
    }

    return $null
}

function ConvertTo-NicRecord {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic,

        [Parameter()]
        $NetworkAdapter,

        [Parameter(Mandatory = $true)]
        $VMHost,

        [Parameter(Mandatory = $true)]
        $AddressEntry,

        [Parameter(Mandatory = $true)]
        [string]$InterfaceRole
    )

    if ($null -eq $AddressEntry) {
        return $null
    }

    $prefixLength = $null
    if ($null -ne $AddressEntry.PrefixLength -and $AddressEntry.PrefixLength -ne '') {
        $prefixLength = [int]$AddressEntry.PrefixLength
    }

    $subnetMask = ConvertTo-SubnetMask -PrefixLength $prefixLength
    $portGroupInfo = $null
    if ($NetworkAdapter) {
        $portGroupInfo = Get-PortGroupVlanId -NetworkAdapter $NetworkAdapter -VMHost $VMHost
    }

    $macAddress = if ($NetworkAdapter) { $NetworkAdapter.MacAddress } else { $GuestNic.MacAddress }
    $portGroupName = if ($portGroupInfo) { $portGroupInfo.PortGroupName } else { $GuestNic.AdapterName }
    $vlanId = if ($portGroupInfo) { $portGroupInfo.VLANID } else { $null }
    $portGroupType = if ($portGroupInfo) { $portGroupInfo.PortGroupType } else { $null }
    $vlanDescription = if ($portGroupInfo) { $portGroupInfo.VlanDescription } else { $null }
    $virtualAdapterName = if ($NetworkAdapter) { $NetworkAdapter.Name } else { $null }
    $networkMatchKey = Get-NetworkMatchKey -NetworkName $portGroupName

    return [ordered]@{
        InterfaceRole        = $InterfaceRole
        AdapterName          = $GuestNic.AdapterName
        InterfaceAlias       = $GuestNic.InterfaceAlias
        InterfaceIndex       = $GuestNic.InterfaceIndex
        InterfaceGuid        = $GuestNic.InterfaceGuid
        InterfaceDescription = $GuestNic.InterfaceDescription
        VirtualAdapterName   = $virtualAdapterName
        MacAddress           = $macAddress
        IPAddress            = $AddressEntry.IPAddress
        IPv4Addresses        = @($GuestNic.IPv4Addresses)
        PrefixLength         = $prefixLength
        SubnetMask           = $subnetMask
        DefaultGateway       = $GuestNic.DefaultGateway
        DNSServers           = @($GuestNic.DNSServers)
        RegisterDnsClient    = $GuestNic.RegisterDnsClient
        PortGroupName        = $portGroupName
        NetworkMatchKey      = $networkMatchKey
        PortGroupType        = $portGroupType
        VLANID               = $vlanId
        VlanDescription      = $vlanDescription
    }
}

function ConvertTo-FrontSideNicRecord {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic,

        [Parameter()]
        $NetworkAdapter,

        [Parameter(Mandatory = $true)]
        $VMHost
    )

    $primary = Get-FirstNonBackSideIPv4Entry -GuestNic $GuestNic
    if ($null -eq $primary) {
        return $null
    }

    return ConvertTo-NicRecord -GuestNic $GuestNic -NetworkAdapter $NetworkAdapter -VMHost $VMHost -AddressEntry $primary -InterfaceRole 'FrontSide'
}

function ConvertTo-BackSideNicRecord {
    param(
        [Parameter(Mandatory = $true)]
        $GuestNic,

        [Parameter()]
        $NetworkAdapter,

        [Parameter(Mandatory = $true)]
        $VMHost
    )

    $primary = Get-FirstBackSideIPv4Entry -GuestNic $GuestNic
    if ($null -eq $primary) {
        return $null
    }

    return ConvertTo-NicRecord -GuestNic $GuestNic -NetworkAdapter $NetworkAdapter -VMHost $VMHost -AddressEntry $primary -InterfaceRole 'BackSide'
}

function Get-FrontSideNicRecord {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [object[]]$GuestNics
    )

    $vmAdapters = @(Get-NetworkAdapter -VM $VM -ErrorAction Stop)
    $records = @()

    foreach ($guestNic in @(Expand-ObjectArray -InputObject $GuestNics)) {
        if (-not (Test-GuestNicIsFrontSide -GuestNic $guestNic)) {
            $skippedAddresses = @($guestNic.IPv4Addresses | ForEach-Object { $_.IPAddress } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ','
            Write-Log -Message ("Skipping guest NIC '{0}' MAC '{1}' because no usable front-side IPv4 address was found. IPv4='{2}'." -f $guestNic.AdapterName, $guestNic.MacAddress, $skippedAddresses)
            continue
        }

        $matchingAdapter = Resolve-GuestNetworkAdapterMatch -GuestNic $guestNic -VMAdapters $vmAdapters
        $record = ConvertTo-FrontSideNicRecord -GuestNic $guestNic -NetworkAdapter $matchingAdapter -VMHost $VM.VMHost
        if ($record) {
            $records += $record
        }
    }

    return @($records)
}

function Get-BackSideNicRecord {
    param(
        [Parameter(Mandatory = $true)]
        $VM,

        [Parameter(Mandatory = $true)]
        [object[]]$GuestNics
    )

    $vmAdapters = @(Get-NetworkAdapter -VM $VM -ErrorAction Stop)
    $records = @()

    foreach ($guestNic in @(Expand-ObjectArray -InputObject $GuestNics)) {
        if (-not (Test-GuestNicIsBackSide -GuestNic $guestNic)) {
            continue
        }

        $matchingAdapter = Resolve-GuestNetworkAdapterMatch -GuestNic $guestNic -VMAdapters $vmAdapters
        $record = ConvertTo-BackSideNicRecord -GuestNic $guestNic -NetworkAdapter $matchingAdapter -VMHost $VM.VMHost
        if ($record) {
            $records += $record
        }
    }

    return @($records)
}

function Get-MigrationLocalAccountScriptText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    $template = @'
$ErrorActionPreference = 'Stop'
$userName = __USER_NAME__
$passwordCharCodes = @(__PASSWORD_CHAR_CODES__)
$securePassword = New-Object System.Security.SecureString
foreach ($passwordCharCode in $passwordCharCodes) {
    $securePassword.AppendChar([char]$passwordCharCode)
}
$securePassword.MakeReadOnly()

if (Get-Command -Name Get-LocalUser -ErrorAction SilentlyContinue) {
    $existingUser = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
    if ($existingUser) {
        Set-LocalUser -Name $userName -Password $securePassword -PasswordNeverExpires $true -ErrorAction Stop
        Enable-LocalUser -Name $userName -ErrorAction SilentlyContinue
    }
    else {
        New-LocalUser -Name $userName -Password $securePassword -FullName 'Hyper-V Migration Account' -Description 'VMware to Hyper-V migration' -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
    }

    $member = Get-LocalGroupMember -Group 'Administrators' -Member $userName -ErrorAction SilentlyContinue
    if (-not $member) {
        Add-LocalGroupMember -Group 'Administrators' -Member $userName -ErrorAction Stop
    }
}
else {
    $passwordPlain = -join ([char[]]$passwordCharCodes)
    $computer = [ADSI]("WinNT://{0},computer" -f $env:COMPUTERNAME)
    $userPath = "WinNT://{0}/{1},user" -f $env:COMPUTERNAME, $userName
    $memberPath = "WinNT://{0}/{1}" -f $env:COMPUTERNAME, $userName
    $userExists = $true
    try {
        $user = [ADSI]$userPath
        [void]$user.Name
    }
    catch {
        $userExists = $false
    }

    if (-not $userExists) {
        $user = $computer.Create('user', $userName)
    }

    $user.SetPassword($passwordPlain)
    $user.SetInfo()
    $user.UserFlags = $user.UserFlags -bor 0x10000
    $user.SetInfo()

    $group = [ADSI]("WinNT://{0}/Administrators,group" -f $env:COMPUTERNAME)
    $isMember = $false
    foreach ($memberObject in @($group.psbase.Invoke('Members'))) {
        $memberName = $memberObject.GetType().InvokeMember('Name', 'GetProperty', $null, $memberObject, $null)
        if ($memberName -ieq $userName) {
            $isMember = $true
            break
        }
    }

    if (-not $isMember) {
        $group.Add($memberPath)
    }
}

'Migration account ready'
'@

    return $template.
        Replace('__USER_NAME__', (ConvertTo-PowerShellLiteral -Value $UserName)).
        Replace('__PASSWORD_CHAR_CODES__', (Get-MigrationPasswordCodeLiteral))
}

function Invoke-MigrationLocalAccountSetup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter(Mandatory = $true)]
        [string]$UserName
    )

    $scriptText = Get-MigrationLocalAccountScriptText -UserName $UserName
    $result = Invoke-GuestPowerShellRemoting -ComputerName $ComputerName -Credential $Credential -ScriptText $scriptText
    return ((@($result) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Write-MigrationDataFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$MigrationData,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    Initialize-Directory -Path $Directory
    $fileName = '{0}_MigrationData.json' -f $MigrationData.VMName
    $path = Join-Path -Path $Directory -ChildPath $fileName
    $MigrationData | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    return $path
}

Initialize-Log -Directory $LogDirectory
Initialize-Directory -Path $OutputDirectory

Write-Log -Message 'Starting VMware pre-migration data collection.'
Write-Log -Message ("Output directory: {0}" -f $OutputDirectory)
Write-Log -Message ("Log file: {0}" -f $script:LogPath)

try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
}
catch {
    Write-Log -Level ERROR -Message ("VMware.PowerCLI could not be imported: {0}" -f $_.Exception.Message)
    throw
}

if ($IgnoreInvalidCertificate) {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
}

if (-not $vCenterCredential) {
    $vCenterCredential = Get-Credential -Message ("Enter credentials for vCenter '{0}'" -f $vCenterServer)
}

$vmImports = Resolve-VMImportEntry -Names $VMName -Path $VMListPath
$summary = @()
$viServerConnection = $null

try {
    Write-Log -Message ("Connecting to vCenter server {0}." -f $vCenterServer)
    $viServerConnection = Connect-VIServer -Server $vCenterServer -Credential $vCenterCredential -ErrorAction Stop

    foreach ($vmImport in $vmImports) {
        $name = $vmImport.VMName
        $guestComputerName = $vmImport.GuestComputerName
        $jsonPath = $null
        $accountCreated = $false
        $nicCount = 0
        $backSideNics = @()
        $status = 'Success'

        Write-Log -Message ("Processing import entry '{0}' as vCenter VM '{1}' and guest computer '{2}'." -f $vmImport.ImportName, $name, $guestComputerName)

        try {
            $vmMatches = @(Get-VM -Name $name -ErrorAction Stop | Where-Object { $_.Name -eq $name })
            if ($vmMatches.Count -eq 0) {
                throw "VM '$name' was not found in vCenter for import entry '$($vmImport.ImportName)'."
            }

            if ($vmMatches.Count -gt 1) {
                throw "More than one VM named '$name' was found in vCenter for import entry '$($vmImport.ImportName)'."
            }

            $vm = $vmMatches[0]

            $guestNics = @()
            try {
                Write-Log -Message ("Collecting guest NIC details from '{0}' through PowerShell remoting." -f $guestComputerName)
                $guestNics = @(Get-GuestNetworkInfo -ComputerName $guestComputerName -Credential $GuestCredential)
            }
            catch {
                Write-Log -Level WARN -Message ("Guest NIC discovery through PowerShell remoting failed for '{0}': {1}" -f $guestComputerName, $_.Exception.Message)
                Write-Log -Level WARN -Message ("Falling back to VMware Tools inventory data for '{0}'. Gateway, DNS, subnet mask, and RegisterDnsClient may be incomplete." -f $vm.Name)
                $guestNics = @(Get-GuestNetworkInfoFromVmInventory -VM $vm)
            }

            $frontSideNics = @(Get-FrontSideNicRecord -VM $vm -GuestNics $guestNics)
            $backSideNics = @(Get-BackSideNicRecord -VM $vm -GuestNics $guestNics)
            $nicCount = $frontSideNics.Count

            if ($nicCount -eq 0) {
                Write-Log -Level WARN -Message ("No front-side NICs were detected for '{0}' after excluding 172.25.*.* and 169.*.*.* addresses." -f $vm.Name)
            }

            Write-Log -Message ("Detected {0} front-side NIC record(s) and {1} back-side NIC record(s) for '{2}'." -f $frontSideNics.Count, $backSideNics.Count, $vm.Name)

            if (-not $SkipMigrationAccountCreation) {
                Write-Log -Message ("Creating or updating local migration account '{0}' on '{1}'." -f $MigrationAccountUserName, $guestComputerName)
                $accountResult = Invoke-MigrationLocalAccountSetup -ComputerName $guestComputerName -Credential $GuestCredential -UserName $MigrationAccountUserName
                Write-Log -Message ("Guest account result for '{0}': {1}" -f $guestComputerName, $accountResult)
                $accountCreated = $true
            }
            else {
                Write-Log -Level WARN -Message ("Skipping migration account creation on '{0}' because -SkipMigrationAccountCreation was specified." -f $guestComputerName)
            }

            $migrationData = [ordered]@{
                SchemaVersion    = '1.0'
                CollectedAt      = (Get-Date).ToString('o')
                VMName           = $vm.Name
                CPUCount         = [int]$vm.NumCpu
                MemoryMB         = [int]$vm.MemoryMB
                Source           = [ordered]@{
                    vCenterServer = $vCenterServer
                    VMHost        = $vm.VMHost.Name
                    PowerState    = [string]$vm.PowerState
                    ImportName    = $vmImport.ImportName
                    GuestComputerName = $guestComputerName
                }
                MigrationAccount = [ordered]@{
                    UserName = $MigrationAccountUserName
                    CreatedOrUpdated = [bool]$accountCreated
                }
                FrontInterface   = @($frontSideNics)
                BackSideInterface = @($backSideNics)
                BackSideNics     = @($backSideNics)
                FrontSideNics    = @($frontSideNics)
            }

            $jsonPath = Write-MigrationDataFile -MigrationData $migrationData -Directory $OutputDirectory
            Write-Log -Message ("Wrote migration data for '{0}' to '{1}'." -f $vm.Name, $jsonPath)
        }
        catch {
            $status = 'Failed: {0}' -f $_.Exception.Message
            Write-Log -Level ERROR -Message ("Failed processing VM '{0}': {1}" -f $name, $_.Exception.Message)
        }

        $summary += [pscustomobject]@{
            VMName                 = $name
            GuestComputerName      = $guestComputerName
            FrontSideNicCount      = $nicCount
            BackSideNicCount       = if ($null -ne $backSideNics) { $backSideNics.Count } else { 0 }
            MigrationAccountReady  = $accountCreated
            JsonPath               = $jsonPath
            Status                 = $status
        }
    }
}
finally {
    if ($viServerConnection) {
        Write-Log -Message ("Disconnecting from vCenter server {0}." -f $vCenterServer)
        Disconnect-VIServer -Server $viServerConnection -Confirm:$false | Out-Null
    }
}

$summaryText = $summary | Format-Table -AutoSize | Out-String
Write-Information -MessageData $summaryText -InformationAction Continue
Add-Content -Path $script:LogPath -Value ''
Add-Content -Path $script:LogPath -Value 'Summary'
Add-Content -Path $script:LogPath -Value $summaryText

Write-Log -Message 'VMware pre-migration data collection complete.'
