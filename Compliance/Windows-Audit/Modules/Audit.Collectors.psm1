Set-StrictMode -Version Latest

function Get-CimRecord {
    <# CIM is used in place of the VBS WMI moniker; errors are logged and the audit continues. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$ClassName, [string]$Filter)

    try {
        if ($Filter) { return @(Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop) }
        return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
    }
    catch {
        Write-AuditError -Context $Context -Message "CIM $ClassName failed: $($_.Exception.Message)"
        return @()
    }
}

function Get-DomainRoleInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $computerSystem = Get-CimRecord -Context $Context -ClassName Win32_ComputerSystem | Select-Object -First 1
    if (-not $computerSystem) { return $null }
    $roles = @('Standalone Workstation', 'Member Workstation', 'Standalone Server', 'Member Server', 'Backup Domain Controller', 'Primary Domain Controller')
    $role = $roles[[int]$computerSystem.DomainRole]
    $Context.IsDomainController = ([int]$computerSystem.DomainRole -ge 4)
    return [pscustomobject]@{ ComputerSystem = $computerSystem; Role = $role }
}

function Invoke-AuditSystemCollectors {
    <# SystemInfo, gpresult, audit policy, event log ACL, netstat, services, hotfixes, drives and log settings. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $os = Get-CimRecord -Context $Context -ClassName Win32_OperatingSystem | Select-Object -First 1
    $roleInfo = Get-DomainRoleInfo -Context $Context
    $systemText = "{0} Run on: {1}`r`n`r`n" -f $Context.Version, $Context.Started
    if ($os) {
        $systemText += "Computer Name: {0}`r`nCaption: {1}`r`nService Pack: {2}.{3}`r`nVersion: {4}`r`n`r`n" -f $os.CSName, $os.Caption, $os.ServicePackMajorVersion, $os.ServicePackMinorVersion, $os.Version
    }
    $ipConfigs = Get-CimRecord -Context $Context -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True'
    $systemText += "IP Address(es):`r`n"
    foreach ($config in $ipConfigs) {
        foreach ($ip in @($config.IPAddress | Where-Object { $_ -and $_ -ne '0.0.0.0' })) {
            $systemText += "{0}: {1}`r`n" -f $config.Description, $ip
        }
    }
    if ($roleInfo -and $roleInfo.ComputerSystem.PartOfDomain) {
        $systemText += "`r`nDomain: {0}`r`nDomain Role: {1}`r`n" -f $roleInfo.ComputerSystem.Domain, $roleInfo.Role
    }
    else { $systemText += "`r`nServer not member of domain.`r`n" }
    $systemText += "Current User: {0}`r`n" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Write-AuditReport -Context $Context -Report SystemInfo -Text $systemText

    $systemInfo = Invoke-AuditNative -Context $Context -FilePath (Join-Path $env:windir 'System32\systeminfo.exe')
    Write-AuditReport -Context $Context -Report SystemInfo -Text ($systemInfo -join "`r`n")

    $gpresultPath = $Context.Paths.Gpresult -replace '\.txt$', '.html'
    Invoke-AuditNative -Context $Context -FilePath (Join-Path $env:windir 'System32\gpresult.exe') -ArgumentList @('/h', $gpresultPath) | Out-Null
    $gptext = Invoke-AuditNative -Context $Context -FilePath (Join-Path $env:windir 'System32\gpresult.exe') -ArgumentList @('/z')
    Write-AuditReport -Context $Context -Report Gpresult -Text ($gptext -join "`r`n")

    $auditpol = Join-Path $env:windir 'System32\auditpol.exe'
    $auditCategory = Invoke-AuditNative -Context $Context -FilePath $auditpol -ArgumentList @('/get', '/category:*')
    Write-AuditReport -Context $Context -Report AuditPolicy -Text ($auditCategory -join "`r`n")
    $auditSubcategory = Invoke-AuditNative -Context $Context -FilePath $auditpol -ArgumentList @('/get', '/subcategory:*')
    Write-AuditReport -Context $Context -Report DetailedAuditSettings -Text ($auditSubcategory -join "`r`n")

    $icacls = Join-Path $env:windir 'System32\icacls.exe'
    foreach ($name in 'Application.evtx', 'Security.evtx', 'System.evtx') {
        $eventPath = Join-Path $env:windir "System32\winevt\Logs\$name"
        Write-AuditReport -Context $Context -Report EventLogPermissions -Text ((Invoke-AuditNative -Context $Context -FilePath $icacls -ArgumentList @($eventPath)) -join "`r`n")
    }
    Write-AuditReport -Context $Context -Report Netstat -Text ((Invoke-AuditNative -Context $Context -FilePath (Join-Path $env:windir 'System32\netstat.exe') -ArgumentList @('-an')) -join "`r`n")

    Write-AuditReport -Context $Context -Report Services -Text (Get-ServiceReportText -Context $Context)
    Write-AuditReport -Context $Context -Report HotFixes -Text (Get-HotFixReportText -Context $Context)
    Write-AuditReport -Context $Context -Report MissingHotfixes -Text (Get-MissingPatchReportText -Context $Context)
    Write-AuditReport -Context $Context -Report Drives -Text (Get-DriveReportText -Context $Context)
    Write-AuditLogSettings -Context $Context
}

function Get-ServiceReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = 'Service Name','Service State','Caption','Description','Can Interact with Desktop','Display Name','Error Control','Executable Path Name','Service Started','Start Mode','Account Name'
    $lines = @($header -join "`t")
    foreach ($service in Get-CimRecord -Context $Context -ClassName Win32_Service | Sort-Object Name) {
        $values = @($service.Name, $service.State, $service.Caption, $service.Description, $service.DesktopInteract, $service.DisplayName, $service.ErrorControl, $service.PathName, $service.Started, $service.StartMode, $service.StartName)
        $lines += ($values | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t"
    }
    return ($lines -join "`r`n")
}

function Get-HotFixReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $os = Get-CimRecord -Context $Context -ClassName Win32_OperatingSystem | Select-Object -First 1
    $lines = @('Service Pack: {0}.{1}' -f $os.ServicePackMajorVersion, $os.ServicePackMinorVersion, '')
    foreach ($hotfix in Get-CimRecord -Context $Context -ClassName Win32_QuickFixEngineering | Sort-Object HotFixID) {
        if ($hotfix.HotFixID -ne 'File 1') { $lines += 'Description: {0}`tHot Fix ID: {1}' -f $hotfix.Description, $hotfix.HotFixID }
    }
    return ($lines -join "`r`n")
}

function Get-MissingPatchReportText {
    <# The legacy wsusscn2.cab workflow is optional because its feed and applicability must be approved per audit cycle. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.Targets.MissingPatchesMode -ne 'OfflineScanPackage') {
        return 'Missing patch analysis not gathered: Offline scan is disabled by the audit configuration.'
    }
    if (-not (Test-Path -LiteralPath $Context.Targets.OfflineScanCabPath -PathType Leaf)) {
        return "Missing patch analysis not gathered: scan package not found at $($Context.Targets.OfflineScanCabPath)."
    }
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $manager = New-Object -ComObject Microsoft.Update.ServiceManager
        $service = $manager.AddScanPackageService('Offline Sync Service', $Context.Targets.OfflineScanCabPath, 1)
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 3
        $searcher.ServiceID = $service.ServiceID
        $result = $searcher.Search('IsInstalled=0')
        if ($result.Updates.Count -eq 0) { return 'There are no applicable missing updates.' }
        $lines = @('List of applicable missing security patches:', '', "KB Num`tRating`tDescription")
        foreach ($update in $result.Updates) { $lines += '{0}`t{1}`t{2}' -f ($update.KBArticleIDs -join ','), $update.MsrcSeverity, $update.Title }
        return ($lines -join "`r`n")
    }
    catch {
        Write-AuditError -Context $Context -Message "Offline patch scan failed: $($_.Exception.Message)"
        return "Missing patch analysis failed: $($_.Exception.Message)"
    }
}

function Get-DriveReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $lines = @((@('Drive Letter','Total Size','Free Space','File System') -join "`t"))
    foreach ($drive in Get-CimRecord -Context $Context -ClassName Win32_LogicalDisk | Sort-Object DeviceID) {
        $total = if ($drive.Size) { [math]::Round($drive.Size / 1GB, 2) } else { '' }
        $free = if ($drive.FreeSpace) { [math]::Round($drive.FreeSpace / 1GB, 2) } else { '' }
        $lines += @($drive.DeviceID, $total, $free, $drive.FileSystem) -join "`t"
    }
    return ($lines -join "`r`n")
}

function Write-AuditLogSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $keys = @('HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Security', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\System')
    if ($Context.IsDomainController) { $keys += 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Directory Service', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\DNS Server', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\DFS Replication' }
    foreach ($key in $keys) { Write-AuditReport -Context $Context -Report LogSettings -Text (Get-RegistryReportText -Context $Context -Path $key) }
}

function Invoke-AuditPermissionCollectors {
    <# FilePermissions, DirectoryPermissions, and Shares. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    foreach ($relative in $Context.Targets.FileTargets) {
        $path = Join-Path $env:windir "System32\$relative"
        Write-AuditReport -Context $Context -Report FilePermissions -Text (Get-AclReportText -Context $Context -Path $path)
    }
    foreach ($template in $Context.Targets.DirectoryTargets) {
        $path = $ExecutionContext.InvokeCommand.ExpandString($template)
        Write-AuditReport -Context $Context -Report DirectoryPermissions -Text (Get-AclReportText -Context $Context -Path $path)
    }
    if ($Context.IsDomainController) {
        foreach ($path in (Join-Path $env:windir 'SYSVOL'), (Join-Path $env:windir 'NTDS')) {
            Write-AuditReport -Context $Context -Report DirectoryPermissions -Text (Get-AclReportText -Context $Context -Path $path)
        }
    }
    Write-AuditShares -Context $Context
}

function Get-AclReportText {
    <# Human-readable DACL/SACL rendering intentionally resembles the VBS report rather than Format-List output. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return "${Path}:`r`n`tFile does not exist!`r`n" }
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $lines = @("${Path}:")
        foreach ($ace in $acl.Access) { $lines += "`t{0}`t{1}: `t{2}" -f $ace.IdentityReference, $ace.AccessControlType, $ace.FileSystemRights }
        $auditRules = @()
        try { $auditRules = @(Get-Acl -LiteralPath $Path -Audit -ErrorAction Stop | Select-Object -ExpandProperty Audit) }
        catch { Write-AuditError -Context $Context -Message "Audit ACL $Path could not be read: $($_.Exception.Message)" }
        if ($auditRules.Count -gt 0) {
            $lines += 'Auditing:'
            foreach ($audit in $auditRules) { $lines += "`t{0}`t{1}`t{2}" -f $audit.IdentityReference, $audit.AuditFlags, $audit.FileSystemRights }
        }
        else { $lines += 'Auditing:', '(No auditing)' }
        return ($lines -join "`r`n") + "`r`n"
    }
    catch {
        Write-AuditError -Context $Context -Message "ACL $Path failed: $($_.Exception.Message)"
        return "${Path}:`r`n`tUnable to read permissions: $($_.Exception.Message)`r`n"
    }
}

function Write-AuditShares {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $lines = @((@('Name','Path','Caption','Type','Trustee','ACE Type','Permissions') -join "`t"))
    foreach ($share in Get-CimRecord -Context $Context -ClassName Win32_Share | Sort-Object Name) {
        $access = @()
        if (Get-Command Get-SmbShareAccess -ErrorAction SilentlyContinue) {
            try { $access = @(Get-SmbShareAccess -Name $share.Name -ErrorAction Stop) } catch { Write-AuditError -Context $Context -Message "Share ACL $($share.Name) failed: $($_.Exception.Message)" }
        }
        if ($access.Count -eq 0) {
            $lines += @($share.Name, $share.Path, $share.Caption, $share.Type, '', '', 'No DACL Found') -join "`t"
        }
        else {
            foreach ($entry in $access) { $lines += @($share.Name, $share.Path, $share.Caption, $share.Type, $entry.AccountName, $entry.AccessControlType, $entry.AccessRight) -join "`t" }
        }
        if ($share.Path -and (Test-Path -LiteralPath $share.Path)) {
            Write-AuditReport -Context $Context -Report DirectoryPermissions -Text "Share Name: $($share.Name)`tShare Path: $($share.Path)"
            Write-AuditReport -Context $Context -Report DirectoryPermissions -Text (Get-AclReportText -Context $Context -Path $share.Path)
        }
    }
    Write-AuditReport -Context $Context -Report Shares -Text ($lines -join "`r`n")
}

function Invoke-AuditConfigurationCollectors {
    <# RegistryValues report. The full scope is data-driven in Config/AuditTargets.psd1. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    foreach ($path in $Context.Targets.RegistryKeys) {
        Write-AuditReport -Context $Context -Report RegistryValues -Text (Get-RegistryReportText -Context $Context -Path $path)
    }
    if ($Context.IsDomainController) {
        foreach ($path in 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Directory Service', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\DNS Server', 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\DFS Replication', 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters') {
            Write-AuditReport -Context $Context -Report RegistryValues -Text (Get-RegistryReportText -Context $Context -Path $path)
        }
    }
}

function Get-RegistryReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)

    $displayPath = $Path.Replace('HKLM:', 'HKEY_LOCAL_MACHINE').Replace('HKCU:', 'HKEY_CURRENT_USER')
    if (-not (Test-Path -LiteralPath $Path)) { return "Registry Key: $displayPath`r`nRegistry Key Does Not Exist`r`n" }
    try {
        $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
        $properties = @($item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
        if ($properties.Count -eq 0) { return "Registry Key: $displayPath`r`nNo Registry Values`r`n" }
        $lines = @("Registry Key: $displayPath")
        foreach ($property in $properties) {
            $value = if ($property.Value -is [array]) { $property.Value -join ' ' } else { $property.Value }
            $lines += "Value Name: {0}`tData: {1}" -f $property.Name, (ConvertTo-AuditField $value)
        }
        return ($lines -join "`r`n") + "`r`n"
    }
    catch {
        Write-AuditError -Context $Context -Message "Registry $Path failed: $($_.Exception.Message)"
        return "Registry Key: $displayPath`r`nUnable to read registry key: $($_.Exception.Message)`r`n"
    }
}

function Invoke-AuditIdentityCollectors {
    <# Local users/groups on member servers; AD users/groups/trusts and GPO backup on DCs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.IsDomainController) { Invoke-AuditDomainControllerCollectors -Context $Context; return }
    Write-AuditReport -Context $Context -Report Users -Text (Get-LocalUserReportText -Context $Context)
    Write-AuditReport -Context $Context -Report Groups -Text (Get-LocalGroupReportText -Context $Context)
}

function Get-LocalUserReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = 'User Name','Full Name','Description','Account Type','SID','Password Last Changed','Domain','Password Is Changeable','Password Expires','Password Required','Account Disabled','Account Locked','Last Login'
    $lines = @(($header | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t")
    foreach ($user in Get-CimRecord -Context $Context -ClassName Win32_UserAccount -Filter 'LocalAccount=True' | Sort-Object Name) {
        $passwordLastChanged = ''
        try { $passwordLastChanged = ([datetime]::Now).AddSeconds(-[double]$user.PasswordAge) } catch { }
        $values = @($user.Name, $user.FullName, $user.Description, $user.AccountType, $user.SID, $passwordLastChanged, $user.Domain, $user.PasswordChangeable, $user.PasswordExpires, $user.PasswordRequired, $user.Disabled, $user.Lockout, $user.LastLogin)
        $lines += ($values | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t"
    }
    return ($lines -join "`r`n")
}

function Get-LocalGroupReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $lines = @()
    foreach ($group in Get-CimRecord -Context $Context -ClassName Win32_Group -Filter 'LocalAccount=True' | Sort-Object Name) {
        $lines += ('"Name: {0}"`t"SID: {1}"`t"Caption: {2}"`t"Description: {3}"`t"Domain: {4}"' -f $group.Name, $group.SID, $group.Caption, $group.Description, $group.Domain)
        try {
            $escapedDomain = $group.Domain.Replace("'", "''")
            $escapedName = $group.Name.Replace("'", "''")
            $query = "ASSOCIATORS OF {Win32_Group.Domain='$escapedDomain',Name='$escapedName'} WHERE AssocClass=Win32_GroupUser Role=GroupComponent"
            $members = Get-CimInstance -Query $query -ErrorAction Stop
            foreach ($member in $members) { $lines += ('"{0}\\{1}"' -f $member.Domain, $member.Name) }
        }
        catch { Write-AuditError -Context $Context -Message "Group membership $($group.Name) failed: $($_.Exception.Message)" }
        $lines += ''
    }
    return ($lines -join "`r`n")
}

function Invoke-AuditDomainControllerCollectors {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $adModule = Get-Module -ListAvailable -Name ActiveDirectory | Select-Object -First 1
    if (-not $adModule) {
        $message = 'ActiveDirectory module unavailable; domain user, group, and trust reports were not gathered.'
        Write-AuditError -Context $Context -Message $message
        Write-AuditReport -Context $Context -Report Users -Text $message
        Write-AuditReport -Context $Context -Report Groups -Text $message
        return
    }
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-AuditReport -Context $Context -Report Users -Text (Get-ADUserReportText -Context $Context)
    Write-AuditReport -Context $Context -Report Groups -Text (Get-ADGroupReportText -Context $Context)
    Initialize-AdministrativeAccountsReport -Context $Context
    Write-AuditReport -Context $Context -Report AdministrativeAccounts -Text (Get-AdministrativeAccountReportText -Context $Context)
    Initialize-AuditAdTrustReport -Context $Context
    Write-AuditReport -Context $Context -Report ADTrusts -Text (Get-ADTrustReportText -Context $Context)
    if ($Context.IncludeGpoBackup) {
        Invoke-AuditGpoBackup -Context $Context
    }
    else {
        Write-AuditError -Context $Context -Message 'INFO: GPO backup skipped; run with -IncludeGpoBackup to create it.'
    }
}

function Get-ADUserReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = 'NT Name','Display Name','Description','SID','Password Last Changed','Password Expired','Password Cannot Change','Password Never Expires','Password Required','Account Disabled','Account Locked','Last Login','Account Expiration Date'
    $lines = @(($header | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t")
    foreach ($user in Get-ADUser -Filter * -Properties DisplayName, Description, PasswordLastSet, PasswordExpired, CannotChangePassword, PasswordNeverExpires, PasswordNotRequired, Enabled, LockedOut, LastLogonDate, AccountExpirationDate, SID | Sort-Object SamAccountName) {
        $values = @($user.SamAccountName, $user.DisplayName, $user.Description, $user.SID, $user.PasswordLastSet, $user.PasswordExpired, $user.CannotChangePassword, $user.PasswordNeverExpires, (-not $user.PasswordNotRequired), (-not $user.Enabled), $user.LockedOut, $user.LastLogonDate, $user.AccountExpirationDate)
        $lines += ($values | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t"
    }
    return ($lines -join "`r`n")
}

function Get-ADGroupReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $lines = @()
    foreach ($group in Get-ADGroup -Filter * -Properties Description, SID | Sort-Object Name) {
        $lines += ('"Name: {0}"`t"Description: {1}"`t"SID: {2}"' -f $group.Name, (ConvertTo-AuditField $group.Description), $group.SID)
        try { foreach ($member in Get-ADGroupMember -Identity $group -ErrorAction Stop) { $lines += ('{0}"{1}"' -f [char]9, $member.Name) } }
        catch { Write-AuditError -Context $Context -Message "AD group membership $($group.Name) failed: $($_.Exception.Message)" }
        $lines += ''
    }
    return ($lines -join "`r`n")
}

function Initialize-AdministrativeAccountsReport {
    <# Creates the DC-only privileged-account report with the standard confidentiality header. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = "{0}: Security Assessment: Confidential for {1} use only`r`n`r`n" -f $Context.Version, $Context.ClientName
    [System.IO.File]::WriteAllText($Context.Paths.AdministrativeAccounts, $header, (Get-ReportTextEncoding -Context $Context))
}

function Get-DomainNameFromDistinguishedName {
    <# Returns a DNS domain name from a DN while preserving escaped commas in CN values. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$DistinguishedName)

    $domainComponents = [regex]::Matches($DistinguishedName, '(?i)(?:^|(?<!\\),)DC=([^,]+)')
    if ($domainComponents.Count -eq 0) { return $null }
    return (@($domainComponents | ForEach-Object { $_.Groups[1].Value }) -join '.')
}

function Get-AdministrativeAccountReportText {
    <#
    Produces one record per recursively resolved member of each configured
    privileged AD group. It intentionally reports source groups, not inferred
    privileges from arbitrary ACLs, GPO preferences, or delegated rights.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = 'Account Name','Display Name','SID','Object Type','Account Domain','Privileged Group(s)','Password Last Changed','Account Disabled','Account Locked','Account Expiration Date','Resolution Status','Distinguished Name'
    $lines = @(($header | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t")
    $accounts = @{}
    $domainControllers = @{}

    foreach ($groupName in $Context.Targets.PrivilegedGroupNames) {
        try {
            $group = Get-ADGroup -Identity $groupName -ErrorAction Stop
            $members = @(Get-ADGroupMember -Identity $group.DistinguishedName -Recursive -ErrorAction Stop)
        }
        catch {
            Write-AuditError -Context $Context -Message "Privileged group $groupName could not be resolved: $($_.Exception.Message)"
            continue
        }

        foreach ($member in $members) {
            $key = if ($member.SID) { [string]$member.SID } else { $member.DistinguishedName }
            if (-not $accounts.ContainsKey($key)) {
                $accounts[$key] = [pscustomobject]@{
                    DistinguishedName = $member.DistinguishedName
                    ObjectClass = $member.objectClass
                    MemberSid = $member.SID
                    AccountDomain = Get-DomainNameFromDistinguishedName -DistinguishedName $member.DistinguishedName
                    SourceGroups = New-Object 'System.Collections.Generic.List[string]'
                }
            }
            if (-not $accounts[$key].SourceGroups.Contains($group.Name)) {
                $accounts[$key].SourceGroups.Add($group.Name)
            }
        }
    }

    foreach ($record in $accounts.Values | Sort-Object DistinguishedName) {
        $accountName = ''
        $displayName = ''
        $sid = ''
        $passwordLastSet = ''
        $disabled = ''
        $locked = ''
        $expiration = ''
        $resolutionStatus = 'Resolved'

        try {
            if ($record.ObjectClass -eq 'foreignSecurityPrincipal') {
                $accountName = $record.DistinguishedName
                $sid = $record.MemberSid
                $resolutionStatus = 'Not resolved - foreign security principal'
                throw 'Foreign security principal has no queryable home-domain distinguished name.'
            }
            if (-not $record.AccountDomain) {
                throw 'The member distinguished name does not contain a domain component.'
            }
            if (-not $domainControllers.ContainsKey($record.AccountDomain)) {
                $domainControllers[$record.AccountDomain] = (Get-ADDomainController -Discover -DomainName $record.AccountDomain -Writable -ErrorAction Stop).HostName
            }
            $server = $domainControllers[$record.AccountDomain]

            switch ($record.ObjectClass) {
                'user' {
                    $account = Get-ADUser -Identity $record.DistinguishedName -Server $server -Properties DisplayName, SID, PasswordLastSet, Enabled, LockedOut, AccountExpirationDate -ErrorAction Stop
                    $accountName = $account.SamAccountName
                    $displayName = $account.DisplayName
                    $sid = $account.SID
                    $passwordLastSet = $account.PasswordLastSet
                    $disabled = -not $account.Enabled
                    $locked = $account.LockedOut
                    $expiration = $account.AccountExpirationDate
                }
                'computer' {
                    $account = Get-ADComputer -Identity $record.DistinguishedName -Server $server -Properties SID, PasswordLastSet, Enabled -ErrorAction Stop
                    $accountName = $account.SamAccountName
                    $displayName = $account.Name
                    $sid = $account.SID
                    $passwordLastSet = $account.PasswordLastSet
                    $disabled = -not $account.Enabled
                }
                default {
                    $account = Get-ADObject -Identity $record.DistinguishedName -Server $server -Properties objectSid, Name -ErrorAction Stop
                    $accountName = $account.Name
                    $displayName = $account.Name
                    $sid = $account.objectSid
                }
            }
        }
        catch {
            if (-not $accountName) { $accountName = $record.DistinguishedName }
            if (-not $sid) { $sid = $record.MemberSid }
            if ($resolutionStatus -eq 'Resolved') { $resolutionStatus = 'Not resolved - unable to query account domain' }
            Write-AuditError -Context $Context -Message "Privileged member $($record.DistinguishedName) under $($record.AccountDomain) could not be read: $($_.Exception.Message)"
        }

        $values = @(
            $accountName,
            $displayName,
            $sid,
            $record.ObjectClass,
            $record.AccountDomain,
            ($record.SourceGroups -join '; '),
            $passwordLastSet,
            $disabled,
            $locked,
            $expiration,
            $resolutionStatus,
            $record.DistinguishedName
        )
        $lines += ($values | ForEach-Object { ConvertTo-AuditQuotedField $_ }) -join "`t"
    }

    if ($accounts.Count -eq 0) { $lines += '"No members were resolved from the configured privileged groups."' }
    return ($lines -join "`r`n")
}

function Initialize-AuditAdTrustReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $header = "{0}: Security Assessment: Confidential for {1} use only`r`n`r`n" -f $Context.Version, $Context.ClientName
    [System.IO.File]::WriteAllText($Context.Paths.ADTrusts, $header, (Get-ReportTextEncoding -Context $Context))
}

function Get-ADTrustReportText {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    try {
        $domain = Get-ADDomain
        $lines = @("Trusts for $($domain.DNSRoot):")
        $trusts = @(Get-ADTrust -Filter * -ErrorAction Stop)
        if ($trusts.Count -eq 0) { return ($lines + 'No trusts found!') -join "`r`n" }
        foreach ($trust in $trusts) { $lines += ' {0} Direction: {1} Type: {2} Attributes: {3}' -f $trust.Name, $trust.Direction, $trust.TrustType, $trust.TrustAttributes }
        return ($lines -join "`r`n")
    }
    catch {
        Write-AuditError -Context $Context -Message "AD trusts failed: $($_.Exception.Message)"
        return "Unable to gather AD trusts: $($_.Exception.Message)"
    }
}

function Invoke-AuditGpoBackup {
    <# Runs only when -IncludeGpoBackup is explicitly requested on a domain controller. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if (-not (Get-Module -ListAvailable -Name GroupPolicy)) {
        Write-AuditError -Context $Context -Message 'GroupPolicy module unavailable; GPO backup was not gathered.'
        return
    }
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        $path = Join-Path $Context.OutputDirectory 'GPOBackup'
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Backup-GPO -All -Path $path -Comment "WindowsAudit $($Context.Started.ToString('o'))" -ErrorAction Stop | Out-Null
    }
    catch { Write-AuditError -Context $Context -Message "GPO backup failed: $($_.Exception.Message)" }
}

function Invoke-AuditSecurityPolicyCollector {
    <# Exports the applicable local password, audit, and user-rights policy as readable text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $outputPath = Join-Path $Context.OutputDirectory 'AuditandUserRights.txt'
    $result = Invoke-AuditNative -Context $Context -FilePath (Join-Path $env:windir 'System32\secedit.exe') -ArgumentList @('/export', '/cfg', $outputPath, '/areas', 'SECURITYPOLICY', 'USER_RIGHTS')
    if (-not (Test-Path -LiteralPath $outputPath)) {
        Write-AuditError -Context $Context -Message "Security policy export did not create $outputPath. Output: $($result -join ' ')"
    }
}

Export-ModuleMember -Function Invoke-Audit*
