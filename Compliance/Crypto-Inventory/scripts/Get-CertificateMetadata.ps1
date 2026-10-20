#Requires -Version 5.1

function Get-CertificateMetadata {
    <#
    .SYNOPSIS
        Collects PKI / certificate metadata from local or remote Windows servers.

    .DESCRIPTION
        Opens the LocalMachine certificate stores on each target over PowerShell Remoting
        and returns one object per certificate with the fields requested for the PKI /
        Certificate Metadata data call:

          - Common name and subject alternative names
          - Serial number and issuing certificate authority
          - Public-key algorithm and key size / curve
          - Signature algorithm
          - Valid-from and expiration dates
          - Certificate status
          - Associated hostname/FQDN, IP address, application/service, certificate store,
            and (when supplied) asset/CI identifier, environment and owner

        Application/service is discovered from HTTP.sys SSL bindings (IIS, WinRM HTTPS,
        SSTP), the RDP listener and SQL Server's configured certificate.

        Metadata only. No private keys, key containers, passwords or other key material are
        read or returned; HasPrivateKey is a yes/no flag.

    .PARAMETER ComputerName
        Target servers. Accepts pipeline input, including objects with a ComputerName,
        Name, DNSHostName, Server or HostName property (e.g. Import-Csv, Get-ADComputer).
        Defaults to the local machine.

    .PARAMETER Credential
        Credential for the remote connection. Omit to use the current session's identity.

    .PARAMETER StoreName
        LocalMachine stores to read. Defaults to the stores that hold service certificates.
        Add 'Root', 'CA' or others to include trust anchors and intermediates.

    .PARAMETER ExpiringDays
        Certificates expiring within this many days are reported as ExpiringSoon.

    .PARAMETER VerifyChain
        Builds the chain with an online revocation check and reports Revoked/Untrusted in
        Status and the raw result in ChainStatus. Slower; each URL fetch times out at 10s.

    .PARAMETER AssetId
        Asset / CI identifier stamped onto every result for this target.

    .PARAMETER Environment
        Environment (Prod, Dev, ...) stamped onto every result for this target.

    .PARAMETER Owner
        Owner stamped onto every result for this target.

    .PARAMETER ThrottleLimit
        Maximum concurrent remote connections.

    .EXAMPLE
        $cred = Get-Credential
        Get-CertificateMetadata -ComputerName web01, web02 -Credential $cred |
            Format-Table ComputerName, CommonName, PublicKeyAlgorithm, KeySize, SignatureAlgorithm, NotAfter, Status, Services -AutoSize

    .EXAMPLE
        # servers.csv columns: ComputerName, AssetId, Environment, Owner
        Import-Csv .\servers.csv | Get-CertificateMetadata -Credential $cred |
            Export-Csv .\CertificateMetadata.csv -NoTypeInformation

    .EXAMPLE
        Get-CertificateMetadata -ComputerName app01 -StoreName My, Root, CA -VerifyChain |
            Where-Object Status -ne 'Valid' | Out-GridView
    #>
    [CmdletBinding()]
    [OutputType('NCSTA.CertificateMetadata')]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Name', 'DNSHostName', 'Server', 'HostName')]
        [string[]]$ComputerName = $env:COMPUTERNAME,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,

        [string[]]$StoreName = @('My', 'WebHosting', 'Remote Desktop'),

        [ValidateRange(0, 3650)]
        [int]$ExpiringDays = 30,

        [switch]$VerifyChain,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('CI', 'CIId', 'AssetTag')]
        [string]$AssetId,

        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Env')]
        [string]$Environment,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string]$Owner,

        [ValidateRange(1, 256)]
        [int]$ThrottleLimit = 32
    )

    begin {
        # Runs on each target. Must be self-contained: no references to caller functions.
        $collector = {
            param([string[]]$StoreName, [int]$ExpiringDays, [bool]$VerifyChain)

            function ConvertFrom-DerOid([byte[]]$Bytes) {
                # Decodes a DER-encoded OBJECT IDENTIFIER (used for the ECC curve parameter).
                if (-not $Bytes -or $Bytes.Length -lt 3 -or $Bytes[0] -ne 0x06) { return $null }
                $parts = @([int][math]::Floor($Bytes[2] / 40), ($Bytes[2] % 40))
                [long]$value = 0
                for ($i = 3; $i -lt (2 + $Bytes[1]) -and $i -lt $Bytes.Length; $i++) {
                    $value = ($value -shl 7) -bor ($Bytes[$i] -band 0x7F)
                    if (($Bytes[$i] -band 0x80) -eq 0) { $parts += $value; $value = 0 }
                }
                $parts -join '.'
            }

            $now = Get-Date

            # --- Host identity -------------------------------------------------------
            $fqdn = $env:COMPUTERNAME
            try {
                $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                if ($cs.PartOfDomain) { $fqdn = '{0}.{1}' -f $cs.DNSHostName, $cs.Domain }
            } catch {}

            $ipAddress = try {
                @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' -ErrorAction Stop |
                    ForEach-Object { $_.IPAddress } |
                    Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notlike '169.254.*' }) -join ', '
            } catch { $null }

            # --- Service bindings: thumbprint -> list of service labels ---------------
            $services = @{}
            function Add-Service([string]$Thumbprint, [string]$Label) {
                $key = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
                if (-not $key) { return }
                if (-not $services.ContainsKey($key)) { $services[$key] = New-Object System.Collections.Generic.List[string] }
                if (-not $services[$key].Contains($Label)) { $services[$key].Add($Label) }
            }

            # IIS https bindings, so HTTP.sys endpoints can be named by site
            $iisBindings = @()
            $appHostConfig = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
            if (Test-Path -LiteralPath $appHostConfig) {
                try {
                    [xml]$appHost = Get-Content -LiteralPath $appHostConfig -Raw -ErrorAction Stop
                    foreach ($site in $appHost.configuration.'system.applicationHost'.sites.site) {
                        foreach ($binding in @($site.bindings.binding)) {
                            if ($binding -and $binding.protocol -eq 'https' -and
                                $binding.bindingInformation -match '^(?<ip>.*):(?<port>\d+):(?<host>[^:]*)$') {
                                $iisBindings += [pscustomobject]@{
                                    Site = $site.name; Ip = $Matches.ip; Port = $Matches.port; Host = $Matches.host
                                }
                            }
                        }
                    }
                } catch {}
            }

            # HTTP.sys SSL bindings (IIS, WinRM HTTPS, SSTP, other HTTP.sys apps)
            $endpointType = $null; $endpoint = $null; $hash = $null
            foreach ($line in @(& netsh.exe http show sslcert 2>$null)) {
                if ($line -match '^\s*(?<type>IP:port|Hostname:port|Central Certificate Store)\s*:\s*(?<ep>.+?)\s*$') {
                    $endpointType = $Matches.type; $endpoint = $Matches.ep; $hash = $null
                } elseif ($line -match '^\s*Certificate Hash\s*:\s*(?<hash>[0-9A-Fa-f]+)') {
                    $hash = $Matches.hash
                } elseif ($hash -and $line -match '^\s*Application ID\s*:\s*(?<app>\{[0-9A-Fa-f-]+\})') {
                    $appId = $Matches.app.ToLowerInvariant()
                    $label = switch ($appId) {
                        '{4dc3e181-e14b-4a21-b022-59fc669b0914}' {
                            $sites = @()
                            if ($endpoint -match '^(?<addr>.*):(?<port>\d+)$') {
                                $addr = $Matches.addr; $port = $Matches.port
                                $sites = @($iisBindings | Where-Object {
                                    $_.Port -eq $port -and (
                                        ($endpointType -eq 'Hostname:port' -and $_.Host -eq $addr) -or
                                        ($endpointType -eq 'IP:port' -and ($_.Ip -eq $addr -or ($_.Ip -eq '*' -and $addr -in '0.0.0.0', '[::]'))))
                                } | Select-Object -ExpandProperty Site -Unique)
                            }
                            if ($sites) { 'IIS: {0} ({1})' -f ($sites -join ' / '), $endpoint } else { "IIS ($endpoint)" }
                        }
                        '{afebb9ad-9b97-4a91-9ab5-daf4d59c08d6}' { "WinRM HTTPS ($endpoint)" }
                        '{ba195980-cd49-458b-9e23-c84ee0adcd75}' { "SSTP VPN ($endpoint)" }
                        default { "HTTP.sys $appId ($endpoint)" }
                    }
                    Add-Service $hash $label
                    $hash = $null
                }
            }

            # RDP listener certificate
            try {
                foreach ($ts in @(Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TSGeneralSetting -ErrorAction Stop)) {
                    if ($ts.SSLCertificateSHA1Hash) { Add-Service $ts.SSLCertificateSHA1Hash "RDP ($($ts.TerminalName))" }
                }
            } catch {}

            # SQL Server forced-encryption certificate, per instance
            $sqlRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
            if (Test-Path -LiteralPath $sqlRoot) {
                foreach ($instanceKey in @(Get-ChildItem -LiteralPath $sqlRoot -ErrorAction SilentlyContinue)) {
                    if ($instanceKey.PSChildName -notmatch '^MSSQL\d+\.(?<inst>.+)$') { continue }
                    $instance = $Matches.inst
                    $netLib = Join-Path $instanceKey.PSPath 'MSSQLServer\SuperSocketNetLib'
                    $thumb = (Get-ItemProperty -LiteralPath $netLib -Name Certificate -ErrorAction SilentlyContinue).Certificate
                    if ($thumb) { Add-Service $thumb "SQL Server ($instance)" }
                }
            }

            # --- Certificates --------------------------------------------------------
            $curveBits = @{ '1.2.840.10045.3.1.7' = 256; '1.3.132.0.34' = 384; '1.3.132.0.35' = 521 }
            $openFlags = [System.Security.Cryptography.X509Certificates.OpenFlags]'ReadOnly, OpenExistingOnly'

            foreach ($name in $StoreName) {
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
                try { $store.Open($openFlags) } catch { continue }   # store not present on this host

                try {
                    foreach ($cert in $store.Certificates) {
                        # Names
                        $commonName = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
                        $issuerName = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)

                        $san = $null
                        $sanExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
                        if ($sanExt) {
                            $san = @($sanExt.Format($true) -split '\r?\n' | Where-Object { $_.Trim() } | ForEach-Object {
                                $_.Trim() -replace '^DNS Name=', 'DNS:' -replace '^IP Address=', 'IP:' -replace '^RFC822 Name=', 'Email:' -replace '^URL=', 'URI:'
                            }) -join ', '
                        }

                        # Public key
                        $keyOid = $cert.PublicKey.Oid.Value
                        $keyAlgorithm = if ($cert.PublicKey.Oid.FriendlyName) { $cert.PublicKey.Oid.FriendlyName } else { $keyOid }
                        $keySize = $null; $curve = $null
                        switch ($keyOid) {
                            '1.2.840.113549.1.1.1' {
                                try { $keySize = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert).KeySize }
                                catch { try { $keySize = $cert.PublicKey.Key.KeySize } catch {} }
                            }
                            '1.2.840.10045.2.1' {
                                $curveOid = ConvertFrom-DerOid $cert.PublicKey.EncodedParameters.RawData
                                if ($curveOid) {
                                    $friendly = (New-Object System.Security.Cryptography.Oid($curveOid)).FriendlyName
                                    $curve = if ($friendly) { $friendly } else { $curveOid }
                                }
                                try { $keySize = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($cert).KeySize } catch {}
                                if (-not $keySize -and $curveOid -and $curveBits.ContainsKey($curveOid)) { $keySize = $curveBits[$curveOid] }
                            }
                            default { try { $keySize = $cert.PublicKey.Key.KeySize } catch {} }
                        }

                        # Status
                        $status = if ($cert.NotBefore -gt $now) { 'NotYetValid' }
                                  elseif ($cert.NotAfter -lt $now) { 'Expired' }
                                  elseif ($cert.NotAfter -lt $now.AddDays($ExpiringDays)) { 'ExpiringSoon' }
                                  else { 'Valid' }

                        $chainStatus = $null
                        if ($VerifyChain) {
                            $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                            $chain.ChainPolicy.RevocationMode = 'Online'
                            $chain.ChainPolicy.RevocationFlag = 'ExcludeRoot'
                            $chain.ChainPolicy.UrlRetrievalTimeout = [timespan]::FromSeconds(10)
                            try {
                                if ($chain.Build($cert)) {
                                    $chainStatus = 'OK'
                                } else {
                                    $codes = @($chain.ChainStatus | ForEach-Object { $_.Status.ToString() } | Select-Object -Unique)
                                    $chainStatus = $codes -join ', '
                                    if ($status -in 'Valid', 'ExpiringSoon') {
                                        if ($codes -contains 'Revoked') { $status = 'Revoked' }
                                        elseif (@($codes | Where-Object { $_ -notin 'RevocationStatusUnknown', 'OfflineRevocation' }).Count) { $status = 'Untrusted' }
                                    }
                                }
                            } catch { $chainStatus = "Error: $($_.Exception.Message)" }
                            finally { $chain.Reset() }
                        }

                        # Usage / template
                        $ekuExt = $cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] } | Select-Object -First 1
                        $eku = if ($ekuExt) { @($ekuExt.EnhancedKeyUsages | ForEach-Object { if ($_.FriendlyName) { $_.FriendlyName } else { $_.Value } }) -join ', ' }

                        $template = $null
                        $tplExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.21.7' } | Select-Object -First 1
                        if ($tplExt -and $tplExt.Format($false) -match 'Template=(?<t>[^(,]+)') { $template = $Matches.t.Trim() }
                        else {
                            $tplExt = $cert.Extensions | Where-Object { $_.Oid.Value -eq '1.3.6.1.4.1.311.20.2' } | Select-Object -First 1
                            if ($tplExt) { $template = $tplExt.Format($false).Trim() }
                        }

                        $thumbprint = $cert.Thumbprint.ToUpperInvariant()

                        [pscustomobject][ordered]@{
                            ComputerName            = $env:COMPUTERNAME
                            FQDN                    = $fqdn
                            IPAddress               = $ipAddress
                            CertificateStore        = "LocalMachine\$name"
                            CommonName              = $commonName
                            SubjectAlternativeNames = $san
                            Subject                 = $cert.Subject
                            IssuingCA               = $issuerName
                            Issuer                  = $cert.Issuer
                            SerialNumber            = $cert.SerialNumber
                            Thumbprint              = $thumbprint
                            PublicKeyAlgorithm      = $keyAlgorithm
                            KeySize                 = $keySize
                            Curve                   = $curve
                            SignatureAlgorithm      = $cert.SignatureAlgorithm.FriendlyName
                            SignatureAlgorithmOid   = $cert.SignatureAlgorithm.Value
                            ValidFrom               = $cert.NotBefore
                            Expiration              = $cert.NotAfter
                            DaysRemaining           = [int][math]::Floor(($cert.NotAfter - $now).TotalDays)
                            Status                  = $status
                            ChainStatus             = $chainStatus
                            Services                = if ($services.ContainsKey($thumbprint)) { $services[$thumbprint] -join '; ' } else { $null }
                            EnhancedKeyUsage        = $eku
                            Template                = $template
                            FriendlyName            = $cert.FriendlyName
                            HasPrivateKey           = $cert.HasPrivateKey
                        }
                    }
                } finally { $store.Close() }
            }
        }

        $propertyOrder = @(
            'ComputerName', 'FQDN', 'IPAddress', 'CertificateStore', 'CommonName', 'SubjectAlternativeNames',
            'Subject', 'IssuingCA', 'Issuer', 'SerialNumber', 'Thumbprint', 'PublicKeyAlgorithm', 'KeySize',
            'Curve', 'SignatureAlgorithm', 'SignatureAlgorithmOid', 'ValidFrom', 'Expiration', 'DaysRemaining',
            'Status', 'ChainStatus', 'Services', 'EnhancedKeyUsage', 'Template', 'FriendlyName', 'HasPrivateKey'
        )
        $localNames = @('.', 'localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)
        $targets = @{}   # target name -> asset metadata (keys are case-insensitive)
    }

    process {
        foreach ($computer in $ComputerName) {
            if ([string]::IsNullOrWhiteSpace($computer)) { continue }
            $targets[$computer.Trim()] = @{ AssetId = $AssetId; Environment = $Environment; Owner = $Owner }
        }
    }

    end {
        $collectorArgs = @($StoreName, $ExpiringDays, $VerifyChain.IsPresent)
        $hasCredential = $Credential -ne [System.Management.Automation.PSCredential]::Empty

        $local = @(); $remote = @()
        foreach ($name in $targets.Keys) {
            $isLocal = $name -in $localNames -or $name -like "$env:COMPUTERNAME.*"
            if ($isLocal -and -not $hasCredential) { $local += $name } else { $remote += $name }
        }

        $results = New-Object System.Collections.Generic.List[object]

        foreach ($name in $local) {
            foreach ($row in (& $collector @collectorArgs)) { $results.Add([pscustomobject]@{ Target = $name; Row = $row }) }
        }

        if ($remote) {
            $invokeParams = @{
                ComputerName  = $remote
                ScriptBlock   = $collector
                ArgumentList  = $collectorArgs
                ThrottleLimit = $ThrottleLimit
                ErrorAction   = 'SilentlyContinue'
                ErrorVariable = 'remoteErrors'
            }
            if ($hasCredential) { $invokeParams.Credential = $Credential }

            foreach ($row in (Invoke-Command @invokeParams)) { $results.Add([pscustomobject]@{ Target = $row.PSComputerName; Row = $row }) }

            foreach ($err in $remoteErrors) {
                $failed = if ($err.OriginInfo) { $err.OriginInfo.PSComputerName } else { $err.TargetObject }
                Write-Warning "${failed}: $($err.Exception.Message)"
            }
        }

        foreach ($result in $results) {
            $out = [ordered]@{ PSTypeName = 'NCSTA.CertificateMetadata' }
            foreach ($property in $propertyOrder) { $out[$property] = $result.Row.$property }
            $meta = $targets[$result.Target]
            $out.AssetId     = if ($meta) { $meta.AssetId } else { $null }
            $out.Environment = if ($meta) { $meta.Environment } else { $null }
            $out.Owner       = if ($meta) { $meta.Owner } else { $null }
            [pscustomobject]$out
        }
    }
}
