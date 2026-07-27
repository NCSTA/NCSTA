<#
.SYNOPSIS
    Phase 1 dependency audit for Windows Server retirement automation.

.DESCRIPTION
    Imports server_retirement.csv, validates WinRM connectivity to each target
    server, runs Test-ServerRetirementEligibility remotely, logs every major
    action, and sends one HTML notification per server when active dependencies
    are detected.

    Required CSV columns:
    Servername,change,Distro,datetoretire,alias

    HTML email color palette:
    - Teal/Primary Accent: #007b86
    - Light Gray Background: #f4f4f4
    - White Content Cards: #ffffff
#>

[CmdletBinding()]
param()

# ==========================================
# CONFIGURATION AND USER VARIABLES
# ==========================================
$CSVPath       = Join-Path -Path $PSScriptRoot -ChildPath 'server_retirement.csv'
$LogDirectory  = Join-Path -Path $PSScriptRoot -ChildPath 'Logs'
$LogFile       = Join-Path -Path $LogDirectory -ChildPath ("Retirement_Phase1_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

# SMTP variables. Leave $SMTPServer blank until your relay details are ready.
$SMTPServer    = ''
$SMTPPort      = 25
$EmailFrom     = 'server-retirement@yourcompany.com'
$EmailCc       = ''
$EmailUseSsl   = $false
$SmtpCredential = $null
$EmailDetailRowLimit = 5

# Optional PSRemoting credential. Leave $null to use the current security context.
$PSRemotingCredential = $null
$PSRemotingAuthentication = 'Default'

# Timeout is in milliseconds.
$WinRmOperationTimeoutMilliseconds = 180000

# Native enterprise management agents commonly excluded from dependency results.
$NativeProcessExclusionList = @(
    'System',
    'TaniumCX',
    'TaniumClient',
    'nessus-agent-module',
    'ccmexec',
    'Splunkd',
    'venPlatformHandler'
)

# Exclude noisy TCP computers by IP, FQDN, short hostname, or wildcard.
# Example: @('10.10.20.30', 'scanner01.contoso.com', 'scanner02', 'pentest-*')
$TcpComputerExclusionList = @()

$ExcludedSmbShareNamePatterns = @(
    '^ADMIN\$$',
    '^IPC\$$',
    '^print\$$',
    '^[A-Z]\$$'
)

$RequiredCsvColumns = @('Servername', 'change', 'Distro', 'datetoretire', 'alias')

# ==========================================
# HELPER FUNCTIONS
# ==========================================
function Initialize-RetirementLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    }
}

function Write-RetirementLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = '[{0}] [{1}] {2}' -f $timestamp, $Level, $Message

    try {
        $entry | Out-File -FilePath $script:LogFile -Append -Encoding utf8 -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to write to log file {0}: {1}" -f $script:LogFile, $_.Exception.Message)
    }

    $color = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        default   { 'White' }
    }
    Write-Host $entry -ForegroundColor $color
}

function Assert-RetirementCsvSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$RequiredColumns
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Target CSV file not found at path: $Path"
    }

    $headerLine = Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($headerLine)) {
        throw "Target CSV file is empty: $Path"
    }

    $columns = @(
        $headerLine -split ',' |
            ForEach-Object { $_.Trim().Trim('"') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $missingColumns = @(
        foreach ($requiredColumn in $RequiredColumns) {
            if ($columns -notcontains $requiredColumn) {
                $requiredColumn
            }
        }
    )

    if ($missingColumns.Count -gt 0) {
        throw "Target CSV is missing required column(s): $($missingColumns -join ', ')"
    }
}

function Get-CollectionCount {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return 0
    }

    $count = 0
    foreach ($item in $InputObject) {
        if ($null -ne $item) {
            $count++
        }
    }

    return $count
}

function Format-RetirementDateDisplay {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'Not provided'
    }

    $parsedDate = [datetime]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $dateStyles = [System.Globalization.DateTimeStyles]::AssumeLocal
    [string[]]$knownFormats = @(
        'M/d/yyyy',
        'MM/dd/yyyy',
        'M-d-yyyy',
        'MM-dd-yyyy',
        'yyyy-MM-dd',
        'yyyyMMdd',
        'MMddyyyy',
        'M/d/yy',
        'MM/dd/yy',
        'M-d-yy',
        'MM-dd-yy'
    )

    if ($text -match '^\d{8}$') {
        [string[]]$compactFormats = @('MMddyyyy', 'yyyyMMdd')
        if ([datetime]::TryParseExact($text, $compactFormats, $culture, $dateStyles, [ref]$parsedDate)) {
            return $parsedDate.ToString('MM/dd/yyyy', $culture)
        }
    }

    if ([datetime]::TryParseExact($text, $knownFormats, $culture, $dateStyles, [ref]$parsedDate)) {
        return $parsedDate.ToString('MM/dd/yyyy', $culture)
    }

    if ([datetime]::TryParse($text, [ref]$parsedDate)) {
        return $parsedDate.ToString('MM/dd/yyyy', $culture)
    }

    return $text
}

function ConvertTo-HtmlEncodedString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $Value = @($Value) -join ', '
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-MailAddressList {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Addresses
    )

    @(
        foreach ($address in @($Addresses)) {
            ([string]$address) -split '[;,]' |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    )
}

function ConvertTo-RetirementAliasRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$AliasText
    )

    $aliases = @(
        ([string]$AliasText) -split '[,;\r\n]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )

    if ($aliases.Count -eq 0) {
        return [PSCustomObject]@{
            Alias = 'No aliases provided in CSV'
        }
    }

    foreach ($alias in $aliases) {
        [PSCustomObject]@{
            Alias = $alias
        }
    }
}

function ConvertTo-RetirementHtmlTable {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter()]
        [ValidateRange(0, 1000)]
        [int]$MaxRows = 5
    )

    $rows = @(
        foreach ($item in $InputObject) {
            if ($null -ne $item) {
                $item
            }
        }
    )

    if ($rows.Count -eq 0) {
        return ''
    }

    $displayRows = if ($MaxRows -eq 0) {
        @($rows)
    }
    else {
        @($rows | Select-Object -First $MaxRows)
    }

    $properties = @($displayRows[0].PSObject.Properties | Select-Object -ExpandProperty Name)
    if ($properties.Count -eq 0) {
        return ''
    }

    $encodedTitle = ConvertTo-HtmlEncodedString -Value $Title
    $rowSummary = if ($MaxRows -eq 0) {
        "Showing all $($displayRows.Count)"
    }
    else {
        "Showing first $($displayRows.Count) of $($rows.Count)"
    }
    $encodedRowSummary = ConvertTo-HtmlEncodedString -Value $rowSummary
    $builder = [System.Text.StringBuilder]::new()

    [void]$builder.AppendLine("<h3 style='Margin:26px 0 8px 0;margin:26px 0 8px 0;font-family:Segoe UI,Arial,sans-serif;font-size:16px;line-height:22px;color:#007b86;'>$encodedTitle</h3>")
    [void]$builder.AppendLine("<p style='Margin:0 0 8px 0;margin:0 0 8px 0;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;color:#007b86;'>$encodedRowSummary</p>")
    [void]$builder.AppendLine("<table role='presentation' width='100%' cellpadding='0' cellspacing='0' border='0' style='width:100%;border-collapse:collapse;background-color:#ffffff;margin:0 0 18px 0;'>")
    [void]$builder.AppendLine("<tr style='background-color:#007b86;color:#ffffff;'>")

    foreach ($property in $properties) {
        $encodedProperty = ConvertTo-HtmlEncodedString -Value $property
        [void]$builder.AppendLine("<th align='left' style='padding:10px;border:1px solid #f4f4f4;text-align:left;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;color:#ffffff;'>$encodedProperty</th>")
    }

    [void]$builder.AppendLine('</tr>')

    foreach ($row in $displayRows) {
        [void]$builder.AppendLine("<tr style='background-color:#ffffff;'>")
        foreach ($property in $properties) {
            $encodedValue = ConvertTo-HtmlEncodedString -Value $row.$property
            [void]$builder.AppendLine("<td valign='top' style='padding:10px;border:1px solid #f4f4f4;vertical-align:top;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;'>$encodedValue</td>")
        }
        [void]$builder.AppendLine('</tr>')
    }

    [void]$builder.AppendLine('</table>')
    return $builder.ToString()
}

function Test-ServerWinRmConnectivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [AllowNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [ValidateSet('Default', 'Basic', 'Negotiate', 'Credssp', 'Digest', 'Kerberos')]
        [string]$Authentication = 'Default'
    )

    $testParams = @{
        ComputerName = $ServerName
        ErrorAction  = 'Stop'
    }

    if ($null -ne $Credential) {
        $testParams.Credential = $Credential
        $testParams.Authentication = $Authentication
    }

    try {
        Test-WSMan @testParams | Out-Null
        return [PSCustomObject]@{
            Succeeded    = $true
            ErrorMessage  = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Succeeded    = $false
            ErrorMessage  = $_.Exception.Message
        }
    }
}

function Invoke-ServerRetirementAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string[]]$NativeProcessExclusionList,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$TcpComputerExclusionList,

        [Parameter(Mandatory = $true)]
        [string[]]$ExcludedSmbShareNamePatterns,

        [AllowNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [ValidateSet('Default', 'Basic', 'Negotiate', 'Credssp', 'Digest', 'Kerberos')]
        [string]$Authentication = 'Default',

        [Parameter(Mandatory = $true)]
        [int]$OperationTimeoutMilliseconds
    )

    $remoteAuditScript = {
        param(
            [string[]]$NativeProcessExclusionList,
            [string[]]$TcpComputerExclusionList,
            [string[]]$ExcludedSmbShareNamePatterns
        )

        function Resolve-RemoteHostName {
            [CmdletBinding()]
            param(
                [AllowNull()]
                [string]$NameOrAddress
            )

            if ([string]::IsNullOrWhiteSpace($NameOrAddress)) {
                return ''
            }

            try {
                return ([System.Net.Dns]::GetHostEntry($NameOrAddress)).HostName
            }
            catch {
                return $NameOrAddress
            }
        }

        function Get-ProcessOwnerName {
            [CmdletBinding()]
            param(
                [Parameter(Mandatory = $true)]
                [int]$ProcessId
            )

            if ($ProcessId -le 0) {
                return 'Unknown'
            }

            try {
                $processCim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
                $owner = Invoke-CimMethod -InputObject $processCim -MethodName GetOwner -ErrorAction Stop
                if ($owner.User) {
                    return ('{0}\{1}' -f $owner.Domain, $owner.User)
                }
            }
            catch {
                return 'Unknown'
            }

            return 'Unknown'
        }

        function Get-TcpComputerComparisonValue {
            [CmdletBinding()]
            param(
                [AllowNull()]
                [string]$Value
            )

            $text = ([string]$Value).Trim()
            if ([string]::IsNullOrWhiteSpace($text)) {
                return @()
            }

            $values = [System.Collections.Generic.List[string]]::new()
            $values.Add($text)

            [System.Net.IPAddress]$ipAddress = $null
            if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ipAddress) -and $text -like '*.*') {
                $values.Add(($text -split '\.')[0])
            }

            return @($values | Select-Object -Unique)
        }

        function Test-IsExcludedTcpComputer {
            [CmdletBinding()]
            param(
                [AllowNull()]
                [string]$RemoteAddress,

                [AllowNull()]
                [string]$Computer,

                [string[]]$TcpComputerExclusionList
            )

            if ($null -eq $TcpComputerExclusionList -or $TcpComputerExclusionList.Count -eq 0) {
                return $false
            }

            $computerValues = @(
                Get-TcpComputerComparisonValue -Value $RemoteAddress
                Get-TcpComputerComparisonValue -Value $Computer
            ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

            foreach ($excludedComputer in @($TcpComputerExclusionList)) {
                if ([string]::IsNullOrWhiteSpace($excludedComputer)) {
                    continue
                }

                $excludedValues = Get-TcpComputerComparisonValue -Value $excludedComputer
                $hasWildcard = [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($excludedComputer)

                foreach ($computerValue in $computerValues) {
                    if ($hasWildcard -and $computerValue -like $excludedComputer) {
                        return $true
                    }

                    foreach ($excludedValue in $excludedValues) {
                        if ($computerValue -ieq $excludedValue) {
                            return $true
                        }
                    }
                }
            }

            return $false
        }

        function Test-IsExcludedSmbShareName {
            [CmdletBinding()]
            param(
                [AllowNull()]
                [string]$ShareName,

                [string[]]$ExcludedSmbShareNamePatterns
            )

            if ([string]::IsNullOrWhiteSpace($ShareName)) {
                return $true
            }

            foreach ($pattern in @($ExcludedSmbShareNamePatterns)) {
                if ($ShareName -match $pattern) {
                    return $true
                }
            }

            return $false
        }

        function Test-ServerRetirementEligibility {
            [CmdletBinding()]
            param(
                [string[]]$NativeProcessExclusionList,
                [string[]]$TcpComputerExclusionList,
                [string[]]$ExcludedSmbShareNamePatterns
            )

            $collectorErrors = [System.Collections.Generic.List[string]]::new()
            $collectorWarnings = [System.Collections.Generic.List[string]]::new()

            $ipv4Addresses = @()
            try {
                $ipv4Addresses = @(
                    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
                        Where-Object {
                            $_.IPAddress -ne '127.0.0.1' -and
                            $_.IPAddress -notlike '169.254*'
                        } |
                        Sort-Object -Property InterfaceIndex, IPAddress |
                        Select-Object -ExpandProperty IPAddress
                )
            }
            catch {
                $collectorWarnings.Add("IPv4 address collection failed: $($_.Exception.Message)")
            }

            $fqdn = $env:COMPUTERNAME
            try {
                $fqdn = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
            }
            catch {
                $collectorWarnings.Add("FQDN lookup failed: $($_.Exception.Message)")
            }

            $externalConnections = @()
            try {
                $tcpConnections = @(
                    Get-NetTCPConnection -State Established -ErrorAction Stop |
                        Where-Object {
                            $_.LocalPort -ne 445 -and
                            $_.RemotePort -ne 445 -and
                            $_.RemoteAddress -notin @('127.0.0.1', '::1', '0.0.0.0', '::')
                        }
                )

                $externalConnections = @(
                    foreach ($connection in $tcpConnections) {
                        $processId = [int]$connection.OwningProcess
                        $processName = 'Unknown'

                        try {
                            if ($processId -gt 0) {
                                $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                                if ($null -ne $process) {
                                    $processName = $process.ProcessName
                                }
                            }
                        }
                        catch {
                            $processName = 'Unknown'
                        }

                        if ($NativeProcessExclusionList -contains $processName) {
                            continue
                        }

                        $remoteAddress = [string]$connection.RemoteAddress
                        $computer = Resolve-RemoteHostName -NameOrAddress $remoteAddress
                        if (Test-IsExcludedTcpComputer -RemoteAddress $remoteAddress -Computer $computer -TcpComputerExclusionList $TcpComputerExclusionList) {
                            continue
                        }

                        [PSCustomObject]@{
                            ProcessName    = $processName
                            ProcessId      = $processId
                            UserId         = Get-ProcessOwnerName -ProcessId $processId
                            Computer       = $computer
                            RemoteAddress  = $remoteAddress
                            RemotePort     = $connection.RemotePort
                            LocalAddress   = [string]$connection.LocalAddress
                            LocalPort      = $connection.LocalPort
                        }
                    }
                )
            }
            catch {
                $collectorErrors.Add("External TCP connection collection failed: $($_.Exception.Message)")
            }

            $customSmbShares = @()
            try {
                $customSmbShares = @(
                    Get-SmbShare -ErrorAction Stop |
                        Where-Object {
                            -not (Test-IsExcludedSmbShareName -ShareName $_.Name -ExcludedSmbShareNamePatterns $ExcludedSmbShareNamePatterns)
                        } |
                        Select-Object -Property Name, Path, Description, CurrentUsers
                )
            }
            catch {
                $collectorWarnings.Add("SMB share collection failed: $($_.Exception.Message)")
            }

            $openSmbSessions = @()
            try {
                if (-not (Get-Command -Name Get-SmbSession -ErrorAction SilentlyContinue)) {
                    throw 'Get-SmbSession cmdlet is not available.'
                }

                $openSmbSessions = @(
                    Get-SmbSession -ErrorAction Stop |
                        ForEach-Object {
                            [PSCustomObject]@{
                                ClientComputerName = Resolve-RemoteHostName -NameOrAddress ([string]$_.ClientComputerName)
                                ClientUserName     = $_.ClientUserName
                                OpenFileCount      = $_.NumOpens
                                SecondsExists      = $_.SecondsExists
                                Dialect            = $_.Dialect
                                Encrypted          = $_.Encrypted
                                SessionId          = $_.SessionId
                            }
                        }
                )
            }
            catch {
                $primaryError = $_.Exception.Message
                try {
                    $openSmbSessions = @(
                        Get-CimInstance -ClassName Win32_ServerConnection -ErrorAction Stop |
                            ForEach-Object {
                                [PSCustomObject]@{
                                    ClientComputerName = Resolve-RemoteHostName -NameOrAddress ([string]$_.ComputerName)
                                    ClientUserName     = $_.UserName
                                    ShareName          = $_.ShareName
                                    OpenFileCount      = $_.NumberOfFiles
                                    SessionSource      = 'Win32_ServerConnection'
                                }
                            }
                    )
                    $collectorWarnings.Add("Get-SmbSession failed, used Win32_ServerConnection fallback: $primaryError")
                }
                catch {
                    $collectorErrors.Add("SMB session collection failed. Get-SmbSession error: $primaryError. Win32_ServerConnection error: $($_.Exception.Message)")
                }
            }

            $openFileSessions = @()
            try {
                if (-not (Get-Command -Name Get-SmbOpenFile -ErrorAction SilentlyContinue)) {
                    throw 'Get-SmbOpenFile cmdlet is not available.'
                }

                $openFileSessions = @(
                    Get-SmbOpenFile -ErrorAction Stop |
                        ForEach-Object {
                            [PSCustomObject]@{
                                Computer          = Resolve-RemoteHostName -NameOrAddress ([string]$_.ClientComputerName)
                                FilePath          = $_.Path
                                ShareRelativePath = $_.ShareRelativePath
                                UserId            = $_.ClientUserName
                                Permissions       = $_.Permissions
                                Locks             = $_.Locks
                            }
                        }
                )
            }
            catch {
                $collectorErrors.Add("Open SMB file collection failed: $($_.Exception.Message)")
            }

            [PSCustomObject]@{
                ServerInfo = [PSCustomObject]@{
                    Hostname      = $env:COMPUTERNAME
                    Fqdn          = $fqdn
                    IPv4Addresses = $ipv4Addresses -join ', '
                    AuditDateTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                }
                ExternalConnections = $externalConnections
                CustomSmbShares     = $customSmbShares
                OpenSmbSessions     = $openSmbSessions
                OpenFileSessions    = $openFileSessions
                CollectorWarnings   = @($collectorWarnings)
                CollectorErrors     = @($collectorErrors)
            }
        }

        Test-ServerRetirementEligibility `
            -NativeProcessExclusionList $NativeProcessExclusionList `
            -TcpComputerExclusionList $TcpComputerExclusionList `
            -ExcludedSmbShareNamePatterns $ExcludedSmbShareNamePatterns
    }

    $sessionOption = New-PSSessionOption -OperationTimeout $OperationTimeoutMilliseconds
    $invokeParams = @{
        ComputerName  = $ServerName
        ScriptBlock   = $remoteAuditScript
        ArgumentList  = $NativeProcessExclusionList, $TcpComputerExclusionList, $ExcludedSmbShareNamePatterns
        SessionOption = $sessionOption
        ErrorAction   = 'Stop'
    }

    if ($null -ne $Credential) {
        $invokeParams.Credential = $Credential
        $invokeParams.Authentication = $Authentication
    }

    Invoke-Command @invokeParams
}

function New-RetirementEmailBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter(Mandatory = $true)]
        [string]$ChangeTicket,

        [Parameter(Mandatory = $true)]
        [string]$RetireDate,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ServerAliases,

        [Parameter(Mandatory = $true)]
        [object]$AuditResult
    )

    $encodedServerName = ConvertTo-HtmlEncodedString -Value $ServerName
    $encodedChangeTicket = ConvertTo-HtmlEncodedString -Value $ChangeTicket
    $displayRetireDate = Format-RetirementDateDisplay -Value $RetireDate
    $encodedRetireDate = ConvertTo-HtmlEncodedString -Value $displayRetireDate

    $externalConnectionCount = Get-CollectionCount -InputObject $AuditResult.ExternalConnections
    $openSmbSessionCount = Get-CollectionCount -InputObject $AuditResult.OpenSmbSessions
    $openFileSessionCount = Get-CollectionCount -InputObject $AuditResult.OpenFileSessions
    $customSmbShareCount = Get-CollectionCount -InputObject $AuditResult.CustomSmbShares

    $serverAliasRows = ConvertTo-RetirementAliasRows -AliasText $ServerAliases
    $serverAliasTable = ConvertTo-RetirementHtmlTable -InputObject $serverAliasRows -Title 'Server Aliases' -MaxRows 0
    $externalConnectionTable = ConvertTo-RetirementHtmlTable -InputObject $AuditResult.ExternalConnections -Title 'Active Processes and TCP Connections' -MaxRows $EmailDetailRowLimit
    $customSmbShareTable = ConvertTo-RetirementHtmlTable -InputObject $AuditResult.CustomSmbShares -Title 'SMB Shares' -MaxRows $EmailDetailRowLimit
    $openSmbSessionTable = ConvertTo-RetirementHtmlTable -InputObject $AuditResult.OpenSmbSessions -Title 'Open SMB Sessions' -MaxRows $EmailDetailRowLimit
    $openFileSessionTable = ConvertTo-RetirementHtmlTable -InputObject $AuditResult.OpenFileSessions -Title 'Open File Sessions' -MaxRows $EmailDetailRowLimit

    @"
<!DOCTYPE html>
<html xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta http-equiv="x-ua-compatible" content="ie=edge" />
    <title>Server Retirement Dependency Notification</title>
    <!--[if mso]>
    <noscript>
        <xml>
            <o:OfficeDocumentSettings>
                <o:PixelsPerInch>96</o:PixelsPerInch>
            </o:OfficeDocumentSettings>
        </xml>
    </noscript>
    <![endif]-->
</head>
<body style="Margin:0;margin:0;padding:0;background-color:#f4f4f4;">
    <div style="display:none;font-size:1px;line-height:1px;color:#f4f4f4;max-height:0;max-width:0;opacity:0;overflow:hidden;mso-hide:all;">
        Active dependencies were detected for $encodedServerName before the scheduled retirement date.
    </div>
    <center style="width:100%;background-color:#f4f4f4;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;background-color:#f4f4f4;">
            <tr>
                <td align="center" style="padding:24px 12px;">
                    <!--[if mso]>
                    <table role="presentation" align="center" width="900" cellpadding="0" cellspacing="0" border="0">
                        <tr>
                            <td>
                    <![endif]-->
                    <table role="presentation" align="center" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:900px;border-collapse:collapse;background-color:#ffffff;">
                        <tr>
                            <td bgcolor="#007b86" style="background-color:#007b86;padding:22px 28px;">
                                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;">
                                    <tr>
                                        <td>
                                            <p style="Margin:0 0 6px 0;margin:0 0 6px 0;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;color:#ffffff;mso-line-height-rule:exactly;">WINDOWS SERVER RETIREMENT - PHASE 1</p>
                                            <h1 style="Margin:0;margin:0;font-family:Segoe UI,Arial,sans-serif;font-size:24px;line-height:30px;color:#ffffff;font-weight:700;mso-line-height-rule:exactly;">$encodedChangeTicket retire $encodedServerName</h1>
                                        </td>
                                    </tr>
                                </table>
                            </td>
                        </tr>
                        <tr>
                            <td bgcolor="#ffffff" style="background-color:#ffffff;padding:24px 28px 8px 28px;">
                                <p style="Margin:0 0 14px 0;margin:0 0 14px 0;font-family:Segoe UI,Arial,sans-serif;font-size:14px;line-height:21px;mso-line-height-rule:exactly;">Hello Team, you submitted server retirement for <strong>$encodedServerName</strong> under change control <strong>$encodedChangeTicket</strong>. This server is scheduled to be powered off on <strong>$encodedRetireDate</strong>.</p>
                                <p style="Margin:0 0 18px 0;margin:0 0 18px 0;font-family:Segoe UI,Arial,sans-serif;font-size:14px;line-height:21px;mso-line-height-rule:exactly;">However, the following active dependencies or open sessions were detected during the Phase 1 retirement audit. Please review and remediate these connections before the retirement date to avoid service interruption.</p>

                                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;background-color:#f4f4f4;">
                                    <tr>
                                        <td style="padding:12px;border-left:6px solid #007b86;font-family:Segoe UI,Arial,sans-serif;font-size:13px;line-height:18px;mso-line-height-rule:exactly;">
                                            Status: Active dependencies detected. Production owners should validate the rows below before approving power-off.
                                        </td>
                                    </tr>
                                </table>

                                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;margin:18px 0 0 0;background-color:#ffffff;">
                                    <tr>
                                        <td width="33.33%" valign="top" style="width:33.33%;padding:10px;border:1px solid #f4f4f4;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;mso-line-height-rule:exactly;">
                                            <strong>Server</strong><br />$encodedServerName
                                        </td>
                                        <td width="33.33%" valign="top" style="width:33.33%;padding:10px;border:1px solid #f4f4f4;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;mso-line-height-rule:exactly;">
                                            <strong>Change</strong><br />$encodedChangeTicket
                                        </td>
                                        <td width="33.33%" valign="top" style="width:33.33%;padding:10px;border:1px solid #f4f4f4;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;mso-line-height-rule:exactly;">
                                            <strong>Power-off Date</strong><br />$encodedRetireDate
                                        </td>
                                    </tr>
                                </table>

                                $serverAliasTable

                                <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;margin:18px 0;background-color:#ffffff;">
                                    <tr>
                                        <td width="25%" valign="top" bgcolor="#f4f4f4" style="width:25%;background-color:#f4f4f4;padding:14px;border:6px solid #ffffff;font-family:Segoe UI,Arial,sans-serif;mso-line-height-rule:exactly;">
                                            <p style="Margin:0 0 8px 0;margin:0 0 8px 0;font-size:12px;line-height:16px;">Active Processes/TCP</p>
                                            <p style="Margin:0;margin:0;font-size:28px;line-height:32px;color:#007b86;font-weight:700;">$externalConnectionCount</p>
                                        </td>
                                        <td width="25%" valign="top" bgcolor="#f4f4f4" style="width:25%;background-color:#f4f4f4;padding:14px;border:6px solid #ffffff;font-family:Segoe UI,Arial,sans-serif;mso-line-height-rule:exactly;">
                                            <p style="Margin:0 0 8px 0;margin:0 0 8px 0;font-size:12px;line-height:16px;">SMB Shares</p>
                                            <p style="Margin:0;margin:0;font-size:28px;line-height:32px;color:#007b86;font-weight:700;">$customSmbShareCount</p>
                                        </td>
                                        <td width="25%" valign="top" bgcolor="#f4f4f4" style="width:25%;background-color:#f4f4f4;padding:14px;border:6px solid #ffffff;font-family:Segoe UI,Arial,sans-serif;mso-line-height-rule:exactly;">
                                            <p style="Margin:0 0 8px 0;margin:0 0 8px 0;font-size:12px;line-height:16px;">Open SMB Sessions</p>
                                            <p style="Margin:0;margin:0;font-size:28px;line-height:32px;color:#007b86;font-weight:700;">$openSmbSessionCount</p>
                                        </td>
                                        <td width="25%" valign="top" bgcolor="#f4f4f4" style="width:25%;background-color:#f4f4f4;padding:14px;border:6px solid #ffffff;font-family:Segoe UI,Arial,sans-serif;mso-line-height-rule:exactly;">
                                            <p style="Margin:0 0 8px 0;margin:0 0 8px 0;font-size:12px;line-height:16px;">Open File Sessions</p>
                                            <p style="Margin:0;margin:0;font-size:28px;line-height:32px;color:#007b86;font-weight:700;">$openFileSessionCount</p>
                                        </td>
                                    </tr>
                                </table>

                                $externalConnectionTable
                                $customSmbShareTable
                                $openSmbSessionTable
                                $openFileSessionTable

                                <p style="Margin:20px 0 12px 0;margin:20px 0 12px 0;font-family:Segoe UI,Arial,sans-serif;font-size:14px;line-height:21px;mso-line-height-rule:exactly;">If these connections are expected, reroute or close them before the target power-off date and update the retirement change record accordingly.</p>
                            </td>
                        </tr>
                        <tr>
                            <td bgcolor="#f4f4f4" align="center" style="background-color:#f4f4f4;padding:14px 24px;text-align:center;font-family:Segoe UI,Arial,sans-serif;font-size:12px;line-height:16px;mso-line-height-rule:exactly;">
                                Domain and Windows Server Team Automated Notification
                            </td>
                        </tr>
                    </table>
                    <!--[if mso]>
                            </td>
                        </tr>
                    </table>
                    <![endif]-->
                </td>
            </tr>
        </table>
    </center>
</body>
</html>
"@
}

function Send-RetirementEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$To,

        [Parameter()]
        [AllowEmptyString()]
        [string]$Cc = '',

        [Parameter(Mandatory = $true)]
        [string]$From,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$BodyHtml,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$SmtpServer,

        [Parameter(Mandatory = $true)]
        [int]$SmtpPort,

        [Parameter(Mandatory = $true)]
        [bool]$UseSsl,

        [AllowNull()]
        [System.Management.Automation.PSCredential]$Credential
    )

    if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
        throw 'SMTP server is blank. Populate $SMTPServer before enabling production notifications.'
    }

    $recipients = @(ConvertTo-MailAddressList -Addresses $To)
    $ccRecipients = @(ConvertTo-MailAddressList -Addresses $Cc)

    if ($recipients.Count -eq 0) {
        throw 'No valid recipient address was provided.'
    }

    $message = [System.Net.Mail.MailMessage]::new()
    $smtpClient = $null

    try {
        $message.From = [System.Net.Mail.MailAddress]::new($From)
        foreach ($recipient in $recipients) {
            $message.To.Add($recipient)
        }

        foreach ($ccRecipient in $ccRecipients) {
            $message.CC.Add($ccRecipient)
        }

        $message.Subject = $Subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $BodyHtml
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $true

        $smtpClient = [System.Net.Mail.SmtpClient]::new($SmtpServer, $SmtpPort)
        $smtpClient.EnableSsl = $UseSsl

        if ($null -ne $Credential) {
            $smtpClient.UseDefaultCredentials = $false
            $smtpClient.Credentials = $Credential.GetNetworkCredential()
        }

        $smtpClient.Send($message)
    }
    finally {
        if ($null -ne $smtpClient) {
            $smtpClient.Dispose()
        }
        $message.Dispose()
    }
}

function Get-RequiredTextValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Fallback
    )

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $Fallback
    }

    return $text
}

# ==========================================
# MAIN ROUTINE
# ==========================================
$processedCount = 0
$clearCount = 0
$dependencyCount = 0
$skippedCount = 0
$emailSentCount = 0
$errorCount = 0

try {
    Initialize-RetirementLog -Directory $LogDirectory

    Write-RetirementLog '========================================================='
    Write-RetirementLog 'Starting Server Retirement Phase 1 dependency scan loop.'
    Write-RetirementLog '========================================================='
    Write-RetirementLog "CSV path: $CSVPath"
    Write-RetirementLog "Log file: $LogFile"

    Write-RetirementLog 'Validating CSV path and required column schema.'
    Assert-RetirementCsvSchema -Path $CSVPath -RequiredColumns $RequiredCsvColumns

    Write-RetirementLog 'Importing CSV retirement target list.'
    $serverList = @(Import-Csv -LiteralPath $CSVPath -ErrorAction Stop)
    if ($serverList.Count -eq 0) {
        Write-RetirementLog "CSV contains headers but no server rows: $CSVPath" -Level WARN
    }

    foreach ($row in $serverList) {
        $processedCount++

        $serverName = Get-RequiredTextValue -Value $row.Servername -Fallback ''
        $distroGroup = Get-RequiredTextValue -Value $row.Distro -Fallback ''
        $changeTicket = Get-RequiredTextValue -Value $row.change -Fallback 'Not provided'
        $retireDate = Get-RequiredTextValue -Value $row.datetoretire -Fallback 'Not provided'
        $serverAliases = Get-RequiredTextValue -Value $row.alias -Fallback ''

        if ([string]::IsNullOrWhiteSpace($serverName) -or [string]::IsNullOrWhiteSpace($distroGroup)) {
            $skippedCount++
            Write-RetirementLog 'Skipping CSV row because Servername or Distro is blank.' -Level WARN
            continue
        }

        Write-RetirementLog "Processing target server: $serverName"
        Write-RetirementLog "Checking WinRM/PSRemoting connectivity for $serverName."

        $connectivity = Test-ServerWinRmConnectivity `
            -ServerName $serverName `
            -Credential $PSRemotingCredential `
            -Authentication $PSRemotingAuthentication
        if (-not $connectivity.Succeeded) {
            $skippedCount++
            $errorCount++
            Write-RetirementLog "WinRM connectivity failed for $serverName. Skipping server. Error: $($connectivity.ErrorMessage)" -Level ERROR
            continue
        }

        Write-RetirementLog "WinRM connectivity confirmed for $serverName." -Level SUCCESS

        try {
            Write-RetirementLog "Executing remote Test-ServerRetirementEligibility audit on $serverName."
            $auditResult = Invoke-ServerRetirementAudit `
                -ServerName $serverName `
                -NativeProcessExclusionList $NativeProcessExclusionList `
                -TcpComputerExclusionList $TcpComputerExclusionList `
                -ExcludedSmbShareNamePatterns $ExcludedSmbShareNamePatterns `
                -Credential $PSRemotingCredential `
                -Authentication $PSRemotingAuthentication `
                -OperationTimeoutMilliseconds $WinRmOperationTimeoutMilliseconds

            if ($null -eq $auditResult) {
                throw "Remote audit returned no data for $serverName."
            }

            foreach ($warning in @($auditResult.CollectorWarnings)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                    Write-RetirementLog "Audit warning for $serverName`: $warning" -Level WARN
                }
            }

            $collectorErrorCount = Get-CollectionCount -InputObject $auditResult.CollectorErrors
            if ($collectorErrorCount -gt 0) {
                foreach ($collectorError in @($auditResult.CollectorErrors)) {
                    Write-RetirementLog "Audit collector error for $serverName`: $collectorError" -Level ERROR
                }
                throw "Remote audit did not complete all required collectors for $serverName."
            }

            $externalConnectionCount = Get-CollectionCount -InputObject $auditResult.ExternalConnections
            $openSmbSessionCount = Get-CollectionCount -InputObject $auditResult.OpenSmbSessions
            $openFileSessionCount = Get-CollectionCount -InputObject $auditResult.OpenFileSessions
            $customSmbShareCount = Get-CollectionCount -InputObject $auditResult.CustomSmbShares

            Write-RetirementLog ("Audit summary for {0} -> External Connections: {1}, Open SMB Sessions: {2}, Open File Sessions: {3}, SMB Shares: {4}" -f $serverName, $externalConnectionCount, $openSmbSessionCount, $openFileSessionCount, $customSmbShareCount)

            if ($externalConnectionCount -eq 0 -and $openSmbSessionCount -eq 0 -and $openFileSessionCount -eq 0) {
                $clearCount++
                Write-RetirementLog "$serverName is clear. Zero active dependencies were detected. No email will be sent." -Level SUCCESS
                continue
            }

            $dependencyCount++
            Write-RetirementLog "Dependencies detected for $serverName. Building one server-specific HTML email notification." -Level WARN

            $bodyHtml = New-RetirementEmailBody `
                -ServerName $serverName `
                -ChangeTicket $changeTicket `
                -RetireDate $retireDate `
                -ServerAliases $serverAliases `
                -AuditResult $auditResult

            $subject = "ACTION REQUIRED: Dependencies Detected on Retirement Target ($serverName) - $changeTicket"

            Write-RetirementLog "Sending dependency notification for $serverName to $distroGroup."
            Send-RetirementEmail `
                -To $distroGroup `
                -Cc $EmailCc `
                -From $EmailFrom `
                -Subject $subject `
                -BodyHtml $bodyHtml `
                -SmtpServer $SMTPServer `
                -SmtpPort $SMTPPort `
                -UseSsl $EmailUseSsl `
                -Credential $SmtpCredential

            $emailSentCount++
            Write-RetirementLog "Notification email sent for $serverName to $distroGroup." -Level SUCCESS
        }
        catch {
            $errorCount++
            Write-RetirementLog "Processing failed for $serverName. Error: $($_.Exception.Message)" -Level ERROR
            continue
        }
    }

    Write-RetirementLog '========================================================='
    Write-RetirementLog ("Server Retirement Phase 1 completed. Processed: {0}, Clear: {1}, Dependencies: {2}, Emails Sent: {3}, Skipped: {4}, Errors: {5}" -f $processedCount, $clearCount, $dependencyCount, $emailSentCount, $skippedCount, $errorCount)
    Write-RetirementLog '========================================================='

    if ($errorCount -gt 0) {
        exit 2
    }

    exit 0
}
catch {
    try {
        Write-RetirementLog "Fatal script error: $($_.Exception.Message)" -Level ERROR
    }
    catch {
        Write-Error "Fatal script error: $($_.Exception.Message)"
    }

    exit 1
}
