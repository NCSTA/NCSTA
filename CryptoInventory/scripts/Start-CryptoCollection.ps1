#Requires -Version 5.1

# Output destination on the management VM.
# Set the CRYPTO_OUTPUT_PATH environment variable before running, e.g.:
#   $env:CRYPTO_OUTPUT_PATH = '\\mgmt-server\CryptoResults'
$OutputPath = $env:CRYPTO_OUTPUT_PATH

# Target servers — populate with FQDNs before running.
$servers = @(
    # 'server01.domain.com',
    # 'server02.domain.com',
)

# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------

if (-not $OutputPath) {
    throw 'CRYPTO_OUTPUT_PATH environment variable is not set. Set it to a local or UNC path before running.'
}

if (-not (Test-Path $OutputPath)) {
    Write-Host "Output path does not exist, creating: $OutputPath"
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

if ($servers.Count -eq 0) {
    throw 'No servers defined in $servers. Populate the array before running.'
}

$scriptPath = Join-Path $PSScriptRoot 'CryptoInventory.ps1'
if (-not (Test-Path $scriptPath)) {
    throw "CryptoInventory.ps1 not found at expected path: $scriptPath"
}

# ---------------------------------------------------------------------------
# Failure log (written alongside collected ZIPs in $OutputPath)
# Only created if at least one failure occurs.
# ---------------------------------------------------------------------------

$runTimestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$failureLogPath  = Join-Path $OutputPath "CollectionFailures_${runTimestamp}.csv"
function Write-FailureLog {
    param(
        [string]$Server,
        [ValidateSet('Connect','Execute','Copy')][string]$Stage,
        [string]$ErrorMessage
    )

    [pscustomobject]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Server    = $Server
        Stage     = $Stage
        Error     = $ErrorMessage
    } | Export-Csv -Path $script:failureLogPath -Append -NoTypeInformation -Encoding utf8

    Write-Warning "[$Stage] $Server - $ErrorMessage"
}

# ---------------------------------------------------------------------------
# Session helper
# ---------------------------------------------------------------------------

function New-PSSessionToVM {
    [CmdletBinding()]
    param (
        $FQDN
    )

    begin {
        $PSOptions = New-PSSessionOption -SkipCNCheck -SkipRevocationCheck -OpenTimeout 5000
    }

    process {
        TRY {
            $PSsession = New-PSSession -ComputerName $FQDN -ErrorAction 'STOP'
        }
        CATCH {
            $PSsession = New-PSSession ($FQDN) -UseSSL -Authentication Negotiate -SessionOption $PSOptions -ErrorAction 'stop'
        }
    }

    end {
        Return $PSsession
    }
}

# ---------------------------------------------------------------------------
# Main collection loop
# ---------------------------------------------------------------------------

$total     = $servers.Count
$succeeded = 0
$failed    = 0

Write-Host "Starting crypto inventory collection."
Write-Host "Servers  : $total"
Write-Host "Output   : $OutputPath"
Write-Host "Script   : $scriptPath"
Write-Host ''

for ($i = 0; $i -lt $servers.Count; $i++) {
    $server  = $servers[$i]
    $index   = $i + 1
    $session = $null

    Write-Host "[$index/$total] $server"

    # --- Connect ---
    try {
        $session = New-PSSessionToVM -FQDN $server
    }
    catch {
        Write-FailureLog -Server $server -Stage 'Connect' -ErrorMessage $_.Exception.Message
        $failed++
        continue
    }

    # --- Execute ---
    $result = $null
    try {
        $result = Invoke-Command -Session $session -FilePath $scriptPath -ErrorAction Stop
    }
    catch {
        Write-FailureLog -Server $server -Stage 'Execute' -ErrorMessage $_.Exception.Message
        $failed++
        Remove-PSSession $session
        continue
    }

    if (-not $result -or -not $result.ZipPath) {
        Write-FailureLog -Server $server -Stage 'Execute' -ErrorMessage 'Script completed but ZipPath was not returned.'
        $failed++
        Remove-PSSession $session
        continue
    }

    # --- Copy ZIP back to management VM ---
    try {
        Copy-Item -FromSession $session -Path $result.ZipPath -Destination $OutputPath -Force -ErrorAction Stop
        $destFile = Join-Path $OutputPath (Split-Path $result.ZipPath -Leaf)
        Write-Host "  Collected -> $destFile  (Certs: $($result.CertificateCount), Warn: $($result.WarningCount), Err: $($result.ErrorCount))"
        $succeeded++
    }
    catch {
        Write-FailureLog -Server $server -Stage 'Copy' -ErrorMessage $_.Exception.Message
        $failed++
    }
    finally {
        Remove-PSSession $session
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '------------------------------------------------------------'
Write-Host "Collection complete.  Succeeded: $succeeded  Failed: $failed"
Write-Host "Results  : $OutputPath"
if (Test-Path $failureLogPath) {
    Write-Host "Failures : $failureLogPath"
}
Write-Host '------------------------------------------------------------'
