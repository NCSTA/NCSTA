Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:RunLogPath=$null
$script:VerboseLoggingEnabled=$false
$script:IsAdmin=$false
$script:RunWarnings=New-Object System.Collections.Generic.List[string]
$script:RunErrors=New-Object System.Collections.Generic.List[string]

function Write-RunLog {
    param([string]$Message,[ValidateSet('INFO','WARN','ERROR')][string]$Level='INFO')
    $t=Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line="${t} [$Level] $Message"
    if($Level -eq 'WARN'){Write-Warning $Message;$script:RunWarnings.Add($Message)|Out-Null}
    elseif($Level -eq 'ERROR'){Write-Error $Message -ErrorAction Continue;$script:RunErrors.Add($Message)|Out-Null}
    elseif($script:VerboseLoggingEnabled){Write-Verbose $Message}
    if($script:RunLogPath){Add-Content -Path $script:RunLogPath -Value $line -Encoding utf8}
}

function Test-IsAdmin {
    try {
        $id=[Security.Principal.WindowsIdentity]::GetCurrent()
        $p=New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { Write-RunLog "Admin check failed: $($_.Exception.Message)" WARN; return $false }
}

function Get-RegistryValueSafe { param([string]$Path,[string]$Name)
    try {(Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name} catch {$null}
}

function Write-JsonFile { param([string]$Path,[object]$Data)
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

function Get-CommandAvailability {
    foreach($n in 'certutil.exe','wevtutil.exe'){
        $c=Get-Command $n -ErrorAction SilentlyContinue
        [pscustomobject]@{Name=$n;Available=[bool]$c}
    }
}

function Get-DeviceInfo {
    $os=Get-CimInstance Win32_OperatingSystem
    $cs=Get-CimInstance Win32_ComputerSystem
    $bios=Get-CimInstance Win32_BIOS
    $nics=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {
        [ordered]@{InterfaceDescription=$_.Description}
    })
    [ordered]@{
        collection_timestamp=(Get-Date).ToString('o')
        identity=[ordered]@{hostname=$env:COMPUTERNAME;domain=$cs.Domain;part_of_domain=[bool]$cs.PartOfDomain;is_admin=$script:IsAdmin;powershell_version=$PSVersionTable.PSVersion.ToString()}
        operating_system=[ordered]@{caption=$os.Caption;version=$os.Version;build_number=$os.BuildNumber;architecture=$os.OSArchitecture;install_date=$(try{[Management.ManagementDateTimeConverter]::ToDateTime($os.InstallDate)}catch{$null});last_boot_up_time=$(try{[Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)}catch{$null})}
        hardware=[ordered]@{manufacturer=$cs.Manufacturer;model=$cs.Model;total_physical_ram=[int64]$cs.TotalPhysicalMemory;logical_processors=$cs.NumberOfLogicalProcessors}
        network=[ordered]@{interface_count=@($nics).Count;interfaces=$nics}
    }
}

function Get-SANData { param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $r=[ordered]@{dns=@();ip=@();upn=@();uri=@();raw=$null}
    try {
        $e=$Certificate.Extensions|Where-Object{$_.Oid.Value -eq '2.5.29.17'}|Select-Object -First 1
        if(-not $e){return $r}
        $f=$e.Format($true);$r.raw=$f
        foreach($p in ($f -split "`r?`n|,\s*")){
            if($p -match 'DNS Name=(.+)$'){$r.dns+=$matches[1].Trim()}
            elseif($p -match 'IP Address=(.+)$'){$r.ip+=$matches[1].Trim()}
            elseif($p -match 'UPN=(.+)$'){$r.upn+=$matches[1].Trim()}
            elseif($p -match 'URL=(.+)$'){$r.uri+=$matches[1].Trim()}
        }
    } catch { Write-RunLog "SAN parse failed $($Certificate.Thumbprint): $($_.Exception.Message)" WARN }
    $r
}

function Get-CertUrlsFromExtension { param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,[string]$Oid)
    $u=@(); try {
        $e=$Certificate.Extensions|Where-Object{$_.Oid.Value -eq $Oid}|Select-Object -First 1
        if($e){$m=[regex]::Matches($e.Format($true),'(https?://[^\s,\r\n]+)');foreach($x in $m){$u+=$x.Groups[1].Value.Trim()}}
    } catch { Write-RunLog "URL parse failed $($Certificate.Thumbprint): $($_.Exception.Message)" WARN }
    $u|Select-Object -Unique
}

function Get-CertificateTemplateInfo { param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $n=$null;$o=$null
    foreach($e in $Certificate.Extensions){if($e.Oid.Value -eq '1.3.6.1.4.1.311.20.2'){$n=$e.Format($false)}elseif($e.Oid.Value -eq '1.3.6.1.4.1.311.21.7'){$o=$e.Format($false)}}
    [ordered]@{template_name=$n;template_oid=$o}
}

function Get-PrivateKeyMetadata { param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $r=[ordered]@{has_private_key=[bool]$Certificate.HasPrivateKey;provider_name=$null;provider_type=$null;key_container_name=$null;unique_key_container_name=$null;key_storage_type=$null;cng_key_name=$null;cng_provider=$null;exportable=$null;key_reference_confidence='none'}
    if(-not $Certificate.HasPrivateKey){return $r}
    try {
        if($Certificate.PrivateKey -and $Certificate.PrivateKey.CspKeyContainerInfo){
            $c=$Certificate.PrivateKey.CspKeyContainerInfo
            $r.provider_name=$c.ProviderName;$r.provider_type=$c.ProviderType;$r.key_container_name=$c.KeyContainerName;$r.unique_key_container_name=$c.UniqueKeyContainerName;$r.key_storage_type='LegacyCSP';$r.exportable=[bool]$c.Exportable;$r.key_reference_confidence='high'; return $r
        }
    } catch {}
    try {
        $k=[System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        if($k -is [System.Security.Cryptography.RSACng]){$r.key_storage_type='CNG';$r.cng_key_name=$k.Key.KeyName;$r.cng_provider=$k.Key.Provider.Provider;$r.provider_name=$k.Key.Provider.Provider;$r.key_container_name=$k.Key.KeyName;$r.exportable=[bool]($k.Key.ExportPolicy.ToString() -match 'AllowExport');$r.key_reference_confidence='medium';return $r}
    } catch {}
    try {
        $k=[System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
        if($k -is [System.Security.Cryptography.ECDsaCng]){$r.key_storage_type='CNG';$r.cng_key_name=$k.Key.KeyName;$r.cng_provider=$k.Key.Provider.Provider;$r.provider_name=$k.Key.Provider.Provider;$r.key_container_name=$k.Key.KeyName;$r.exportable=[bool]($k.Key.ExportPolicy.ToString() -match 'AllowExport');$r.key_reference_confidence='medium';return $r}
    } catch {}
    $r
}

function Get-PublicKeyDetails { param([System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $bits=$null;$curve=$null;$family='Other';$oidName=$Certificate.PublicKey.Oid.FriendlyName;$oidVal=$Certificate.PublicKey.Oid.Value
    try{if($Certificate.PublicKey.Key){$bits=$Certificate.PublicKey.Key.KeySize}}catch{}
    if($oidName -match 'RSA' -or $oidVal -eq '1.2.840.113549.1.1.1'){$family='RSA'}
    elseif($oidName -match 'ECDSA|ECC|EC' -or $oidVal -eq '1.2.840.10045.2.1'){$family='ECC';try{$e=[System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPublicKey($Certificate);if($e -is [System.Security.Cryptography.ECDsaCng]){$curve=$e.Key.AlgorithmGroup}}catch{}}
    elseif($oidName -match 'Ed25519|Ed448'){$family='EdDSA'}
    [ordered]@{public_key_oid=$oidVal;public_key_algorithm=$oidName;public_key_family=$family;public_key_size_bits=$bits;ecc_curve_name=$curve}
}

function Get-CertificateInventory { param([bool]$IncludeCurrentUser)
    $targets=@([ordered]@{Location='LocalMachine';Stores=@('My','Root','CA','AuthRoot','TrustedPeople','TrustedPublisher','WebHosting')})
    if($IncludeCurrentUser){$targets+=[ordered]@{Location='CurrentUser';Stores=@('My','Root','CA','TrustedPeople','TrustedPublisher')}}
    $out=New-Object System.Collections.Generic.List[object]
    foreach($t in $targets){foreach($s in $t.Stores){
        try {
            $store=New-Object System.Security.Cryptography.X509Certificates.X509Store($s,$t.Location)
            $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
            foreach($c in $store.Certificates){
                try {
                    $p=Get-PublicKeyDetails $c; $k=Get-PrivateKeyMetadata $c
                    $eku=@();$ku=$null;$isCa=$null
                    foreach($e in $c.Extensions){
                        if($e -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]){foreach($o in $e.EnhancedKeyUsages){$eku+=[ordered]@{oid=$o.Value;friendly_name=$o.FriendlyName}}}
                        elseif($e -is [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]){$ku=$e.KeyUsages.ToString()}
                        elseif($e -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]){$isCa=[bool]$e.CertificateAuthority}
                    }
                    $out.Add([ordered]@{
                        store_location=$t.Location;store_name=$s;friendly_name=$c.FriendlyName;thumbprint=$c.Thumbprint;not_before=$c.NotBefore;not_after=$c.NotAfter
                        signature_algorithm_name=$c.SignatureAlgorithm.FriendlyName;signature_algorithm_oid=$c.SignatureAlgorithm.Value;public_key=$p;has_private_key=$k.has_private_key
                        private_key=[ordered]@{key_storage_type=$k.key_storage_type;exportable=$k.exportable;key_reference_confidence=$k.key_reference_confidence}
                        enhanced_key_usage=$eku;key_usage_flags=$ku;basic_constraints_is_ca=$isCa;certificate_template=(Get-CertificateTemplateInfo $c)
                    })|Out-Null
                } catch { Write-RunLog "Cert parse failed in $($t.Location)\$s for $($c.Thumbprint): $($_.Exception.Message)" WARN }
            }
            $store.Close()
        } catch { Write-RunLog "Unable to open cert store $($t.Location)\${s}: $($_.Exception.Message)" WARN }
    }}
    $out
}

function Add-CertificateIds {
    param([System.Collections.IEnumerable]$Certificates)
    $i=0
    foreach($c in @($Certificates)){
        $i++
        if($c -is [System.Collections.IDictionary]){
            $c['cert_id']=('cert-{0:d6}' -f $i)
        } else {
            try { Add-Member -InputObject $c -NotePropertyName cert_id -NotePropertyValue ('cert-{0:d6}' -f $i) -Force } catch {}
        }
    }
    @($Certificates)
}

function Remove-CertificateThumbprints {
    param([System.Collections.IEnumerable]$Certificates)
    foreach($c in @($Certificates)){
        if($c -is [System.Collections.IDictionary]){
            if($c.Contains('thumbprint')){ [void]$c.Remove('thumbprint') }
        } else {
            if($c.PSObject.Properties.Match('thumbprint').Count -gt 0){ $c.PSObject.Properties.Remove('thumbprint') }
        }
    }
    @($Certificates)
}

function Get-SchannelPosture {
    $protocols=@();$base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach($p in 'SSL 2.0','SSL 3.0','TLS 1.0','TLS 1.1','TLS 1.2','TLS 1.3'){
        foreach($r in 'Client','Server'){
            $path=Join-Path $base "$p\$r"
            $keyPresent=[bool](Test-Path $path)
            $enabled=Get-RegistryValueSafe $path 'Enabled'
            $disabledByDefault=Get-RegistryValueSafe $path 'DisabledByDefault'
            $protocols+=[ordered]@{
                protocol=$p
                role=$r
                key_present=$keyPresent
                enabled=$enabled
                disabled_by_default=$disabledByDefault
                effective_state=if(-not $keyPresent){'not_explicitly_configured'}elseif($enabled -eq 1){'enabled'}elseif($enabled -eq 0){'disabled'}elseif($disabledByDefault -eq 1){'disabled_by_default'}elseif($disabledByDefault -eq 0){'enabled_by_default'}else{'unknown'}
            }
        }
    }

    $suiteSource='NotDeterminable';$suites=@()
    if(Get-Command Get-TlsCipherSuite -ErrorAction SilentlyContinue){try{$suites=Get-TlsCipherSuite|Select-Object -ExpandProperty Name;$suiteSource='Get-TlsCipherSuite'}catch{}}
    if(-not $suites){$f=Get-RegistryValueSafe 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002' 'Functions';if($f){$suites=@($f -split ',')|ForEach-Object{$_.Trim()}|Where-Object{$_};$suiteSource='RegistryPolicyFunctions'}}

    $cipherOrder=@()
    foreach($p in 'HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\Configuration\SSL\00010002','HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002'){
        $f=Get-RegistryValueSafe $p 'Functions'
        $funcList=if($f){@($f -split ',')|ForEach-Object{$_.Trim()}|Where-Object{$_}}else{@()}
        $cipherOrder+=[ordered]@{configured=[bool]$f;functions=@($funcList)}
    }

    $strong=@(); foreach($p in 'HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319','HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319','HKCU:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319','HKCU:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319'){$strong+=[ordered]@{scope=$p.Replace('HKLM:\','HKLM:').Replace('HKCU:\','HKCU:');sch_use_strong_crypto=(Get-RegistryValueSafe $p 'SchUseStrongCrypto');system_default_tls_versions=(Get-RegistryValueSafe $p 'SystemDefaultTlsVersions')}}

    $curvePath='HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002\ECCCurves';$curves=@();$curveStatus='not_determinable'
    if(Test-Path $curvePath){try{$curveStatus='collected';$curves=Get-ChildItem $curvePath|ForEach-Object{[ordered]@{name=$_.PSChildName;ecc_curve_type=(Get-RegistryValueSafe $_.PSPath 'EccCurveType')}}}catch{}}

    [ordered]@{protocols=$protocols;cipher_suites=[ordered]@{source=$suiteSource;suites=$suites};cipher_order_policy=$cipherOrder;strong_crypto_flags=$strong;ecc_curves=[ordered]@{status=$curveStatus;curves=$curves}}
}

function Get-CryptoProviders {
    $csplist=$null
    try { if(Get-Command certutil.exe -ErrorAction SilentlyContinue){$csplist=& certutil.exe -csplist 2>&1 | Out-String} else {Write-RunLog 'certutil.exe not found.' WARN} } catch { Write-RunLog "certutil -csplist failed: $($_.Exception.Message)" WARN }
    $providerDefaults=@();$providerTypes=@()
    try{$providerDefaults=Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Cryptography\Defaults\Provider' -ErrorAction Stop|Select-Object -ExpandProperty PSChildName}catch{Write-RunLog "Provider defaults read failed: $($_.Exception.Message)" WARN}
    try{$providerTypes=Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Cryptography\Defaults\Provider Types' -ErrorAction Stop|ForEach-Object{[ordered]@{provider_type=$_.PSChildName;name=(Get-RegistryValueSafe $_.PSPath 'Name');type=(Get-RegistryValueSafe $_.PSPath 'Type')}}}catch{Write-RunLog "Provider types read failed: $($_.Exception.Message)" WARN}
    $fipsLocal=Get-RegistryValueSafe 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\FipsAlgorithmPolicy' 'Enabled'
    $fipsPolicy=Get-RegistryValueSafe 'HKLM:\SOFTWARE\Policies\Microsoft\FipsAlgorithmPolicy' 'Enabled'
    [ordered]@{
        provider_defaults=$providerDefaults
        provider_types=$providerTypes
        policies=[ordered]@{
            fips_policy_registry=[ordered]@{local_security_option=$fipsLocal;policy_override=$fipsPolicy;effective_enabled=[bool](($fipsPolicy -eq 1)-or($fipsLocal -eq 1))}
            schannel_policy_categories=@('Hashes','Ciphers','KeyExchangeAlgorithms')
        }
    }
}

function Get-DpapiStatus {
    $providers=@();$policyVals=[ordered]@{}
    $pp='HKLM:\SOFTWARE\Microsoft\Cryptography\Protect\Providers';$pol='HKLM:\SOFTWARE\Policies\Microsoft\Cryptography\DPAPI'
    try{if(Test-Path $pp){$providers=Get-ChildItem $pp|Select-Object -ExpandProperty PSChildName}}catch{Write-RunLog "DPAPI provider read failed: $($_.Exception.Message)" WARN}
    try{if(Test-Path $pol){$item=Get-ItemProperty $pol;foreach($p in $item.PSObject.Properties){if($p.Name -notmatch '^PS'){$policyVals[$p.Name]=$p.Value}}}}catch{Write-RunLog "DPAPI policy read failed: $($_.Exception.Message)" WARN}
    [ordered]@{providers=@($providers);policy_values=$policyVals;notes=@('No secrets are extracted.','Posture indicators only.')}
}

function Get-FileMetadataList { param([string]$Path)
    if(-not (Test-Path $Path)){return [ordered]@{path_exists=$false;file_count=0;total_bytes=0;latest_write_time=$null}}
    $f=@(Get-ChildItem $Path -File -Force -ErrorAction SilentlyContinue|ForEach-Object{[ordered]@{length=$_.Length;last_write_time=$_.LastWriteTimeUtc}})
    $totalBytes=0
    foreach($item in $f){ if($item.Contains('length') -and $item.length){ $totalBytes += [int64]$item.length } }
    [ordered]@{
        path_exists=$true
        file_count=@($f).Count
        total_bytes=[int64]$totalBytes
        latest_write_time=if(@($f).Count -gt 0){(@($f | Sort-Object last_write_time -Descending | Select-Object -First 1).last_write_time)}else{$null}
    }
}

function Get-FileMetadataByPattern {
    param([string]$RootPath,[string[]]$Patterns,[int]$MaxResults=500)
    $items=@()
    if(-not (Test-Path $RootPath)){return @()}
    $count=0
    foreach($pattern in $Patterns){
        try{
            Get-ChildItem -Path $RootPath -Filter $pattern -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if($count -ge $MaxResults){ return }
                $items += [ordered]@{
                    extension=$_.Extension
                    length=$_.Length
                    last_write_time=$_.LastWriteTimeUtc
                }
                $count++
            }
        }catch{}
    }
    @($items | Sort-Object extension,last_write_time -Unique)
}

function Get-CryptoArtifactFiles {
    $patterns=@('*.pem','*.key','*.pfx','*.p12','*.jks','*.kdb','*.kdbx','*.cer','*.crt','*.der','*.csr','*.p7b','*.p7c','*.ovpn')
    $roots=@($env:ProgramData,$env:ProgramFiles,${env:ProgramFiles(x86)},'C:\inetpub')
    $all=@()
    foreach($root in $roots){
        if(-not $root){ continue }
        $found=Get-FileMetadataByPattern -RootPath $root -Patterns $patterns -MaxResults 300
        if($found){ $all += @($found) }
    }
    [ordered]@{
        patterns=$patterns
        scanned_root_labels=@('ProgramData','ProgramFiles','ProgramFilesX86','inetpub')
        total_file_count=@($all).Count
        file_counts_by_extension=@($all | Group-Object extension | Sort-Object Name | ForEach-Object { [ordered]@{ extension=$_.Name; count=$_.Count } })
    }
}

function Get-KeyAndStoreReferences { param([System.Collections.IEnumerable]$Certificates,[bool]$IncludeCurrentUser)
    $mRsa=Join-Path $env:ProgramData 'Microsoft\Crypto\RSA\MachineKeys'
    $mCng=Join-Path $env:ProgramData 'Microsoft\Crypto\Keys'
    $uRsa=Join-Path $env:APPDATA 'Microsoft\Crypto\RSA'
    $uCng=Join-Path $env:APPDATA 'Microsoft\Crypto\Keys'
    $links=@(foreach($c in $Certificates){
        if(-not $c.has_private_key){continue}
        $k=$c.private_key
        [ordered]@{cert_id=$c.cert_id;store_location=$c.store_location;store_name=$c.store_name;key_storage_type=$k.key_storage_type;confidence='low';note='Private key presence recorded; container/file-level mapping intentionally omitted in sanitized output.'}
    })
    $sshHostKeyFiles=@()
    try{
        $sshHostKeyFiles=@(Get-ChildItem -Path 'C:\ProgramData\ssh' -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^ssh_host_.*_key(\.pub)?$' } | ForEach-Object {
            [ordered]@{
                length=$_.Length
                last_write_time=$_.LastWriteTimeUtc
            }
        })
    }catch{}

    [ordered]@{
        machine_keys_rsa=(Get-FileMetadataList $mRsa)
        machine_keys_cng=(Get-FileMetadataList $mCng)
        current_user_rsa=if($IncludeCurrentUser){Get-FileMetadataList $uRsa}else{[ordered]@{path_exists=$false;file_count=0;total_bytes=0;latest_write_time=$null}}
        current_user_cng=if($IncludeCurrentUser){Get-FileMetadataList $uCng}else{[ordered]@{path_exists=$false;file_count=0;total_bytes=0;latest_write_time=$null}}
        openssh_host_key_files=[ordered]@{
            file_count=@($sshHostKeyFiles).Count
            total_bytes=[int64]((@($sshHostKeyFiles) | ForEach-Object { if($_.Contains('length') -and $_.length){ [int64]$_.length } else { 0 } } | Measure-Object -Sum).Sum)
        }
        filesystem_crypto_artifacts=Get-CryptoArtifactFiles
        certificate_key_links=@($links | ForEach-Object { [ordered]@{ cert_id=$_.cert_id; store_location=$_.store_location; store_name=$_.store_name; key_storage_type=$_.key_storage_type; confidence=$_.confidence } })
    }
}

function Get-OpenSshSettingsFromConfig {
    param([string]$ConfigPath)
    $result=[ordered]@{
        path_exists=[bool](Test-Path $ConfigPath)
        directives=[ordered]@{
            Ciphers=@()
            KexAlgorithms=@()
            MACs=@()
            HostKeyAlgorithms=@()
            PubkeyAcceptedAlgorithms=@()
        }
    }
    if(-not (Test-Path $ConfigPath)){ return $result }
    try{
        $lines=Get-Content -Path $ConfigPath -ErrorAction SilentlyContinue
        foreach($line in $lines){
            $clean=($line -replace '#.*$','').Trim()
            if(-not $clean){ continue }
            if($clean -match '^(Ciphers|KexAlgorithms|MACs|HostKeyAlgorithms|PubkeyAcceptedAlgorithms)\s+(.+)$'){
                $name=$matches[1]
                $vals=@($matches[2] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                $result.directives[$name]=@($vals)
            }
        }
    }catch{}
    $result
}

function Get-ProtocolInventory {
    param([hashtable]$Schannel)
    $sshdSvc=$null
    try{$sshdSvc=Get-Service -Name sshd -ErrorAction Stop}catch{}
    $sshdConfig=Get-OpenSshSettingsFromConfig -ConfigPath 'C:\ProgramData\ssh\sshd_config'
    $sshClientConfig=Get-OpenSshSettingsFromConfig -ConfigPath (Join-Path $env:USERPROFILE '.ssh\config')

    $ipsecMain=@();$ipsecQuick=@()
    if(Get-Command -Name Get-NetIPsecMainModeCryptoSet -ErrorAction SilentlyContinue){
        try{
            $ipsecMain=@(Get-NetIPsecMainModeCryptoSet | ForEach-Object {
                [ordered]@{
                    name=$_.DisplayName
                    encryption=@($_.Encryption)
                    hash=@($_.Hash)
                    dh_group=@($_.DHGroup)
                }
            })
        }catch{}
    }
    if(Get-Command -Name Get-NetIPsecQuickModeCryptoSet -ErrorAction SilentlyContinue){
        try{
            $ipsecQuick=@(Get-NetIPsecQuickModeCryptoSet | ForEach-Object {
                [ordered]@{
                    name=$_.DisplayName
                    encapsulation=@($_.Encapsulation)
                    encryption=@($_.Encryption)
                    integrity=@($_.Integrity)
                    pfs_group=@($_.PfsGroup)
                }
            })
        }catch{}
    }

    $smbServer=[ordered]@{}
    if(Get-Command -Name Get-SmbServerConfiguration -ErrorAction SilentlyContinue){
        try{
            $cfg=Get-SmbServerConfiguration
            $smbServer=[ordered]@{
                enable_smb1=$cfg.EnableSMB1Protocol
                enable_smb2=$cfg.EnableSMB2Protocol
                encrypt_data=$cfg.EncryptData
                require_security_signature=$cfg.RequireSecuritySignature
            }
        }catch{}
    }

    $rdpPath='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $rdp=[ordered]@{security_layer=(Get-RegistryValueSafe $rdpPath 'SecurityLayer');user_authentication=(Get-RegistryValueSafe $rdpPath 'UserAuthentication');min_encryption_level=(Get-RegistryValueSafe $rdpPath 'MinEncryptionLevel')}

    [ordered]@{
        schannel=$Schannel
        openssh=[ordered]@{
            service_status=if($sshdSvc){$sshdSvc.Status.ToString()}else{'NotInstalledOrUnknown'}
            server_config=$sshdConfig
            client_config=$sshClientConfig
        }
        ipsec=[ordered]@{
            main_mode_crypto_sets=@($ipsecMain)
            quick_mode_crypto_sets=@($ipsecQuick)
        }
        smb=$smbServer
        rdp=$rdp
    }
}

function Get-AlgorithmInventory {
    param([System.Collections.IEnumerable]$Certificates,[hashtable]$Providers,[hashtable]$Protocols)
    $certList=@($Certificates)
    $sigAlgs=@()
    $pubAlgs=@()
    $pubFamilies=@()
    foreach($cert in $certList){
        if($cert -is [System.Collections.IDictionary]){
            if($cert.Contains('signature_algorithm_name') -and $cert['signature_algorithm_name']){ $sigAlgs += [string]$cert['signature_algorithm_name'] }
            if($cert.Contains('public_key') -and $cert['public_key'] -is [System.Collections.IDictionary]){
                $pk=$cert['public_key']
                if($pk.Contains('public_key_algorithm') -and $pk['public_key_algorithm']){ $pubAlgs += [string]$pk['public_key_algorithm'] }
                if($pk.Contains('public_key_family') -and $pk['public_key_family']){ $pubFamilies += [string]$pk['public_key_family'] }
            }
        }else{
            if($cert.PSObject.Properties.Match('signature_algorithm_name').Count -gt 0 -and $cert.signature_algorithm_name){ $sigAlgs += [string]$cert.signature_algorithm_name }
            if($cert.PSObject.Properties.Match('public_key').Count -gt 0 -and $cert.public_key){
                if($cert.public_key.PSObject.Properties.Match('public_key_algorithm').Count -gt 0 -and $cert.public_key.public_key_algorithm){ $pubAlgs += [string]$cert.public_key.public_key_algorithm }
                if($cert.public_key.PSObject.Properties.Match('public_key_family').Count -gt 0 -and $cert.public_key.public_key_family){ $pubFamilies += [string]$cert.public_key.public_key_family }
            }
        }
    }
    $sigAlgs=@($sigAlgs | Select-Object -Unique)
    $pubAlgs=@($pubAlgs | Select-Object -Unique)
    $pubFamilies=@($pubFamilies | Select-Object -Unique)

    $cipherCandidates=@()
    foreach($suite in @($Protocols.schannel.cipher_suites.suites)){ if($suite){$cipherCandidates += [string]$suite} }
    foreach($entry in @($Protocols.schannel.cipher_order_policy)){ foreach($suite in @($entry.functions)){ if($suite){$cipherCandidates += [string]$suite} } }
    $cipherSuites=@($cipherCandidates | Select-Object -Unique)

    $sshAlgs=@()
    foreach($k in 'Ciphers','KexAlgorithms','MACs','HostKeyAlgorithms','PubkeyAcceptedAlgorithms'){
        foreach($v in @($Protocols.openssh.server_config.directives[$k])){ if($v){$sshAlgs += [string]$v} }
        foreach($v in @($Protocols.openssh.client_config.directives[$k])){ if($v){$sshAlgs += [string]$v} }
    }

    $ipsecAlgs=@()
    foreach($m in @($Protocols.ipsec.main_mode_crypto_sets)){
        foreach($v in @($m.encryption+$m.hash+$m.dh_group)){ if($v){$ipsecAlgs += [string]$v} }
    }
    foreach($q in @($Protocols.ipsec.quick_mode_crypto_sets)){
        foreach($v in @($q.encryption+$q.integrity+$q.pfs_group+$q.encapsulation)){ if($v){$ipsecAlgs += [string]$v} }
    }

    [ordered]@{
        certificates=[ordered]@{
            signature_algorithms=@($sigAlgs)
            public_key_algorithms=@($pubAlgs)
            public_key_families=@($pubFamilies)
        }
        tls_schannel=[ordered]@{
            cipher_suites=@($cipherSuites)
            protocol_versions=@(@($Protocols.schannel.protocols | ForEach-Object {
                if($_ -is [System.Collections.IDictionary]){
                    if($_.Contains('protocol')){ $_['protocol'] }
                }elseif($_.PSObject.Properties.Match('protocol').Count -gt 0){
                    $_.protocol
                }
            } | Where-Object { $_ } | Select-Object -Unique))
        }
        ssh=[ordered]@{
            configured_algorithms=@($sshAlgs | Select-Object -Unique)
        }
        ipsec=[ordered]@{
            configured_algorithms=@($ipsecAlgs | Select-Object -Unique)
        }
        providers=[ordered]@{
            csp_ksp_providers=@($Providers.provider_defaults)
        }
    }
}

function Get-PqcReadiness { param([System.Collections.IEnumerable]$Certificates,[hashtable]$Schannel,[hashtable]$CryptoProviders)
    $legacy=@()
    $legacyUnknown=@()
    foreach($row in ($Schannel.protocols|Where-Object{$_.protocol -in @('TLS 1.0','TLS 1.1','SSL 2.0','SSL 3.0')})){
        $en=$false
        if($row.enabled -eq 1){$en=$true}
        elseif($row.enabled -eq $null -and $row.disabled_by_default -eq 0){$en=$true}
        if($en){$legacy+="$($row.protocol) $($row.role)"}
        if(-not $row.key_present){$legacyUnknown+="$($row.protocol) $($row.role)"}
    }

    $allCipherCandidates=New-Object System.Collections.Generic.List[string]
    foreach($s in @($Schannel.cipher_suites.suites)){ if($s){$allCipherCandidates.Add([string]$s)|Out-Null} }
    foreach($entry in @($Schannel.cipher_order_policy)){
        foreach($s in @($entry.functions)){ if($s){$allCipherCandidates.Add([string]$s)|Out-Null} }
    }
    $allCipherCandidates=@($allCipherCandidates|Select-Object -Unique)
    $weakCiphers=@($allCipherCandidates|Where-Object{$_ -match 'RC4|3DES|NULL|EXPORT|MD5|DES(?!EDE)|RC2'})
    $rsaWeak=0;$eccWeak=0;$nonPqcSig=0
    foreach($c in $Certificates){
        $sig=("$($c.signature_algorithm_name)").ToUpperInvariant(); if($sig -match 'RSA|ECDSA|DSA'){$nonPqcSig++}
        if($c.public_key.public_key_family -eq 'RSA' -and $c.public_key.public_key_size_bits -and [int]$c.public_key.public_key_size_bits -lt 2048){$rsaWeak++}
        if($c.public_key.public_key_family -eq 'ECC'){if(("$($c.public_key.ecc_curve_name)") -match 'P-192|secp192|P-224|secp224'){$eccWeak++}}
    }
    $fips=[bool]$CryptoProviders.policies.fips_policy_registry.effective_enabled
    [ordered]@{
        summary=[ordered]@{certificate_count=@($Certificates).Count;certs_with_non_pqc_signature_algorithms=$nonPqcSig;rsa_keys_lt_2048_count=$rsaWeak;weak_ecc_curve_count=$eccWeak;legacy_protocol_enabled_count=@($legacy).Count;legacy_protocol_not_explicitly_configured_count=@($legacyUnknown).Count;weak_cipher_suite_count=@($weakCiphers).Count;fips_mode_enabled=$fips}
        flags=[ordered]@{pqc_transition_required_for_signatures=([bool]($nonPqcSig -gt 0));legacy_protocol_enabled=([bool](@($legacy).Count -gt 0));legacy_protocol_explicitly_configured=([bool](@($legacyUnknown).Count -lt 8));weak_cipher_enabled=([bool](@($weakCiphers).Count -gt 0));weak_rsa_key_present=([bool]($rsaWeak -gt 0));weak_ecc_curve_present=([bool]($eccWeak -gt 0));fips_mode_enabled=$fips}
        evidence=[ordered]@{legacy_protocol_entries=@($legacy);legacy_protocol_not_explicitly_configured_entries=@($legacyUnknown);weak_cipher_suites=@($weakCiphers);weak_cipher_candidate_source='cipher_suites plus cipher_order_policy.functions'}
    }
}

function Build-SummaryCsvRows { param([hashtable]$Device,[System.Collections.IEnumerable]$Certificates,[hashtable]$PqcReadiness)
    foreach($c in $Certificates){
        $rsaWeakForCert=($c.public_key.public_key_family -eq 'RSA' -and $c.public_key.public_key_size_bits -and [int]$c.public_key.public_key_size_bits -lt 2048)
        $eccWeakForCert=($c.public_key.public_key_family -eq 'ECC' -and ("$($c.public_key.ecc_curve_name)" -match 'P-192|secp192|P-224|secp224'))
        [pscustomobject]@{
            hostname=$Device.identity.hostname;domain=$Device.identity.domain;os_build=$Device.operating_system.build_number
            cert_id=$c.cert_id;store_location=$c.store_location;store_name=$c.store_name;not_before=$c.not_before;not_after=$c.not_after
            signature_algorithm_name=$c.signature_algorithm_name;signature_algorithm_oid=$c.signature_algorithm_oid;public_key_algorithm=$c.public_key.public_key_algorithm;public_key_family=$c.public_key.public_key_family;public_key_size_bits=$c.public_key.public_key_size_bits;ecc_curve_name=$c.public_key.ecc_curve_name
            has_private_key=$c.has_private_key;key_storage_type=$c.private_key.key_storage_type;exportable=$c.private_key.exportable
            basic_constraints_is_ca=$c.basic_constraints_is_ca;key_usage_flags=$c.key_usage_flags
            tls_legacy_protocol_enabled=$PqcReadiness.flags.legacy_protocol_enabled;legacy_protocol_explicitly_configured=$PqcReadiness.flags.legacy_protocol_explicitly_configured;weak_cipher_enabled=$PqcReadiness.flags.weak_cipher_enabled;pqc_signature_transition_required=$PqcReadiness.flags.pqc_transition_required_for_signatures;weak_rsa_key_present=$rsaWeakForCert;weak_ecc_curve_present=$eccWeakForCert;fips_mode_enabled=$PqcReadiness.flags.fips_mode_enabled
        }
    }
}

function Invoke-CryptoInventory {
    [CmdletBinding()]param()
    $start=Get-Date; $script:VerboseLoggingEnabled=$false
    $folder='CryptoInventory_{0}_{1}' -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Path 'C:\temp' -Force|Out-Null
    $outPath=Join-Path 'C:\temp' $folder
    New-Item -ItemType Directory -Path $outPath -Force|Out-Null
    $script:RunLogPath=Join-Path $outPath 'runlog.txt'
    Set-Content -Path $script:RunLogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Starting CryptoInventory run" -Encoding utf8

    if($PSVersionTable.PSVersion.Major -lt 5){throw 'PowerShell 5.1+ required.'}
    $script:IsAdmin=Test-IsAdmin
    if(-not $script:IsAdmin){Write-RunLog 'Not running as Administrator. Partial results may be collected.' WARN}

    $checks=[ordered]@{powershell_version_ok=($PSVersionTable.PSVersion.Major -ge 5);powershell_version=$PSVersionTable.PSVersion.ToString();is_admin=$script:IsAdmin;commands=(Get-CommandAvailability)}

    $device=[ordered]@{};$certs=@();$schannel=[ordered]@{};$providers=[ordered]@{};$dpapi=[ordered]@{};$keys=[ordered]@{};$protocols=[ordered]@{};$algorithms=[ordered]@{};$pqc=[ordered]@{}
    try{
        $device=Get-DeviceInfo
        $device.self_checks=$checks
    }catch{
        Write-RunLog "Device collection failed: $($_.Exception.Message)" ERROR
        $device=[ordered]@{
            collection_timestamp=(Get-Date).ToString('o')
            identity=[ordered]@{hostname=$env:COMPUTERNAME;domain=$null;part_of_domain=$null;is_admin=$script:IsAdmin;powershell_version=$PSVersionTable.PSVersion.ToString()}
            operating_system=[ordered]@{caption=$null;version=$null;build_number=$null;architecture=$null;install_date=$null;last_boot_up_time=$null}
            hardware=[ordered]@{manufacturer=$null;model=$null;total_physical_ram=$null;logical_processors=$null}
            network=[ordered]@{interface_count=0;interfaces=@()}
            self_checks=$checks
        }
    }
    try{$certs=Get-CertificateInventory $false}catch{Write-RunLog "Certificate collection failed: $($_.Exception.Message)" ERROR}
    try{$certs=Add-CertificateIds $certs}catch{Write-RunLog "Certificate ID assignment failed: $($_.Exception.Message)" ERROR}
    try{$schannel=Get-SchannelPosture}catch{Write-RunLog "Schannel collection failed: $($_.Exception.Message)" ERROR}
    try{$providers=Get-CryptoProviders}catch{Write-RunLog "Crypto providers collection failed: $($_.Exception.Message)" ERROR}
    try{$dpapi=Get-DpapiStatus}catch{Write-RunLog "DPAPI collection failed: $($_.Exception.Message)" ERROR}
    try{$keys=Get-KeyAndStoreReferences $certs $false}catch{Write-RunLog "Key/store collection failed: $($_.Exception.Message)" ERROR}
    try{$protocols=Get-ProtocolInventory $schannel}catch{Write-RunLog "Protocol inventory collection failed: $($_.Exception.Message)" ERROR}
    try{$algorithms=Get-AlgorithmInventory $certs $providers $protocols}catch{Write-RunLog "Algorithm inventory collection failed: $($_.Exception.Message)" ERROR}
    try{$pqc=Get-PqcReadiness $certs $schannel $providers}catch{Write-RunLog "PQC readiness computation failed: $($_.Exception.Message)" ERROR}
    try{$certs=Remove-CertificateThumbprints $certs}catch{Write-RunLog "Certificate thumbprint sanitization failed: $($_.Exception.Message)" ERROR}

    Write-JsonFile (Join-Path $outPath 'device.json') $device
    Write-JsonFile (Join-Path $outPath 'certs.json') $certs
    Write-JsonFile (Join-Path $outPath 'schannel.json') $schannel
    Write-JsonFile (Join-Path $outPath 'crypto_providers.json') $providers
    Write-JsonFile (Join-Path $outPath 'dpapi.json') $dpapi
    Write-JsonFile (Join-Path $outPath 'keys_and_stores.json') $keys
    Write-JsonFile (Join-Path $outPath 'protocols.json') $protocols
    Write-JsonFile (Join-Path $outPath 'algorithms.json') $algorithms
    Write-JsonFile (Join-Path $outPath 'pqc_readiness.json') $pqc
    Build-SummaryCsvRows $device $certs $pqc | Export-Csv (Join-Path $outPath 'summary.csv') -NoTypeInformation -Encoding UTF8
    $stop=Get-Date
    Write-RunLog "Completed run in $([int](($stop-$start).TotalSeconds))s. Warnings=$($script:RunWarnings.Count), Errors=$($script:RunErrors.Count)."

    $zip="$outPath.zip"
    try{
        if(Test-Path $zip){Remove-Item $zip -Force}
        Compress-Archive -Path $outPath -DestinationPath $zip -Force
        Write-RunLog "Created ZIP package: $zip"
    }catch{Write-RunLog "ZIP creation failed: $($_.Exception.Message)" ERROR}

    Write-Host ''
    Write-Host 'Crypto inventory collection complete.'
    Write-Host "Output ZIP: $zip"

    [pscustomobject]@{OutputFolder=$outPath;ZipPath=$zip;CertificateCount=@($certs).Count;WarningCount=$script:RunWarnings.Count;ErrorCount=$script:RunErrors.Count}
}

Invoke-CryptoInventory
