#Requires -Version 5.1
<#
.SYNOPSIS
    Server QA validation engine.
.DESCRIPTION
    Compares collected server data against template expectations.
    Returns structured pass/fail/info results for each check.
#>

function New-QaValidationResult {
    param(
        [string]$Category,
        [string]$CheckKey,
        [bool]$Enabled,
        [string]$Expected,
        [string]$Actual,
        [ValidateSet('Pass','Fail','Warn','Error','Info','Skip')]
        [string]$Status,
        [string]$Details,
        [string]$ErrorMessage
    )
    [PSCustomObject]@{
        Category     = $Category
        CheckKey     = $CheckKey
        Enabled      = $Enabled
        Expected     = $Expected
        Actual       = $Actual
        Status       = $Status
        Details      = $Details
        ErrorMessage = $ErrorMessage
    }
}

function Compare-QaValue {
    <#
    .SYNOPSIS
        Compares an actual value against an expected value using the specified operator.
    #>
    param(
        [object]$Actual,
        [object]$Expected,
        [ValidateSet('eq','gte','lte','gt','lt','contains','regex')]
        [string]$Operator = 'eq'
    )

    if ($null -eq $Actual) { return $false }

    switch ($Operator) {
        'eq'       { return $Actual -eq $Expected }
        'gte'      {
            try { return ([double]$Actual) -ge ([double]$Expected) }
            catch { return [string]$Actual -ge [string]$Expected }
        }
        'lte'      {
            try { return ([double]$Actual) -le ([double]$Expected) }
            catch { return [string]$Actual -le [string]$Expected }
        }
        'gt'       {
            try { return ([double]$Actual) -gt ([double]$Expected) }
            catch { return [string]$Actual -gt [string]$Expected }
        }
        'lt'       {
            try { return ([double]$Actual) -lt ([double]$Expected) }
            catch { return [string]$Actual -lt [string]$Expected }
        }
        'contains' { return ([string]$Actual) -like "*$Expected*" }
        'regex'    { return ([string]$Actual) -match $Expected }
    }
    return $false
}

function Get-OperatorDisplay {
    param([string]$Operator, [object]$Value)
    switch ($Operator) {
        'eq'       { return "$Value" }
        'gte'      { return ">= $Value" }
        'lte'      { return "<= $Value" }
        'gt'       { return "> $Value" }
        'lt'       { return "< $Value" }
        'contains' { return "Contains '$Value'" }
        'regex'    { return "Matches '$Value'" }
        default    { return "$Value" }
    }
}

# --- Individual check validators ---

function Test-QaConnectivityCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Connectivity' -CheckKey 'connectivity' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.Connectivity
    if (-not $check.Success -and -not $check.Data) {
        return New-QaValidationResult -Category 'Connectivity' -CheckKey 'connectivity' `
            -Enabled $true -Expected 'Reachable' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $actual = if ($check.Data) { 'Reachable' } else { 'Unreachable' }
    $status = if ($check.Data) { 'Pass' } else { 'Fail' }

    New-QaValidationResult -Category 'Connectivity' -CheckKey 'connectivity' `
        -Enabled $true -Expected 'Reachable' -Actual $actual -Status $status `
        -Details '' -ErrorMessage $null
}

function Test-QaCpuCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'CPU Count' -CheckKey 'cpu' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.Cpu
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'CPU Count' -CheckKey 'cpu' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $operator = if ($CheckConfig.operator) { $CheckConfig.operator } else { 'gte' }
    $expected = $CheckConfig.expected
    $actual = $check.Data

    if ($null -eq $expected -or $expected -eq '') {
        return New-QaValidationResult -Category 'CPU Count' -CheckKey 'cpu' `
            -Enabled $true -Expected '(info)' -Actual "$actual" -Status 'Info' `
            -Details '' -ErrorMessage $null
    }

    $pass = Compare-QaValue -Actual $actual -Expected $expected -Operator $operator
    $expectedDisplay = Get-OperatorDisplay -Operator $operator -Value $expected

    New-QaValidationResult -Category 'CPU Count' -CheckKey 'cpu' `
        -Enabled $true -Expected $expectedDisplay -Actual "$actual" `
        -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
        -Details '' -ErrorMessage $null
}

function Test-QaMemoryCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Memory' -CheckKey 'memoryGB' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.MemoryGB
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Memory' -CheckKey 'memoryGB' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $operator = if ($CheckConfig.operator) { $CheckConfig.operator } else { 'gte' }
    $expected = $CheckConfig.expected
    $actual = $check.Data

    if ($null -eq $expected -or $expected -eq '') {
        return New-QaValidationResult -Category 'Memory' -CheckKey 'memoryGB' `
            -Enabled $true -Expected '(info)' -Actual "$actual GB" -Status 'Info' `
            -Details '' -ErrorMessage $null
    }

    $pass = Compare-QaValue -Actual $actual -Expected $expected -Operator $operator
    $expectedDisplay = "$(Get-OperatorDisplay -Operator $operator -Value $expected) GB"

    New-QaValidationResult -Category 'Memory' -CheckKey 'memoryGB' `
        -Enabled $true -Expected $expectedDisplay -Actual "$actual GB" `
        -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
        -Details '' -ErrorMessage $null
}

function Test-QaSoftwareCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Software' -CheckKey 'installedSoftware' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.Software
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Software' -CheckKey 'installedSoftware' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $installedNames = @()
    if ($check.Data) {
        $installedNames = $check.Data | ForEach-Object { $_.Name }
    }

    $required = $CheckConfig.required
    if (-not $required -or $required.Count -eq 0) {
        $softwareList = ($installedNames | Select-Object -First 10) -join ', '
        if ($installedNames.Count -gt 10) { $softwareList += "... (+$($installedNames.Count - 10) more)" }
        $results += New-QaValidationResult -Category 'Software' -CheckKey 'installedSoftware' `
            -Enabled $true -Expected '(info)' -Actual "$($installedNames.Count) packages" -Status 'Info' `
            -Details $softwareList -ErrorMessage $null
        return $results
    }

    foreach ($req in $required) {
        $foundObj = $check.Data | Where-Object { $_.Name -like "*$req*" } | Select-Object -First 1
        $displayReq = $req -replace '\*', ''
        if ($foundObj) {
            $matchName = $foundObj.Name
            $matchVersion = if ($foundObj.Version) { $foundObj.Version } else { 'unknown' }
            $results += New-QaValidationResult -Category 'Software' -CheckKey 'installedSoftware' `
                -Enabled $true -Expected $displayReq -Actual $matchName -Status 'Pass' `
                -Details "$matchName v$matchVersion" -ErrorMessage $null
        }
        else {
            $results += New-QaValidationResult -Category 'Software' -CheckKey 'installedSoftware' `
                -Enabled $true -Expected $displayReq -Actual 'Not Found' -Status 'Fail' `
                -Details "Not in HKLM Uninstall registry (64-bit + 32-bit)" -ErrorMessage $null
        }
    }

    return $results
}

function Test-QaIpConfigCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'IP Config' -CheckKey 'ipConfig' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.IpConfig
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'IP Config' -CheckKey 'ipConfig' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $adapterCount = 0
    if ($check.Data) { $adapterCount = @($check.Data).Count }

    # --- Backend NIC check (172.25.x.x or 172.24.x.x) ---
    $backendSubnets = $CheckConfig.backendSubnets
    if ($CheckConfig.requireBackendNic -and $backendSubnets -and $backendSubnets.Count -gt 0) {
        $hasBackend = $false
        foreach ($adapter in $check.Data) {
            foreach ($ip in $adapter.IPAddresses) {
                foreach ($subnet in $backendSubnets) {
                    if ($ip.StartsWith($subnet)) { $hasBackend = $true; break }
                }
                if ($hasBackend) { break }
            }
            if ($hasBackend) { break }
        }
        $subnetDisplay = ($backendSubnets -join ' or ') + 'x.x'
        $results += New-QaValidationResult -Category 'Backend NIC' -CheckKey 'ipConfig' `
            -Enabled $true -Expected "NIC on $subnetDisplay" -Actual $(if ($hasBackend) { 'Found' } else { 'Not found' }) `
            -Status $(if ($hasBackend) { 'Pass' } else { 'Fail' }) `
            -Details '' -ErrorMessage $null
    }

    # --- Per-adapter detail: IP, DNS, NetBIOS ---
    foreach ($adapter in $check.Data) {
        $ipStr = ($adapter.IPAddresses -join ', ')
        $dnsActual = ($adapter.DnsServers -join ', ')

        # Display adapter info line
        $results += New-QaValidationResult -Category 'Adapter' -CheckKey 'ipConfig' `
            -Enabled $true -Expected '(info)' `
            -Actual "$($adapter.Description)" `
            -Status 'Info' `
            -Details '' -ErrorMessage $null

        # IP addresses - info row
        $results += New-QaValidationResult -Category '  IP Address' -CheckKey 'ipConfig' `
            -Enabled $true -Expected '(info)' -Actual $ipStr -Status 'Info' `
            -Details '' -ErrorMessage $null

        # DNS servers
        $expectedDns = $CheckConfig.expectedDnsServers
        if ($expectedDns -and $expectedDns.Count -gt 0) {
            $expectedDnsStr = ($expectedDns -join ', ')
            $dnsMatch = $true
            foreach ($dns in $expectedDns) {
                if ($adapter.DnsServers -notcontains $dns) { $dnsMatch = $false; break }
            }
            $results += New-QaValidationResult -Category '  DNS Servers' -CheckKey 'ipConfig' `
                -Enabled $true -Expected $expectedDnsStr -Actual $dnsActual `
                -Status $(if ($dnsMatch) { 'Pass' } else { 'Fail' }) `
                -Details '' -ErrorMessage $null
        }
        else {
            $results += New-QaValidationResult -Category '  DNS Servers' -CheckKey 'ipConfig' `
                -Enabled $true -Expected '(info)' -Actual $dnsActual -Status 'Info' `
                -Details '' -ErrorMessage $null
        }

        # NetBIOS check - value 2 = Disabled
        if ($CheckConfig.netBiosDisabled) {
            $nbValue = $adapter.NetBIOSValue
            $nbDisabled = ($nbValue -eq 2)
            $results += New-QaValidationResult -Category '  NetBIOS' -CheckKey 'ipConfig' `
                -Enabled $true -Expected 'Disabled (2)' -Actual "$($adapter.NetBIOS) ($nbValue)" `
                -Status $(if ($nbDisabled) { 'Pass' } else { 'Fail' }) `
                -Details '' -ErrorMessage $null
        }
        else {
            $nbValue = $adapter.NetBIOSValue
            $results += New-QaValidationResult -Category '  NetBIOS' -CheckKey 'ipConfig' `
                -Enabled $true -Expected '(info)' -Actual "$($adapter.NetBIOS)" -Status 'Info' `
                -Details '' -ErrorMessage $null
        }
    }

    if ($adapterCount -eq 0) {
        $results += New-QaValidationResult -Category 'IP Config' -CheckKey 'ipConfig' `
            -Enabled $true -Expected '(info)' -Actual 'No adapters' -Status 'Warn' `
            -Details '' -ErrorMessage $null
    }

    return $results
}

function Test-QaLocalAdminsCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Local Admins' -CheckKey 'localAdmins' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.LocalAdmins
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Local Admins' -CheckKey 'localAdmins' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $memberNames = @()
    if ($check.Data) {
        $memberNames = $check.Data | ForEach-Object { $_.Name }
    }

    $allowed = $CheckConfig.allowed
    if (-not $allowed -or $allowed.Count -eq 0) {
        $memberList = ($memberNames -join "`n")
        $results += New-QaValidationResult -Category 'Local Admins' -CheckKey 'localAdmins' `
            -Enabled $true -Expected '(info)' -Actual $memberList -Status 'Info' `
            -Details '' -ErrorMessage $null
        return $results
    }

    $results += New-QaValidationResult -Category 'Local Admins' -CheckKey 'localAdmins' `
        -Enabled $true -Expected ($allowed -join ', ') -Actual ($memberNames -join "`n") `
        -Status 'Info' -Details '' -ErrorMessage $null

    # Check for members not in the allowed list
    foreach ($member in $memberNames) {
        $isAllowed = $false
        foreach ($pattern in $allowed) {
            if ($member -like "*$pattern*") { $isAllowed = $true; break }
        }
        if (-not $isAllowed) {
            $results += New-QaValidationResult -Category 'Local Admins' -CheckKey 'localAdmins' `
                -Enabled $true -Expected 'Not in allowed list' -Actual $member -Status 'Warn' `
                -Details '' -ErrorMessage $null
        }
    }

    return $results
}

function Test-QaHotfixCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Hotfixes' -CheckKey 'recentHotfixes' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.Hotfixes
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Hotfixes' -CheckKey 'recentHotfixes' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $hotfixCount = 0
    if ($check.Data) { $hotfixCount = $check.Data.Count }

    $minCount = $CheckConfig.minimumCount
    $kbDisplay = if ($check.Data) { ($check.Data | ForEach-Object { $_.HotFixID }) -join "`n" } else { 'None' }
    $kbDetails = if ($check.Data) {
        ($check.Data | ForEach-Object {
            $dateStr = if ($_.InstalledOn) { $_.InstalledOn.ToString('yyyy-MM-dd') } else { 'unknown date' }
            "$($_.HotFixID) installed $dateStr"
        }) -join "`n"
    } else { 'None' }

    if ($null -eq $minCount -or $minCount -eq '') {
        $results += New-QaValidationResult -Category 'Hotfixes' -CheckKey 'recentHotfixes' `
            -Enabled $true -Expected '(info)' -Actual $kbDisplay -Status 'Info' `
            -Details $kbDetails -ErrorMessage $null
        return $results
    }

    $pass = $hotfixCount -ge $minCount
    $results += New-QaValidationResult -Category 'Hotfixes' -CheckKey 'recentHotfixes' `
        -Enabled $true -Expected ">= $minCount in 30 days" -Actual $kbDisplay `
        -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
        -Details $kbDetails -ErrorMessage $null

    # Check for specific required KBs
    $requiredKBs = $CheckConfig.requiredKBs
    if ($requiredKBs -and $requiredKBs.Count -gt 0) {
        $installedKBs = @()
        if ($check.Data) { $installedKBs = $check.Data | ForEach-Object { $_.HotFixID } }
        foreach ($kb in $requiredKBs) {
            $found = $installedKBs -contains $kb
            $results += New-QaValidationResult -Category 'Hotfixes' -CheckKey 'recentHotfixes' `
                -Enabled $true -Expected $kb -Actual $(if ($found) { 'Installed' } else { 'Missing' }) `
                -Status $(if ($found) { 'Pass' } else { 'Fail' }) `
                -Details "Required KB $kb" -ErrorMessage $null
        }
    }

    return $results
}

function Test-QaDrivePermissionsCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Storage Permissions' -CheckKey 'drivePermissions' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.DrivePerms
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Storage Permissions' -CheckKey 'drivePermissions' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $everyoneAllowed = $CheckConfig.everyoneAccessAllowed

    foreach ($vol in $check.Data) {
        $label = "$($vol.Path)"
        $typeTag = if ($vol.Type -eq 'MountPoint') { ' (mount)' } else { '' }

        if ($null -eq $vol.EveryoneAccess) {
            $results += New-QaValidationResult -Category "ACL$typeTag" -CheckKey 'drivePermissions' `
                -Enabled $true -Expected '(info)' -Actual "$label - Unable to read ACL" -Status 'Warn' `
                -Details '' -ErrorMessage $null
            continue
        }

        $actualStr = if ($vol.EveryoneAccess) { "'Everyone' has access" } else { "'Everyone' removed" }

        if ($null -eq $everyoneAllowed) {
            $results += New-QaValidationResult -Category "ACL$typeTag" -CheckKey 'drivePermissions' `
                -Enabled $true -Expected '(info)' -Actual "$label $actualStr" -Status 'Info' `
                -Details '' -ErrorMessage $null
        }
        else {
            # Policy: Everyone must be removed from all drive ACLs.
            # Keep honoring the setting's presence, but enforce secure behavior.
            $pass = -not $vol.EveryoneAccess
            $expectedStr = "'Everyone' removed"
            $results += New-QaValidationResult -Category "ACL$typeTag" -CheckKey 'drivePermissions' `
                -Enabled $true -Expected "$label $expectedStr" -Actual "$label $actualStr" `
                -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
                -Details '' -ErrorMessage $null
        }
    }

    if ($results.Count -eq 0) {
        $results += New-QaValidationResult -Category 'Storage Permissions' -CheckKey 'drivePermissions' `
            -Enabled $true -Expected '(info)' -Actual 'No volumes found' -Status 'Warn' `
            -Details '' -ErrorMessage $null
    }

    return $results
}

function Test-QaFDriveCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'F: Drive' -CheckKey 'fDrive' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.FDrive
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'F: Drive' -CheckKey 'fDrive' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $exists = $check.Data.Exists

    $mustExist = $CheckConfig.mustExist
    if ($null -ne $mustExist) {
        $pass = ($mustExist -and $exists) -or (-not $mustExist -and -not $exists)
        $expectedStr = if ($mustExist) { 'Must exist' } else { 'Must not exist' }
        $actualStr = if ($exists) { 'Exists' } else { 'Not found' }
        $results += New-QaValidationResult -Category 'F: Drive' -CheckKey 'fDrive' `
            -Enabled $true -Expected $expectedStr -Actual $actualStr `
            -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
            -Details '' -ErrorMessage $null
    }
    else {
        $actualStr = if ($exists) { 'Exists' } else { 'Not found' }
        $results += New-QaValidationResult -Category 'F: Drive' -CheckKey 'fDrive' `
            -Enabled $true -Expected '(info)' -Actual $actualStr -Status 'Info' `
            -Details '' -ErrorMessage $null
    }

    if ($exists) {
        $sizeStr = "$($check.Data.SizeGB) GB total, $($check.Data.FreeSpaceGB) GB free"
        $results += New-QaValidationResult -Category 'F: Drive' -CheckKey 'fDrive' `
            -Enabled $true -Expected '(info)' -Actual $sizeStr -Status 'Info' `
            -Details '' -ErrorMessage $null
    }

    return $results
}

function Test-QaTracerouteCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Traceroute' -CheckKey 'traceroute' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.Traceroute
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Traceroute' -CheckKey 'traceroute' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $target = $check.Data.Target
    $hopCount = $check.Data.HopCount
    $firstHop = $check.Data.FirstHop
    $reachable = $check.Data.Reachable
    $hopsStr = ($check.Data.Hops -join ' -> ')

    # Display full trace info
    $results += New-QaValidationResult -Category 'Trace Path' -CheckKey 'traceroute' `
        -Enabled $true -Expected '(info)' -Actual "$hopCount hops to $target" -Status 'Info' `
        -Details $hopsStr -ErrorMessage $null

    # First-hop backend subnet check
    $firstHopSubnets = $CheckConfig.firstHopBackendSubnets
    if ($firstHopSubnets -and $firstHopSubnets.Count -gt 0 -and $firstHop) {
        $firstHopIsBackend = $false
        foreach ($subnet in $firstHopSubnets) {
            if ($firstHop.StartsWith($subnet)) { $firstHopIsBackend = $true; break }
        }
        $subnetDisplay = ($firstHopSubnets -join ' or ') + 'x.x'
        $results += New-QaValidationResult -Category 'First Hop' -CheckKey 'traceroute' `
            -Enabled $true -Expected "Backend gw ($subnetDisplay)" -Actual $firstHop `
            -Status $(if ($firstHopIsBackend) { 'Pass' } else { 'Fail' }) `
            -Details "Source: $($check.Data.SourceIP) -> First hop: $firstHop" -ErrorMessage $null
    }
    elseif ($firstHopSubnets -and $firstHopSubnets.Count -gt 0 -and -not $firstHop) {
        $results += New-QaValidationResult -Category 'First Hop' -CheckKey 'traceroute' `
            -Enabled $true -Expected 'Backend gateway' -Actual 'No hops returned' -Status 'Fail' `
            -Details 'Traceroute returned no hops' -ErrorMessage $null
    }

    # Reachability
    $results += New-QaValidationResult -Category 'Reachable' -CheckKey 'traceroute' `
        -Enabled $true -Expected 'Yes' -Actual $(if ($reachable) { 'Yes' } else { 'No' }) `
        -Status $(if ($reachable) { 'Pass' } else { 'Warn' }) `
        -Details '' -ErrorMessage $null

    return $results
}

function Test-QaVmwareToolsCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'VMware Tools' -CheckKey 'vmwareTools' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.VMwareTools
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'VMware Tools' -CheckKey 'vmwareTools' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $actual = $check.Data
    $operator = $CheckConfig.operator
    $expected = $CheckConfig.expected

    if (-not $operator -or -not $expected -or $expected -eq '') {
        return New-QaValidationResult -Category 'VMware Tools' -CheckKey 'vmwareTools' `
            -Enabled $true -Expected '(info)' -Actual "$actual" -Status 'Info' `
            -Details '' -ErrorMessage $null
    }

    $pass = Compare-QaValue -Actual $actual -Expected $expected -Operator $operator
    $expectedDisplay = Get-OperatorDisplay -Operator $operator -Value $expected

    New-QaValidationResult -Category 'VMware Tools' -CheckKey 'vmwareTools' `
        -Enabled $true -Expected $expectedDisplay -Actual "$actual" `
        -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
        -Details '' -ErrorMessage $null
}

function Test-QaOuPathCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'OU Path' -CheckKey 'ouPath' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.OuPath
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'OU Path' -CheckKey 'ouPath' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $results = @()
    $canonicalName = $check.Data.CanonicalName
    $dn = $check.Data.DistinguishedName

    $operator = $CheckConfig.operator
    $expected = $CheckConfig.expected

    if (-not $expected -or $expected -eq '') {
        $results += New-QaValidationResult -Category 'OU Path' -CheckKey 'ouPath' `
            -Enabled $true -Expected '(info)' -Actual $canonicalName -Status 'Info' `
            -Details "DN: $dn" -ErrorMessage $null
        return $results
    }

    # Compare against CanonicalName
    $pass = Compare-QaValue -Actual $canonicalName -Expected $expected -Operator $operator
    if (-not $pass) {
        # Also try against DistinguishedName
        $pass = Compare-QaValue -Actual $dn -Expected $expected -Operator $operator
    }
    $expectedDisplay = Get-OperatorDisplay -Operator $operator -Value $expected

    $results += New-QaValidationResult -Category 'OU Path' -CheckKey 'ouPath' `
        -Enabled $true -Expected $expectedDisplay -Actual $canonicalName `
        -Status $(if ($pass) { 'Pass' } else { 'Fail' }) `
        -Details "DN: $dn" -ErrorMessage $null

    return $results
}

function Test-QaWinActivationCheck {
    param($ServerData, $CheckConfig)

    if (-not $CheckConfig.enabled) {
        return New-QaValidationResult -Category 'Windows Activation' -CheckKey 'winActivation' `
            -Enabled $false -Expected '' -Actual '' -Status 'Skip' -Details 'Check disabled' -ErrorMessage $null
    }

    $check = $ServerData.WinActivation
    if (-not $check.Success) {
        return New-QaValidationResult -Category 'Windows Activation' -CheckKey 'winActivation' `
            -Enabled $true -Expected '' -Actual 'Error' -Status 'Error' `
            -Details $check.ErrorMessage -ErrorMessage $check.ErrorMessage
    }

    $raw = $check.Data
    # Determine if activated: any form of "activated" in slmgr output is a pass
    $isActivated = $raw -match 'activated'
    $displayStatus = if ($raw -match 'permanently activated') { 'Permanently Activated' }
                     elseif ($raw -match 'expir') { 'Activated (Expiring)' }
                     elseif ($raw -match 'notification mode') { 'Not Activated (Notification Mode)' }
                     else { $raw }

    New-QaValidationResult -Category 'Windows Activation' -CheckKey 'winActivation' `
        -Enabled $true -Expected 'Activated' -Actual $displayStatus `
        -Status $(if ($isActivated) { 'Pass' } else { 'Fail' }) `
        -Details '' -ErrorMessage $null
}

# --- Main validation function ---

function Invoke-QaValidation {
    <#
    .SYNOPSIS
        Validates collected server data against a check template.
    .PARAMETER ServerData
        The PSCustomObject returned by Get-QaServerData.
    .PARAMETER Template
        The template object loaded from a JSON template file.
    .OUTPUTS
        Array of PSCustomObject validation results.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ServerData,

        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Template
    )

    $checks = $Template.checks
    $results = @()

    $results += Test-QaConnectivityCheck     -ServerData $ServerData -CheckConfig $checks.connectivity
    $results += Test-QaWinActivationCheck   -ServerData $ServerData -CheckConfig $checks.winActivation
    $results += Test-QaCpuCheck              -ServerData $ServerData -CheckConfig $checks.cpu
    $results += Test-QaMemoryCheck           -ServerData $ServerData -CheckConfig $checks.memoryGB
    $results += Test-QaSoftwareCheck         -ServerData $ServerData -CheckConfig $checks.installedSoftware
    $results += Test-QaIpConfigCheck         -ServerData $ServerData -CheckConfig $checks.ipConfig
    $results += Test-QaLocalAdminsCheck      -ServerData $ServerData -CheckConfig $checks.localAdmins
    $results += Test-QaHotfixCheck           -ServerData $ServerData -CheckConfig $checks.recentHotfixes
    $results += Test-QaDrivePermissionsCheck -ServerData $ServerData -CheckConfig $checks.drivePermissions
    $results += Test-QaFDriveCheck           -ServerData $ServerData -CheckConfig $checks.fDrive
    $results += Test-QaTracerouteCheck       -ServerData $ServerData -CheckConfig $checks.traceroute
    $results += Test-QaVmwareToolsCheck      -ServerData $ServerData -CheckConfig $checks.vmwareTools
    $results += Test-QaOuPathCheck           -ServerData $ServerData -CheckConfig $checks.ouPath

    return $results
}

Export-ModuleMember -Function Invoke-QaValidation
