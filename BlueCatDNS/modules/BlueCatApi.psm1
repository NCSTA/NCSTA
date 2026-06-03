# BlueCatApi.psm1 - BlueCat Address Manager RESTful v2 API wrapper
# Requires BAM 9.5.0+ with the v2 API enabled
# Compatible with PowerShell 5.1+

$script:BamUrl = $null
$script:Token = $null
$script:Headers = @{}
$script:ConfigId = $null
$script:ViewId = $null
$script:CurrentUser = $null
$script:SkipCert = $false

# PS 5.1 TLS cert bypass helper
function Set-CertBypass {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}

# ---------------------------------------------------------------------------
# Session Management
# ---------------------------------------------------------------------------

function Connect-BlueCat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][pscredential]$Credential,
        [switch]$SkipCertCheck
    )

    $script:BamUrl = if ($Server -match '^https?://') {
        $Server.TrimEnd('/')
    } else {
        "https://$Server"
    }
    $script:CurrentUser = $Credential.UserName

    $uri = "$($script:BamUrl)/api/v2/sessions"
    $body = @{
        username = $Credential.UserName
        password = $Credential.GetNetworkCredential().Password
    } | ConvertTo-Json -Compress

    if ($SkipCertCheck) {
        $script:SkipCert = $true
        Set-CertBypass
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }

    $params = @{
        Uri         = $uri
        Method      = 'POST'
        ContentType = 'application/json'
        Body        = $body
    }

    try {
        $response = Invoke-RestMethod @params
        # RESTful v2 returns pre-encoded Basic credentials for subsequent calls.
        $script:Token = $null
        if ($response.basicAuthenticationCredentials) {
            $script:Token = $response.basicAuthenticationCredentials
        } elseif ($response.apiToken) {
            $tokenBytes = [System.Text.Encoding]::ASCII.GetBytes(
                "$($Credential.UserName):$($response.apiToken)"
            )
            $script:Token = [Convert]::ToBase64String($tokenBytes)
        }

        if (-not $script:Token) {
            throw 'Login succeeded but no API session credentials were returned.'
        }

        $script:Headers = @{
            Authorization  = "Basic $($script:Token)"
            'Content-Type' = 'application/json'
            Accept         = 'application/hal+json'
        }

        Write-Verbose "Connected to BlueCat at $Server as $($Credential.UserName)"
        return $true
    }
    catch {
        $errMsg = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            $errMsg = $_.ErrorDetails.Message
        }
        throw "Failed to connect to BlueCat: $errMsg"
    }
}

function Disconnect-BlueCat {
    [CmdletBinding()]
    param()

    if (-not $script:Token) { return }

    try {
        $params = @{
            Uri     = "$($script:BamUrl)/api/v2/sessions/current"
            Method  = 'PATCH'
            Headers = $script:Headers
            Body    = '{"state":"LOGGED_OUT"}'
        }
        Invoke-RestMethod @params | Out-Null
    }
    catch {
        Write-Warning "Logout request failed: $($_.Exception.Message)"
    }
    finally {
        $script:Token = $null
        $script:Headers = @{}
    }
}

function Get-BlueCatCurrentUser { return $script:CurrentUser }

# ---------------------------------------------------------------------------
# Internal helper
# ---------------------------------------------------------------------------

function Invoke-BlueCatApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
        [object]$Body,
        [hashtable]$ExtraHeaders = @{}
    )

    $uri = if ($Endpoint.StartsWith('http')) { $Endpoint } else { "$($script:BamUrl)/api/v2/$Endpoint" }

    $merged = @{}
    foreach ($k in $script:Headers.Keys) { $merged[$k] = $script:Headers[$k] }
    foreach ($k in $ExtraHeaders.Keys) { $merged[$k] = $ExtraHeaders[$k] }

    $params = @{
        Uri     = $uri
        Method  = $Method
        Headers = $merged
    }

    if ($Body) {
        if ($Body -is [string]) {
            $params['Body'] = $Body
        } else {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
        }
    }

    try {
        # Cert bypass is handled globally via Set-CertBypass in Connect-BlueCat
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $messages = New-Object System.Collections.ArrayList
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            [void]$messages.Add($_.ErrorDetails.Message)
        }
        if ($_.Exception -and $_.Exception.Message) {
            [void]$messages.Add($_.Exception.Message)
        }
        if ($_.Exception -and $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Dispose()
                    if ($responseBody) { [void]$messages.Add($responseBody) }
                }
            }
            catch {}
        }

        $errMsg = (($messages | Select-Object -Unique) -join "`n")
        if (-not $errMsg) { $errMsg = 'Unknown API error' }
        throw "BlueCat API $Method $uri failed: $errMsg"
    }
}

function Get-BlueCatResponseData {
    param([object]$Response)

    if ($null -eq $Response) {
        return ,@()
    }

    $dataProperty = $Response.PSObject.Properties['data']
    if ($dataProperty) {
        if ($null -eq [object]$dataProperty.Value) {
            return ,@()
        }
        return ,@($dataProperty.Value)
    }

    return ,@($Response)
}

# ---------------------------------------------------------------------------
# Configuration & View lookup
# ---------------------------------------------------------------------------

function Get-BlueCatConfigurations {
    [CmdletBinding()]
    param()
    $result = Invoke-BlueCatApi -Endpoint 'configurations'
    return Get-BlueCatResponseData $result
}

function Set-BlueCatContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ConfigurationId,
        [Parameter(Mandatory)][int]$ViewId
    )
    $script:ConfigId = $ConfigurationId
    $script:ViewId = $ViewId
}

function Get-BlueCatConfigId { return $script:ConfigId }
function Get-BlueCatViewId { return $script:ViewId }

function Get-BlueCatViews {
    [CmdletBinding()]
    param(
        [int]$ConfigurationId = $script:ConfigId
    )
    $result = Invoke-BlueCatApi -Endpoint "configurations/$ConfigurationId/views"
    return Get-BlueCatResponseData $result
}

# ---------------------------------------------------------------------------
# Zone operations
# ---------------------------------------------------------------------------

function Get-BlueCatZones {
    [CmdletBinding()]
    param(
        [int]$ViewId = $script:ViewId,
        [string]$Filter
    )

    $endpoint = "views/$ViewId/zones"
    if ($Filter) {
        $endpoint += "?filter=$([uri]::EscapeDataString($Filter))"
    }
    $result = Invoke-BlueCatApi -Endpoint $endpoint
    return Get-BlueCatResponseData $result
}

function Find-BlueCatZone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AbsoluteName
    )

    $encoded = [uri]::EscapeDataString("absoluteName:eq('$AbsoluteName')")
    $result = Invoke-BlueCatApi -Endpoint "zones?filter=$encoded"
    $zones = Get-BlueCatResponseData $result

    if ($zones.Count -gt 0) {
        return $zones[0]
    }
    return $null
}

function Get-BlueCatSubZones {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ZoneId
    )
    $result = Invoke-BlueCatApi -Endpoint "zones/$ZoneId/zones"
    return Get-BlueCatResponseData $result
}

# ---------------------------------------------------------------------------
# Resource Record operations
# ---------------------------------------------------------------------------

function Get-BlueCatResourceRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ZoneId,
        [string]$Filter,
        [int]$Limit = 100
    )

    $endpoint = "zones/$ZoneId/resourceRecords?limit=$Limit"
    if ($Filter) {
        $endpoint += "&filter=$([uri]::EscapeDataString($Filter))"
    }
    $result = Invoke-BlueCatApi -Endpoint $endpoint
    return Get-BlueCatResponseData $result
}

function Get-BlueCatResourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id
    )
    $result = Invoke-BlueCatApi -Endpoint "resourceRecords/$Id"
    return $result
}

function New-BlueCatResourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ZoneId,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Name,
        [string]$AbsoluteName,
        [string]$RData,
        [array]$Addresses,
        [int]$TTL = 300,
        [string]$Comment,
        [switch]$CreateReverseRecord,
        [object]$LinkedRecord
    )

    $body = @{
        type = $Type
        ttl  = $TTL
    }

    if ($AbsoluteName) {
        $body['absoluteName'] = $AbsoluteName
    } else {
        $body['name'] = $Name
    }

    switch ($Type) {
        'HostRecord' {
            if ($Addresses) {
                $body['addresses'] = $Addresses
            } else {
                $body['addresses'] = @(
                    @{ type = 'IPv4Address'; address = $RData }
                )
            }
        }
        'AliasRecord' {
            if ($LinkedRecord) {
                $body['linkedRecord'] = $LinkedRecord
            } else {
                $body['linkedRecord'] = @{ type = 'HostRecord'; absoluteName = $RData }
            }
        }
        'MXRecord' {
            $parts = $RData -split '\s+', 2
            $body['priority'] = [int]$parts[0]
            $body['linkedRecord'] = @{ absoluteName = $parts[1] }
        }
        'TXTRecord' {
            $body['text'] = $RData
        }
        'SRVRecord' {
            $parts = $RData -split '\s+', 4
            $body['priority'] = [int]$parts[0]
            $body['weight']   = [int]$parts[1]
            $body['port']     = [int]$parts[2]
            $body['linkedRecord'] = @{ absoluteName = $parts[3] }
        }
        'GenericRecord' {
            $body['rdata'] = $RData
        }
        default {
            $body['rdata'] = $RData
        }
    }

    $extraHeaders = @{}
    if ($Comment) {
        $extraHeaders['x-bcn-change-control-comment'] = $Comment
    }
    if ($CreateReverseRecord) {
        $extraHeaders['x-bcn-create-reverse-record'] = 'true'
    }

    $result = Invoke-BlueCatApi -Endpoint "zones/$ZoneId/resourceRecords" -Method POST -Body $body -ExtraHeaders $extraHeaders
    return $result
}

function Update-BlueCatResourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Name,
        [string]$RData,
        [array]$Addresses,
        [int]$TTL,
        [string]$Comment,
        [string]$Type
    )

    $existing = Get-BlueCatResourceRecord -Id $Id
    $body = @{}

    if ($Name)  { $body['name'] = $Name }
    if ($TTL)   { $body['ttl'] = $TTL }

    $recordType = if ($Type) { $Type } else { $existing.type }

    if ($RData) {
        switch ($recordType) {
            'HostRecord' {
                if ($Addresses) {
                    $body['addresses'] = $Addresses
                } else {
                    $body['addresses'] = @(
                        @{ type = 'IPv4Address'; address = $RData }
                    )
                }
            }
            'AliasRecord' {
                $body['linkedRecord'] = @{ absoluteName = $RData }
            }
            'TXTRecord' {
                $body['text'] = $RData
            }
            'GenericRecord' {
                $body['rdata'] = $RData
            }
            default {
                $body['rdata'] = $RData
            }
        }
    }

    $extraHeaders = @{}
    if ($Comment) {
        $extraHeaders['x-bcn-change-control-comment'] = $Comment
    }

    $result = Invoke-BlueCatApi -Endpoint "resourceRecords/$Id" -Method PUT -Body $body -ExtraHeaders $extraHeaders
    return $result
}

function Remove-BlueCatResourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Id,
        [string]$Comment
    )

    $extraHeaders = @{}
    if ($Comment) {
        $extraHeaders['x-bcn-change-control-comment'] = $Comment
    }

    Invoke-BlueCatApi -Endpoint "resourceRecords/$Id" -Method DELETE -ExtraHeaders $extraHeaders
}

# ---------------------------------------------------------------------------
# Deployment operations
# ---------------------------------------------------------------------------

function Invoke-BlueCatSelectiveDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$EntityId,
        [ValidateSet('related','specific')][string]$Scope = 'related',
        [ValidateSet('disabled','batch_by_server')][string]$BatchMode = 'disabled'
    )

    $body = @{
        resources  = @(
            @{ id = $EntityId }
        )
        properties = @{
            scope             = $Scope
            batchMode         = $BatchMode
            continueOnFailure = $false
        }
    }

    $result = Invoke-BlueCatApi -Endpoint 'deployments' -Method POST -Body $body
    return $result
}

function Invoke-BlueCatQuickDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ZoneId
    )

    $result = Invoke-BlueCatApi -Endpoint "zones/$ZoneId/deployments" -Method POST -Body @{}
    return $result
}

function Invoke-BlueCatServerDeploy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ServerId,
        [ValidateSet('dns','dhcp','dhcpv6','tftp')][string]$Service = 'dns'
    )

    $body = @{ service = $Service }
    $result = Invoke-BlueCatApi -Endpoint "servers/$ServerId/deployments" -Method POST -Body $body
    return $result
}

function Get-BlueCatDeploymentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$DeploymentId
    )

    $result = Invoke-BlueCatApi -Endpoint "deployments/$DeploymentId"
    return $result
}

function Get-BlueCatDeployments {
    [CmdletBinding()]
    param(
        [int]$Limit = 20,
        [string]$Filter
    )

    $endpoint = "deployments?limit=$Limit"
    if ($Filter) {
        $endpoint += "&filter=$([uri]::EscapeDataString($Filter))"
    }

    $result = Invoke-BlueCatApi -Endpoint $endpoint
    return Get-BlueCatResponseData $result
}

# ---------------------------------------------------------------------------
# Server operations
# ---------------------------------------------------------------------------

function Get-BlueCatServers {
    [CmdletBinding()]
    param(
        [int]$ConfigurationId = $script:ConfigId
    )
    $result = Invoke-BlueCatApi -Endpoint "configurations/$ConfigurationId/servers"
    return Get-BlueCatResponseData $result
}

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

function Test-BlueCatConnection {
    try {
        $null = Invoke-BlueCatApi -Endpoint 'sessions/current'
        return $true
    }
    catch {
        return $false
    }
}

function Get-BlueCatRecordTypeDisplayName {
    param([string]$Type)
    switch ($Type) {
        'HostRecord'     { 'A / Host Record' }
        'AliasRecord'    { 'CNAME' }
        'MXRecord'       { 'MX' }
        'TXTRecord'      { 'TXT' }
        'SRVRecord'      { 'SRV' }
        'GenericRecord'  { 'Generic' }
        'HINFORecord'    { 'HINFO' }
        'NAPTRRecord'    { 'NAPTR' }
        default          { $Type }
    }
}

function Get-BlueCatRecordTypeApiName {
    param([string]$DisplayName)
    switch ($DisplayName) {
        'A / Host Record' { 'HostRecord' }
        'CNAME'           { 'AliasRecord' }
        'MX'              { 'MXRecord' }
        'TXT'             { 'TXTRecord' }
        'SRV'             { 'SRVRecord' }
        'Generic'         { 'GenericRecord' }
        default           { $DisplayName }
    }
}

Export-ModuleMember -Function Connect-BlueCat, Disconnect-BlueCat, Get-BlueCatCurrentUser,
    Get-BlueCatConfigurations, Set-BlueCatContext, Get-BlueCatConfigId, Get-BlueCatViewId,
    Get-BlueCatViews, Get-BlueCatZones, Find-BlueCatZone, Get-BlueCatSubZones,
    Get-BlueCatResourceRecords, Get-BlueCatResourceRecord,
    New-BlueCatResourceRecord, Update-BlueCatResourceRecord, Remove-BlueCatResourceRecord,
    Invoke-BlueCatSelectiveDeploy, Invoke-BlueCatQuickDeploy, Invoke-BlueCatServerDeploy,
    Get-BlueCatDeploymentStatus, Get-BlueCatDeployments, Get-BlueCatServers, Test-BlueCatConnection,
    Get-BlueCatRecordTypeDisplayName, Get-BlueCatRecordTypeApiName
