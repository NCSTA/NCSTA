#Requires -Version 5.1
<#
.SYNOPSIS
    Server QA data collection module.
.DESCRIPTION
    Collects server configuration data via Invoke-Command for QA validation.
    Returns structured PSCustomObject results instead of raw text.
#>

function New-QaCheckResult {
    param(
        [bool]$Success,
        [object]$Data,
        [string]$ErrorMessage
    )
    [PSCustomObject]@{
        Success      = $Success
        Data         = $Data
        ErrorMessage = $ErrorMessage
    }
}

function Get-QaServerData {
    <#
    .SYNOPSIS
        Collects all QA-relevant data from a remote server.
    .PARAMETER ComputerName
        The server hostname or FQDN.
    .PARAMETER TracerouteTarget
        Target hostname for traceroute check. Defaults to DOMAIN1.REDACTED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [string]$TracerouteTarget = 'DOMAIN1.REDACTED'
    )

    $result = [PSCustomObject]@{
        ComputerName = $ComputerName
        CollectedAt  = Get-Date
        Connectivity = $null
        Cpu          = $null
        MemoryGB     = $null
        Software     = $null
        IpConfig     = $null
        LocalAdmins  = $null
        Hotfixes     = $null
        DrivePerms   = $null
        FDrive       = $null
        Traceroute   = $null
        VMwareTools  = $null
        OuPath       = $null
    }

    # --- Step 1: Connectivity check (local) ---
    try {
        $ping = Test-Connection -ComputerName $ComputerName -Count 2 -Quiet
        $result.Connectivity = New-QaCheckResult -Success $true -Data $ping -ErrorMessage $null
    }
    catch {
        $result.Connectivity = New-QaCheckResult -Success $false -Data $false -ErrorMessage $_.Exception.Message
    }

    if (-not $result.Connectivity.Data) {
        # Server unreachable - mark all remote checks as failed
        $unreachableMsg = "Server $ComputerName is not reachable"
        $result.Cpu         = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.MemoryGB    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.Software    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.IpConfig    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.LocalAdmins = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.Hotfixes    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.DrivePerms  = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.FDrive      = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.Traceroute  = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
        $result.VMwareTools = New-QaCheckResult -Success $false -Data $null -ErrorMessage $unreachableMsg
    }
    else {
        # --- Step 2: Single Invoke-Command for all remote checks ---
        try {
            $remoteData = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                param($TraceTarget)

                $output = @{}

                # CPU count
                try {
                    $cpuCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
                    $output['Cpu'] = @{ Success = $true; Data = $cpuCount; ErrorMessage = $null }
                }
                catch {
                    $output['Cpu'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # Memory
                try {
                    $memBytes = (Get-WmiObject -Class Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
                    $memGB = [math]::Round($memBytes / 1GB, 2)
                    $output['MemoryGB'] = @{ Success = $true; Data = $memGB; ErrorMessage = $null }
                }
                catch {
                    $output['MemoryGB'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # Installed software (64-bit + 32-bit, excluding Microsoft)
                try {
                    $software64 = Get-ChildItem -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                        Get-ItemProperty |
                        Where-Object { $_.DisplayName -and $_.DisplayName -notlike '*Microsoft*' } |
                        Select-Object @{N='Name';E={$_.DisplayName}},
                                      @{N='Version';E={$_.DisplayVersion}},
                                      @{N='Vendor';E={$_.Publisher}},
                                      @{N='InstallDate';E={$_.InstallDate}}

                    $software32 = Get-ChildItem -Path 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
                        Get-ItemProperty |
                        Where-Object { $_.DisplayName -and $_.DisplayName -notlike '*Microsoft*' } |
                        Select-Object @{N='Name';E={$_.DisplayName}},
                                      @{N='Version';E={$_.DisplayVersion}},
                                      @{N='Vendor';E={$_.Publisher}},
                                      @{N='InstallDate';E={$_.InstallDate}}

                    $allSoftware = @()
                    if ($software64) { $allSoftware += $software64 }
                    if ($software32) { $allSoftware += $software32 }
                    $allSoftware = $allSoftware | Sort-Object -Property Name, Version, Vendor, InstallDate -Unique

                    $output['Software'] = @{ Success = $true; Data = $allSoftware; ErrorMessage = $null }
                }
                catch {
                    $output['Software'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # IP configuration
                try {
                    $adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true }
                    $ipData = foreach ($adapter in $adapters) {
                        [PSCustomObject]@{
                            Description      = $adapter.Description
                            IPAddresses      = @($adapter.IPAddress)
                            NetBIOSValue     = $adapter.TcpipNetbiosOptions
                            NetBIOS          = switch ($adapter.TcpipNetbiosOptions) {
                                0 { 'Default' }
                                1 { 'Enabled' }
                                2 { 'Disabled' }
                                default { "Unknown ($($adapter.TcpipNetbiosOptions))" }
                            }
                            DnsServers       = @($adapter.DNSServerSearchOrder)
                        }
                    }
                    $output['IpConfig'] = @{ Success = $true; Data = @($ipData); ErrorMessage = $null }
                }
                catch {
                    $output['IpConfig'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # Local administrators
                try {
                    $localAdmins = Get-LocalGroupMember -Group 'Administrators' |
                        Select-Object Name, ObjectClass
                    $output['LocalAdmins'] = @{ Success = $true; Data = @($localAdmins); ErrorMessage = $null }
                }
                catch {
                    $output['LocalAdmins'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # Recent hotfixes (past 30 days)
                try {
                    $cutoff = (Get-Date).AddDays(-30)
                    $hotfixes = Get-HotFix | Where-Object { $_.InstalledOn -gt $cutoff } |
                        Select-Object HotFixID, Description, InstalledOn
                    $output['Hotfixes'] = @{ Success = $true; Data = @($hotfixes); ErrorMessage = $null }
                }
                catch {
                    $output['Hotfixes'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # Drive/mountpoint permissions - check for "Everyone" access on all volumes
                try {
                    $volumePerms = @()
                    # Get standard drive letters (fixed disks)
                    $drives = Get-WmiObject Win32_LogicalDisk -Filter "DriveType = 3"
                    foreach ($drive in $drives) {
                        try {
                            $acl = Get-Acl $drive.DeviceID
                            $everyoneAccess = $acl.Access | Where-Object { $_.IdentityReference -eq 'Everyone' }
                            $volumePerms += [PSCustomObject]@{
                                Path           = $drive.DeviceID
                                Type           = 'Drive'
                                EveryoneAccess = [bool]$everyoneAccess
                            }
                        } catch {
                            $volumePerms += [PSCustomObject]@{
                                Path           = $drive.DeviceID
                                Type           = 'Drive'
                                EveryoneAccess = $null
                            }
                        }
                    }
                    # Get mountpoints (volumes mounted to folders)
                    $mountPoints = Get-WmiObject Win32_MountPoint | ForEach-Object {
                        $dir = $_.Directory
                        if ($dir -match 'Win32_Directory.Name="(.+)"') {
                            $matches[1] -replace '\\\\', '\'
                        }
                    } | Where-Object { $_ -and $_ -notmatch '^[A-Z]:\\$' }
                    foreach ($mp in $mountPoints) {
                        try {
                            $acl = Get-Acl $mp
                            $everyoneAccess = $acl.Access | Where-Object { $_.IdentityReference -eq 'Everyone' }
                            $volumePerms += [PSCustomObject]@{
                                Path           = $mp
                                Type           = 'MountPoint'
                                EveryoneAccess = [bool]$everyoneAccess
                            }
                        } catch {
                            $volumePerms += [PSCustomObject]@{
                                Path           = $mp
                                Type           = 'MountPoint'
                                EveryoneAccess = $null
                            }
                        }
                    }
                    $output['DrivePerms'] = @{ Success = $true; Data = @($volumePerms); ErrorMessage = $null }
                }
                catch {
                    $output['DrivePerms'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # F: drive status
                try {
                    $fDrive = Get-Volume -DriveLetter F -ErrorAction Stop
                    $output['FDrive'] = @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            Exists       = $true
                            DriveLetter  = 'F'
                            FileSystem   = $fDrive.FileSystemType
                            SizeGB       = [math]::Round($fDrive.Size / 1GB, 2)
                            FreeSpaceGB  = [math]::Round($fDrive.SizeRemaining / 1GB, 2)
                            HealthStatus = $fDrive.HealthStatus
                        }
                        ErrorMessage = $null
                    }
                }
                catch {
                    $output['FDrive'] = @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            Exists      = $false
                            DriveLetter = 'F'
                        }
                        ErrorMessage = $null
                    }
                }

                # Traceroute
                try {
                    $trace = Test-NetConnection -ComputerName $TraceTarget -TraceRoute -WarningAction SilentlyContinue
                    $firstHop = if ($trace.TraceRoute -and $trace.TraceRoute.Count -gt 0) { $trace.TraceRoute[0] } else { $null }
                    $output['Traceroute'] = @{
                        Success = $true
                        Data    = [PSCustomObject]@{
                            Target    = $TraceTarget
                            Hops      = @($trace.TraceRoute)
                            HopCount  = $trace.TraceRoute.Count
                            FirstHop  = $firstHop
                            SourceIP  = $trace.SourceAddress.IPAddress
                            Reachable = $trace.PingSucceeded
                        }
                        ErrorMessage = $null
                    }
                }
                catch {
                    $output['Traceroute'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                # VMware Tools version (derived from software list)
                try {
                    $vmwareEntry = $output['Software'].Data | Where-Object { $_.Name -like '*VMware Tools*' } | Select-Object -First 1
                    if ($vmwareEntry) {
                        $output['VMwareTools'] = @{ Success = $true; Data = $vmwareEntry.Version; ErrorMessage = $null }
                    }
                    else {
                        $output['VMwareTools'] = @{ Success = $true; Data = 'Not Installed'; ErrorMessage = $null }
                    }
                }
                catch {
                    $output['VMwareTools'] = @{ Success = $false; Data = $null; ErrorMessage = $_.Exception.Message }
                }

                $output
            } -ArgumentList $TracerouteTarget

            # Unpack remote data into result
            $result.Cpu         = New-QaCheckResult -Success $remoteData['Cpu'].Success         -Data $remoteData['Cpu'].Data         -ErrorMessage $remoteData['Cpu'].ErrorMessage
            $result.MemoryGB    = New-QaCheckResult -Success $remoteData['MemoryGB'].Success    -Data $remoteData['MemoryGB'].Data    -ErrorMessage $remoteData['MemoryGB'].ErrorMessage
            $result.Software    = New-QaCheckResult -Success $remoteData['Software'].Success    -Data $remoteData['Software'].Data    -ErrorMessage $remoteData['Software'].ErrorMessage
            $result.IpConfig    = New-QaCheckResult -Success $remoteData['IpConfig'].Success    -Data $remoteData['IpConfig'].Data    -ErrorMessage $remoteData['IpConfig'].ErrorMessage
            $result.LocalAdmins = New-QaCheckResult -Success $remoteData['LocalAdmins'].Success -Data $remoteData['LocalAdmins'].Data -ErrorMessage $remoteData['LocalAdmins'].ErrorMessage
            $result.Hotfixes    = New-QaCheckResult -Success $remoteData['Hotfixes'].Success    -Data $remoteData['Hotfixes'].Data    -ErrorMessage $remoteData['Hotfixes'].ErrorMessage
            $result.DrivePerms  = New-QaCheckResult -Success $remoteData['DrivePerms'].Success  -Data $remoteData['DrivePerms'].Data  -ErrorMessage $remoteData['DrivePerms'].ErrorMessage
            $result.FDrive      = New-QaCheckResult -Success $remoteData['FDrive'].Success      -Data $remoteData['FDrive'].Data      -ErrorMessage $remoteData['FDrive'].ErrorMessage
            $result.Traceroute  = New-QaCheckResult -Success $remoteData['Traceroute'].Success  -Data $remoteData['Traceroute'].Data  -ErrorMessage $remoteData['Traceroute'].ErrorMessage
            $result.VMwareTools = New-QaCheckResult -Success $remoteData['VMwareTools'].Success -Data $remoteData['VMwareTools'].Data -ErrorMessage $remoteData['VMwareTools'].ErrorMessage
        }
        catch {
            $remoteError = "Invoke-Command failed: $($_.Exception.Message)"
            $result.Cpu         = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.MemoryGB    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.Software    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.IpConfig    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.LocalAdmins = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.Hotfixes    = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.DrivePerms  = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.FDrive      = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.Traceroute  = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
            $result.VMwareTools = New-QaCheckResult -Success $false -Data $null -ErrorMessage $remoteError
        }
    }

    # --- Step 3: OU path (local, via Get-ADComputer) ---
    try {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            $result.OuPath = New-QaCheckResult -Success $false -Data $null -ErrorMessage 'ActiveDirectory module not available (RSAT not installed)'
        }
        else {
            $shortName = ($ComputerName -split '\.')[0]
            $domainParts = ($ComputerName -split '\.')[1..99]
            $serverParam = @{}
            if ($domainParts.Count -gt 0) {
                $serverParam['Server'] = $domainParts -join '.'
            }
            $adComputer = Get-ADComputer -Identity $shortName -Properties CanonicalName, DistinguishedName @serverParam
            $result.OuPath = New-QaCheckResult -Success $true -Data ([PSCustomObject]@{
                Name              = $adComputer.Name
                CanonicalName     = $adComputer.CanonicalName
                DistinguishedName = $adComputer.DistinguishedName
            }) -ErrorMessage $null
        }
    }
    catch {
        $result.OuPath = New-QaCheckResult -Success $false -Data $null -ErrorMessage $_.Exception.Message
    }

    return $result
}

Export-ModuleMember -Function Get-QaServerData
