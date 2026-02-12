#Requires -Version 5.1
<#
.SYNOPSIS
    Scheduled deployment processor for BlueCat DNS Manager.
.DESCRIPTION
    Reads pending scheduled jobs from the staging database and executes them
    via the BlueCat v2 API. Designed to be called by Windows Task Scheduler.
.PARAMETER BamServer
    The hostname or IP of the BlueCat Address Manager.
.PARAMETER Username
    BAM API username.
.PARAMETER PasswordFile
    Path to an encrypted password file created with Export-CliXml.
    If not provided, the script will look for .\data\cred.xml.
.PARAMETER SkipCertCheck
    Skip TLS certificate validation.
.PARAMETER DryRun
    Show what would be deployed without actually deploying.
.EXAMPLE
    # Create encrypted credential file (run once interactively):
    Get-Credential | Export-Clixml .\data\cred.xml

    # Run via Task Scheduler:
    powershell.exe -ExecutionPolicy Bypass -File .\scripts\ScheduledDeploy.ps1 -BamServer bam.corp.local
#>

param(
    [Parameter(Mandatory)][string]$BamServer,
    [string]$Username,
    [string]$PasswordFile,
    [int]$ConfigurationId,
    [int]$ViewId,
    [switch]$SkipCertCheck,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Setup paths
# ---------------------------------------------------------------------------

if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$scriptRoot = Split-Path -Parent $scriptDir
$modulesPath = Join-Path $scriptRoot 'modules'
$dataPath = Join-Path $scriptRoot 'data'
$libPath = Join-Path $scriptRoot 'lib'
$logPath = Join-Path $scriptRoot 'logs'

if (-not (Test-Path $logPath)) {
    New-Item -Path $logPath -ItemType Directory -Force | Out-Null
}

$logFile = Join-Path $logPath "scheduled_deploy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry
    Write-Host $entry
}

# ---------------------------------------------------------------------------
# Load dependencies
# ---------------------------------------------------------------------------

$sqliteDll = Join-Path $libPath 'System.Data.SQLite.dll'
if (-not (Test-Path $sqliteDll)) {
    Write-Log "SQLite DLL not found at $sqliteDll" 'FATAL'
    exit 1
}
Add-Type -Path $sqliteDll

Import-Module (Join-Path $modulesPath 'BlueCatApi.psm1') -Force
Import-Module (Join-Path $modulesPath 'StagingDb.psm1') -Force

# ---------------------------------------------------------------------------
# Initialize staging DB
# ---------------------------------------------------------------------------

$dbFile = Join-Path $dataPath 'staging.db'
if (-not (Test-Path $dbFile)) {
    Write-Log "Staging database not found at $dbFile" 'FATAL'
    exit 1
}

Initialize-StagingDb -Path $dbFile
Write-Log "Staging database opened: $dbFile"

# ---------------------------------------------------------------------------
# Check for pending scheduled jobs
# ---------------------------------------------------------------------------

$pendingJobs = Get-ScheduledPendingJobs
$jobCount = $pendingJobs.Rows.Count

if ($jobCount -eq 0) {
    Write-Log 'No pending scheduled jobs found. Exiting.'
    Close-StagingDb
    exit 0
}

Write-Log "Found $jobCount pending scheduled job(s)"

if ($DryRun) {
    Write-Log '=== DRY RUN MODE - No changes will be made ==='
    foreach ($row in $pendingJobs.Rows) {
        Write-Log "  Job $($row['id']): $($row['action']) $($row['record_type']) '$($row['record_name'])' in $($row['zone_name']) -> $($row['record_value']) (scheduled: $($row['scheduled_time']))"
    }
    Close-StagingDb
    exit 0
}

# ---------------------------------------------------------------------------
# Connect to BAM
# ---------------------------------------------------------------------------

$credFile = if ($PasswordFile) { $PasswordFile } else { Join-Path $dataPath 'cred.xml' }
if (-not (Test-Path $credFile)) {
    Write-Log "Credential file not found at $credFile. Create it with: Get-Credential | Export-Clixml '$credFile'" 'FATAL'
    Close-StagingDb
    exit 1
}

try {
    $cred = Import-Clixml $credFile
    Write-Log "Loaded credentials for user: $($cred.UserName)"
}
catch {
    Write-Log "Failed to load credentials: $($_.Exception.Message)" 'FATAL'
    Close-StagingDb
    exit 1
}

try {
    $connectParams = @{ Server = $BamServer; Credential = $cred }
    if ($SkipCertCheck) { $connectParams['SkipCertCheck'] = $true }
    Connect-BlueCat @connectParams
    Write-Log "Connected to BAM at $BamServer"
}
catch {
    Write-Log "Failed to connect to BAM: $($_.Exception.Message)" 'FATAL'
    Close-StagingDb
    exit 1
}

# Set context if provided
if ($ConfigurationId -and $ViewId) {
    Set-BlueCatContext -ConfigurationId $ConfigurationId -ViewId $ViewId
    Write-Log "Context set: Config=$ConfigurationId, View=$ViewId"
}

# ---------------------------------------------------------------------------
# Process each scheduled job
# ---------------------------------------------------------------------------

$successCount = 0
$failCount = 0

foreach ($row in $pendingJobs.Rows) {
    $jobId      = [int]$row['id']
    $action     = $row['action'].ToString()
    $recType    = $row['record_type'].ToString()
    $recName    = $row['record_name'].ToString()
    $zoneName   = $row['zone_name'].ToString()
    $recValue   = $row['record_value'].ToString()
    $ttl        = [int]$row['ttl']
    $entityId   = if ($row['bam_entity_id'] -is [DBNull]) { 0 } else { [int]$row['bam_entity_id'] }
    $comment    = if ($row['comment'] -is [DBNull]) { "Scheduled deploy via BlueCat DNS Manager" } else { $row['comment'].ToString() }

    Write-Log "Processing job $jobId`: $action $recType '$recName' in $zoneName"
    Update-StagedChangeStatus -Id $jobId -Status 'deploying'

    try {
        switch ($action) {
            'create' {
                # Find the zone
                $zone = Find-BlueCatZone -AbsoluteName $zoneName
                if (-not $zone) {
                    throw "Zone '$zoneName' not found in BAM"
                }

                $createParams = @{
                    ZoneId  = $zone.id
                    Type    = $recType
                    Name    = $recName
                    RData   = $recValue
                    TTL     = $ttl
                    Comment = $comment
                }
                $newRecord = New-BlueCatResourceRecord @createParams
                $entityId = $newRecord.id
                Write-Log "  Created record: entity ID $entityId"
            }
            'modify' {
                if ($entityId -le 0) {
                    throw "No entity ID for modify operation"
                }
                Update-BlueCatResourceRecord -Id $entityId -RData $recValue -TTL $ttl -Comment $comment -Type $recType
                Write-Log "  Modified record: entity ID $entityId"
            }
            'delete' {
                if ($entityId -le 0) {
                    throw "No entity ID for delete operation"
                }
                Remove-BlueCatResourceRecord -Id $entityId -Comment $comment
                Write-Log "  Deleted record: entity ID $entityId"
            }
        }

        # Deploy
        if ($entityId -gt 0 -and $action -ne 'delete') {
            $deployment = Invoke-BlueCatSelectiveDeploy -EntityId $entityId
            Write-Log "  Selective deploy initiated: deployment ID $($deployment.id)"
            Update-StagedChangeStatus -Id $jobId -Status 'deployed' -BamEntityId $entityId -DeploymentId $deployment.id
        }
        elseif ($action -eq 'delete') {
            # For deletes, use quick deploy on the zone
            $zone = Find-BlueCatZone -AbsoluteName $zoneName
            if ($zone) {
                $deployment = Invoke-BlueCatQuickDeploy -ZoneId $zone.id
                Write-Log "  Quick deploy (zone) initiated: deployment ID $($deployment.id)"
                Update-StagedChangeStatus -Id $jobId -Status 'deployed' -DeploymentId $deployment.id
            }
            else {
                Update-StagedChangeStatus -Id $jobId -Status 'deployed'
                Write-Log "  Record deleted, zone not found for deploy"
            }
        }

        $successCount++
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "  FAILED: $errMsg" 'ERROR'
        Update-StagedChangeStatus -Id $jobId -Status 'failed' -ErrorMessage $errMsg
        $failCount++
    }
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

Write-Log "Completed: $successCount succeeded, $failCount failed out of $jobCount jobs"

try { Disconnect-BlueCat } catch {}
Close-StagingDb

if ($failCount -gt 0) { exit 1 }
exit 0
