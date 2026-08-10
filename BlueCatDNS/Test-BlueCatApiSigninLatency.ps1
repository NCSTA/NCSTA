<#
.SYNOPSIS
    Measures BlueCat Integrity REST v2 API sign-in latency.

.DESCRIPTION
    Repeatedly creates and closes an Address Manager REST v2 API session and
    records DNS, TCP, authentication, and logout latency. Credentials and API
    tokens are never written to the console or CSV output.

    The test stops after the first failed sign-in to reduce the risk of an LDAP
    account lockout caused by invalid credentials.

.PARAMETER Server
    Address Manager hostname, IP address, or base URL.

.PARAMETER Attempts
    Number of successful sign-in samples to collect. Default: 5.

.PARAMETER DelaySeconds
    Delay between attempts. Default: 2 seconds.

.PARAMETER TimeoutSeconds
    Timeout for each REST request and TCP probe. Default: 60 seconds.

.PARAMETER Credential
    Optional credential. When omitted, the script prompts once.

.PARAMETER SkipCertificateCheck
    Bypasses TLS certificate validation. Use only for diagnostic testing.

.PARAMETER OutputCsv
    CSV result path. Defaults to a timestamped file beside this script.

.EXAMPLE
    .\Test-BlueCatApiSigninLatency.ps1 -Server bam.example.com -Attempts 10

.EXAMPLE
    .\Test-BlueCatApiSigninLatency.ps1 -Server https://10.20.30.40 -Attempts 5 -SkipCertificateCheck
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Server,

    [ValidateRange(1, 100)]
    [int]$Attempts = 5,

    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 2,

    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 60,

    [pscredential]$Credential,

    [switch]$SkipCertificateCheck,

    [string]$OutputCsv
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter the BlueCat API/LDAP credentials to test against $Server"
}
if (-not $Credential) {
    throw 'No credential was supplied.'
}

$baseUrl = if ($Server -match '^https?://') {
    $Server.TrimEnd('/')
}
else {
    "https://$($Server.TrimEnd('/'))"
}

try {
    $baseUri = [uri]$baseUrl
}
catch {
    throw "Invalid Address Manager address '$Server'."
}

if (-not $OutputCsv) {
    $fileName = "BlueCat-ApiSigninLatency-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $OutputCsv = Join-Path $PSScriptRoot $fileName
}

if ($SkipCertificateCheck) {
    if (-not ([System.Management.Automation.PSTypeName]'BlueCatLatencyTrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BlueCatLatencyTrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint servicePoint,
        X509Certificate certificate,
        WebRequest request,
        int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object BlueCatLatencyTrustAllCertsPolicy
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Measure-DnsLookup {
    param([Parameter(Mandatory)][string]$HostName)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    [void][System.Net.Dns]::GetHostAddresses($HostName)
    $timer.Stop()
    return [math]::Round($timer.Elapsed.TotalMilliseconds, 2)
}

function Measure-TcpConnection {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $asyncResult = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            throw "TCP connection timed out after $TimeoutMilliseconds ms."
        }
        $client.EndConnect($asyncResult)
        $timer.Stop()
        return [math]::Round($timer.Elapsed.TotalMilliseconds, 2)
    }
    finally {
        $timer.Stop()
        $client.Dispose()
    }
}

function Get-Percentile {
    param(
        [Parameter(Mandatory)][double[]]$Values,
        [Parameter(Mandatory)][ValidateRange(0, 100)][double]$Percentile
    )

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    if ($sorted.Count -eq 1) { return [math]::Round($sorted[0], 2) }

    $position = ($Percentile / 100) * ($sorted.Count - 1)
    $lower = [math]::Floor($position)
    $upper = [math]::Ceiling($position)
    if ($lower -eq $upper) { return [math]::Round($sorted[$lower], 2) }

    $weight = $position - $lower
    return [math]::Round(($sorted[$lower] + (($sorted[$upper] - $sorted[$lower]) * $weight)), 2)
}

$loginUri = "$baseUrl/api/v2/sessions"
$logoutUri = "$baseUrl/api/v2/sessions/current"
$requestBody = @{
    username = $Credential.UserName
    password = $Credential.GetNetworkCredential().Password
} | ConvertTo-Json -Compress

$results = New-Object System.Collections.ArrayList
$port = if ($baseUri.IsDefaultPort) {
    if ($baseUri.Scheme -eq 'https') { 443 } else { 80 }
}
else {
    $baseUri.Port
}

Write-Host "Testing BlueCat REST v2 sign-in at $loginUri" -ForegroundColor Cyan
Write-Host "User: $($Credential.UserName) | Attempts: $Attempts | Timeout: $TimeoutSeconds seconds"
Write-Host 'The password and returned API credentials will not be logged.' -ForegroundColor DarkGray

for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $dnsMs = $null
    $tcpMs = $null
    $signInMs = $null
    $logoutMs = $null
    $authenticator = $null
    $sessionId = $null
    $success = $false
    $errorMessage = $null
    $loginResponse = $null
    $attemptTimer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $dnsMs = Measure-DnsLookup -HostName $baseUri.DnsSafeHost
        $tcpMs = Measure-TcpConnection -HostName $baseUri.DnsSafeHost -Port $port -TimeoutMilliseconds ($TimeoutSeconds * 1000)

        $loginTimer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $loginResponse = Invoke-RestMethod -Uri $loginUri -Method Post -ContentType 'application/json' -Body $requestBody -TimeoutSec $TimeoutSeconds
        }
        finally {
            $loginTimer.Stop()
            $signInMs = [math]::Round($loginTimer.Elapsed.TotalMilliseconds, 2)
        }

        if (-not $loginResponse.basicAuthenticationCredentials) {
            throw 'Sign-in returned no basicAuthenticationCredentials value.'
        }

        $sessionId = $loginResponse.id
        if ($loginResponse.authenticator) {
            $authenticator = $loginResponse.authenticator.name
        }
        $success = $true
    }
    catch {
        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errorMessage = $_.ErrorDetails.Message
        }
        if ($errorMessage -match '(?is)<!DOCTYPE|<html|<style|<body') {
            $errorMessage = 'Address Manager returned HTML instead of a REST API response. Verify the base URL, proxy, and SSO/API routing.'
        }
    }
    finally {
        if ($loginResponse -and $loginResponse.basicAuthenticationCredentials) {
            $logoutTimer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $logoutHeaders = @{
                    Authorization = "Basic $($loginResponse.basicAuthenticationCredentials)"
                    Accept = 'application/hal+json'
                }
                Invoke-RestMethod -Uri $logoutUri -Method Patch -Headers $logoutHeaders -ContentType 'application/json' -Body '{"state":"LOGGED_OUT"}' -TimeoutSec $TimeoutSeconds | Out-Null
            }
            catch {
                if (-not $errorMessage) {
                    $errorMessage = "Sign-in succeeded, but logout failed: $($_.Exception.Message)"
                }
            }
            finally {
                $logoutTimer.Stop()
                $logoutMs = [math]::Round($logoutTimer.Elapsed.TotalMilliseconds, 2)
            }
        }

        $attemptTimer.Stop()
        $row = [PSCustomObject]@{
            Timestamp     = (Get-Date).ToString('o')
            Attempt       = $attempt
            Server        = $baseUri.DnsSafeHost
            Port          = $port
            Username      = $Credential.UserName
            Authenticator = $authenticator
            DnsMs         = $dnsMs
            TcpConnectMs  = $tcpMs
            SignInMs      = $signInMs
            LogoutMs      = $logoutMs
            TotalMs       = [math]::Round($attemptTimer.Elapsed.TotalMilliseconds, 2)
            SessionId     = $sessionId
            Success       = $success
            Error         = $errorMessage
        }
        [void]$results.Add($row)

        $color = if ($success) { 'Green' } else { 'Red' }
        $resultText = if ($success) {
            "Attempt $attempt/${Attempts}: sign-in $signInMs ms; DNS $dnsMs ms; TCP $tcpMs ms; authenticator '$authenticator'"
        }
        else {
            "Attempt $attempt/${Attempts} FAILED after $($row.TotalMs) ms: $errorMessage"
        }
        Write-Host $resultText -ForegroundColor $color
    }

    if (-not $success) {
        Write-Warning 'Stopping after the first failed sign-in to reduce account-lockout risk.'
        break
    }

    if ($attempt -lt $Attempts -and $DelaySeconds -gt 0) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

$results | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

$successfulResults = @($results | Where-Object Success)
if ($successfulResults.Count -gt 0) {
    $signInValues = [double[]]@($successfulResults | ForEach-Object { $_.SignInMs })
    $average = [math]::Round(($signInValues | Measure-Object -Average).Average, 2)
    $minimum = [math]::Round(($signInValues | Measure-Object -Minimum).Minimum, 2)
    $maximum = [math]::Round(($signInValues | Measure-Object -Maximum).Maximum, 2)
    $median = Get-Percentile -Values $signInValues -Percentile 50
    $p95 = Get-Percentile -Values $signInValues -Percentile 95

    Write-Host ''
    Write-Host "Successful sign-ins: $($successfulResults.Count)/$($results.Count)" -ForegroundColor Cyan
    Write-Host "Sign-in latency (ms): min=$minimum median=$median average=$average p95=$p95 max=$maximum"
}
else {
    Write-Warning 'No successful sign-ins were recorded.'
}

Write-Host "Results: $OutputCsv" -ForegroundColor Cyan
$results
