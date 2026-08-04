Set-StrictMode -Version Latest

function Get-SchUseStrongCryptoStatus {
    [CmdletBinding()]
    param()

    $paths = @(
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v2.0.50727'; Framework = '.NET Framework 2.0/3.5'; Architecture = '64-bit' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319'; Framework = '.NET Framework 4.x'; Architecture = '64-bit' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v2.0.50727'; Framework = '.NET Framework 2.0/3.5'; Architecture = '32-bit' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319'; Framework = '.NET Framework 4.x'; Architecture = '32-bit' }
    )

    foreach ($item in $paths) {
        $value = $null
        if (Test-Path -LiteralPath $item.Path) {
            $value = (Get-ItemProperty -LiteralPath $item.Path -Name SchUseStrongCrypto -ErrorAction SilentlyContinue).SchUseStrongCrypto
        }

        [pscustomobject]@{
            PSTypeName         = 'ServerProtocolAudit.StrongCrypto'
            Framework          = $item.Framework
            Architecture       = $item.Architecture
            SchUseStrongCrypto = $value
            Enabled            = ($value -eq 1)
            Configuration      = if ($null -eq $value) { 'NotConfigured' } else { 'Explicit' }
            RegistryPath       = $item.Path
        }
    }
}

function Get-SchannelProtocolStatus {
    [CmdletBinding()]
    param()

    $protocols = 'SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2', 'TLS 1.3'

    foreach ($protocol in $protocols) {
        foreach ($role in 'Server', 'Client') {
            $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol\$role"
            $properties = if (Test-Path -LiteralPath $path) {
                Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
            }
            else {
                $null
            }

            $enabledValue = if ($null -ne $properties -and $properties.PSObject.Properties.Name -contains 'Enabled') {
                [int]$properties.Enabled
            }
            else {
                $null
            }
            $disabledByDefault = if ($null -ne $properties -and $properties.PSObject.Properties.Name -contains 'DisabledByDefault') {
                [int]$properties.DisabledByDefault
            }
            else {
                $null
            }

            $effectiveEnabled = if ($enabledValue -eq 0) {
                $false
            }
            elseif ($enabledValue -eq 1) {
                $true
            }
            elseif ($disabledByDefault -eq 1) {
                $false
            }
            else {
                $null
            }

            [pscustomobject]@{
                PSTypeName        = 'ServerProtocolAudit.Protocol'
                Protocol          = $protocol
                Role              = $role
                Enabled           = $effectiveEnabled
                Configuration     = if ($null -eq $enabledValue -and $null -eq $disabledByDefault) { 'OSDefault' } else { 'Explicit' }
                EnabledValue      = $enabledValue
                DisabledByDefault = $disabledByDefault
                RegistryPath      = $path
                RestartRequired   = $false
            }
        }
    }
}

function Get-ServerCipherSuiteOrder {
    [CmdletBinding()]
    param()

    $getTlsCipherSuite = Get-Command -Name Get-TlsCipherSuite -ErrorAction SilentlyContinue
    if ($null -eq $getTlsCipherSuite) {
        throw 'Get-TlsCipherSuite is unavailable. Run this command on Windows Server 2016 / Windows 10 or newer.'
    }

    $protocolNames = @{
        768   = 'SSL 3.0'
        769   = 'TLS 1.0'
        770   = 'TLS 1.1'
        771   = 'TLS 1.2'
        772   = 'TLS 1.3'
        65277 = 'DTLS 1.2'
        65279 = 'DTLS 1.0'
    }

    # This cmdlet returns a generic List as one pipeline object on some Windows
    # builds, so explicitly enumerate it before assigning preference positions.
    $suites = @(Get-TlsCipherSuite | ForEach-Object { $_ })
    $position = 0
    foreach ($suite in $suites) {
        $position++
        $reasons = [System.Collections.Generic.List[string]]::new()
        if ($suite.CipherLength -eq 0 -or $suite.Name -match '_NULL_') {
            $reasons.Add('No encryption')
        }
        if ($suite.Name -match '(^|_)RC4_|(^|_)RC2_|(^|_)DES_') {
            $reasons.Add('Legacy cipher')
        }
        if ($suite.Exchange -eq 'RSA') {
            $reasons.Add('Static RSA key exchange')
        }
        if ($suite.Hash -eq 'SHA1' -or $suite.Name -match '_CBC_') {
            $reasons.Add('Legacy CBC/SHA-1 construction')
        }

        $assessment = if ($reasons -contains 'No encryption' -or $reasons -contains 'Legacy cipher') {
            'Weak'
        }
        elseif ($reasons.Count -gt 0) {
            'Review'
        }
        else {
            'Preferred'
        }

        [pscustomobject]@{
            PSTypeName = 'ServerProtocolAudit.CipherSuite'
            Order      = $position
            Name       = $suite.Name
            Protocols  = @($suite.Protocols | ForEach-Object {
                    if ($protocolNames.ContainsKey([int]$_)) { $protocolNames[[int]$_] } else { [string]$_ }
                })
            Cipher     = $suite.Cipher
            CipherLength = $suite.CipherLength
            Hash       = $suite.Hash
            HashLength = $suite.HashLength
            Exchange   = $suite.Exchange
            Certificate = $suite.Certificate
            Assessment = $assessment
            Findings   = ($reasons -join '; ')
        }
    }
}

function Get-ServerProtocolSummary {
    [CmdletBinding()]
    param()

    $protocols = @(Get-SchannelProtocolStatus | Where-Object Role -eq 'Server')
    $ciphers = @(Get-ServerCipherSuiteOrder)
    $enabled = @($protocols | Where-Object { $_.Configuration -eq 'Explicit' -and $_.Enabled } | Select-Object -ExpandProperty Protocol)
    $disabled = @($protocols | Where-Object { $_.Configuration -eq 'Explicit' -and -not $_.Enabled } | Select-Object -ExpandProperty Protocol)
    $osDefault = @($protocols | Where-Object Configuration -eq 'OSDefault' | Select-Object -ExpandProperty Protocol)
    $weak = @($ciphers | Where-Object Assessment -eq 'Weak')
    $review = @($ciphers | Where-Object Assessment -eq 'Review')

    [pscustomobject]@{
        PSTypeName        = 'ServerProtocolAudit.Summary'
        ActionRequired    = if ($weak.Count -gt 0 -or $review.Count -gt 0 -or $osDefault.Count -gt 0) { 'Yes' } else { 'No' }
        EnabledProtocols  = if ($enabled.Count) { $enabled -join ', ' } else { 'None explicit' }
        DisabledProtocols = if ($disabled.Count) { $disabled -join ', ' } else { 'None explicit' }
        OSDefaultCount    = $osDefault.Count
        CipherCount       = $ciphers.Count
        WeakCiphers       = $weak.Count
        ReviewCiphers     = $review.Count
    }
}

function Get-ServerProtocolAudit {
    <#
    .SYNOPSIS
    Returns the local server's SCHANNEL protocol state and TLS cipher-suite order.

    .DESCRIPTION
    Reads effective local SCHANNEL protocol policy and the Windows TLS cipher-suite
    list. The command is read-only and makes no hardening changes.

    .PARAMETER IncludeStrongCrypto
    Includes .NET Framework SchUseStrongCrypto registry status.

    .EXAMPLE
    Get-ServerProtocolAudit

    .EXAMPLE
    Get-ServerProtocolAudit -View Protocol

    .EXAMPLE
    Get-ServerProtocolAudit -View CipherSuite | Export-Csv .\ciphers.csv -NoTypeInformation
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Summary', 'All', 'Protocol', 'CipherSuite')]
        [string]$View = 'All',

        [switch]$IncludeStrongCrypto
    )

    if ($View -eq 'Summary') {
        Get-ServerProtocolSummary
    }
    if ($View -in 'All', 'Protocol') {
        Get-SchannelProtocolStatus
    }
    if ($View -in 'All', 'CipherSuite') {
        Get-ServerCipherSuiteOrder
    }
    if ($IncludeStrongCrypto) {
        Get-SchUseStrongCryptoStatus
    }
}

function Get-Cipher {
    <#
    .SYNOPSIS
    Audits TLS/SSL protocols and cipher-suite order on one or more Windows servers.

    .DESCRIPTION
    Runs a read-only SCHANNEL audit locally or through PowerShell remoting.

    By default, Get-Cipher returns one compact summary row per computer. Use the
    View parameter to return detailed protocol records, cipher-suite records, or
    all available records. Every result includes ComputerName for filtering,
    grouping, and export.

    Remote computers require PowerShell remoting (WinRM) and appropriate access.

    .PARAMETER ComputerName
    One or more Windows computer names, FQDNs, or IP addresses.

    Accepts strings from the pipeline and objects whose property is named
    ComputerName, CN, Server, or Name. Use localhost, a dot, or the local computer
    name to run without PowerShell remoting.

    .PARAMETER View
    Controls the type of information returned:

    Summary     One compact row per computer. This is the default.
    Protocol    SSL/TLS client and server protocol configuration.
    CipherSuite Effective cipher-suite preference order and assessments.
    All         Every protocol and cipher-suite record.

    .PARAMETER IncludeStrongCrypto
    Includes the .NET Framework SchUseStrongCrypto registry status.

    .PARAMETER Credential
    Optional credential used for remote PowerShell sessions.

    .EXAMPLE
    Get-Cipher server1.domain.com

    Displays the default summary for one remote server.

    .EXAMPLE
    Get-Cipher server1.domain.com, server2.domain.com

    Displays one summary row for each server supplied as an array.

    .EXAMPLE
    $servers = @('server1.domain.com', 'server2.domain.com')
    $servers | Get-Cipher

    Sends an array of server names to Get-Cipher through the pipeline.

    .EXAMPLE
    'server1.domain.com', 'server2.domain.com' | Get-Cipher -View CipherSuite

    Returns the detailed cipher-suite order for each server.

    .EXAMPLE
    Import-Csv .\servers.csv | Get-Cipher -View Protocol

    Audits objects imported from a CSV containing a ComputerName column.

    .EXAMPLE
    Get-Cipher server1.domain.com -IncludeStrongCrypto

    Includes .NET Framework strong-cryptography settings with the audit.

    .EXAMPLE
    Get-Cipher server1.domain.com -Credential (Get-Credential)

    Uses alternate credentials for the remote PowerShell connection.

    .INPUTS
    System.String

    You can pipe computer-name strings to this command.

    System.Management.Automation.PSObject

    You can pipe objects containing a ComputerName, CN, Server, or Name property.

    .OUTPUTS
    ServerProtocolAudit.Summary
    ServerProtocolAudit.Protocol
    ServerProtocolAudit.CipherSuite
    ServerProtocolAudit.StrongCrypto

    .NOTES
    Discover command usage with:

    Get-Help Get-Cipher
    Get-Help Get-Cipher -Examples
    Get-Help Get-Cipher -Full
    Get-Command Get-Cipher -Syntax

    The command is read-only and does not modify protocols or cipher suites.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'Server', 'Name')]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName = @($env:COMPUTERNAME),

        [ValidateSet('Summary', 'All', 'Protocol', 'CipherSuite')]
        [string]$View = 'Summary',

        [switch]$IncludeStrongCrypto,

        [pscredential]$Credential
    )

    begin {
        $modulePath = $PSScriptRoot
    }

    process {
        foreach ($computer in $ComputerName) {
            $isLocal = $computer -in '.', 'localhost', $env:COMPUTERNAME

            if ($isLocal) {
                $results = Get-ServerProtocolAudit -View $View -IncludeStrongCrypto:$IncludeStrongCrypto
            }
            else {
                $invokeParameters = @{
                    ComputerName = $computer
                    ErrorAction  = 'Stop'
                    ScriptBlock  = {
                        param($RequestedView, $RequestStrongCrypto, $ModuleSource)

                        $temporaryModule = Join-Path $env:TEMP ('ServerProtocolAudit-{0}.psm1' -f [guid]::NewGuid())
                        try {
                            Set-Content -LiteralPath $temporaryModule -Value $ModuleSource -Encoding UTF8
                            Import-Module $temporaryModule -Force
                            Get-ServerProtocolAudit -View $RequestedView -IncludeStrongCrypto:$RequestStrongCrypto
                        }
                        finally {
                            Remove-Module ([System.IO.Path]::GetFileNameWithoutExtension($temporaryModule)) -ErrorAction SilentlyContinue
                            Remove-Item -LiteralPath $temporaryModule -Force -ErrorAction SilentlyContinue
                        }
                    }
                    ArgumentList = @(
                        $View,
                        [bool]$IncludeStrongCrypto,
                        (Get-Content -LiteralPath (Join-Path $modulePath 'ServerProtocolAudit.psm1') -Raw)
                    )
                }
                if ($PSBoundParameters.ContainsKey('Credential')) {
                    $invokeParameters.Credential = $Credential
                }

                try {
                    $results = Invoke-Command @invokeParameters
                }
                catch {
                    Write-Error -Message "Unable to audit '$computer': $($_.Exception.Message)" -ErrorId 'GetCipher.RemoteAuditFailed' -Category ConnectionError -TargetObject $computer
                    continue
                }
            }

            foreach ($result in $results) {
                $output = [ordered]@{ ComputerName = $computer }
                foreach ($property in $result.PSObject.Properties) {
                    if ($property.Name -notin 'PSComputerName', 'RunspaceId', 'PSShowComputerName') {
                        $output[$property.Name] = $property.Value
                    }
                }
                $finalResult = [pscustomobject]$output
                $sourceType = @($result.PSObject.TypeNames | Where-Object {
                        $_ -like '*ServerProtocolAudit.*'
                    } | Select-Object -First 1)
                if ($sourceType.Count) {
                    $finalResult.PSObject.TypeNames.Insert(0, ($sourceType[0] -replace '^Deserialized\.', ''))
                }
                $finalResult
            }
        }
    }
}

Export-ModuleMember -Function Get-Cipher, Get-ServerProtocolAudit
