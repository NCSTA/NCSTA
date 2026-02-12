#Requires -Version 5.1
<#
.SYNOPSIS
    Registers a Windows Scheduled Task to run ScheduledDeploy.ps1 on a recurring interval.
.DESCRIPTION
    Creates a Task Scheduler entry that processes pending scheduled DNS deployments.
    Run this once during initial setup.
.PARAMETER BamServer
    The hostname or IP of the BlueCat Address Manager.
.PARAMETER IntervalMinutes
    How often the task runs (default: 5 minutes).
.PARAMETER TaskName
    Name of the scheduled task (default: BlueCat-DNS-ScheduledDeploy).
.EXAMPLE
    .\Register-ScheduledTask.ps1 -BamServer bam.corp.local -IntervalMinutes 5
#>

param(
    [Parameter(Mandatory)][string]$BamServer,
    [int]$IntervalMinutes = 5,
    [string]$TaskName = 'BlueCat-DNS-ScheduledDeploy',
    [switch]$SkipCertCheck
)

if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
$scriptRoot = Split-Path -Parent $scriptDir
$deployScript = Join-Path $scriptRoot 'scripts\ScheduledDeploy.ps1'

if (-not (Test-Path $deployScript)) {
    Write-Error "ScheduledDeploy.ps1 not found at $deployScript"
    exit 1
}

# Check for credential file
$credFile = Join-Path $scriptRoot 'data\cred.xml'
if (-not (Test-Path $credFile)) {
    Write-Host "`nNo credential file found. Creating one now..." -ForegroundColor Yellow
    Write-Host "Enter the BAM service account credentials that will be used for scheduled deployments:" -ForegroundColor Cyan
    $cred = Get-Credential -Message "BlueCat BAM service account for scheduled deployments"
    if (-not $cred) {
        Write-Error "Credentials are required for scheduled deployments."
        exit 1
    }
    $dataDir = Join-Path $scriptRoot 'data'
    if (-not (Test-Path $dataDir)) {
        New-Item -Path $dataDir -ItemType Directory -Force | Out-Null
    }
    $cred | Export-Clixml $credFile
    Write-Host "Credentials saved to $credFile" -ForegroundColor Green
    Write-Host "NOTE: This file is encrypted with your Windows user profile. The scheduled task must run as the same user." -ForegroundColor Yellow
}

# Build the argument string
$arguments = "-ExecutionPolicy Bypass -NoProfile -NonInteractive -File `"$deployScript`" -BamServer `"$BamServer`""
if ($SkipCertCheck) {
    $arguments += " -SkipCertCheck"
}

# Create the scheduled task
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) -RepetitionDuration (New-TimeSpan -Days 9999)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopIfGoingOnBatteries -AllowStartIfOnBatteries -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited -LogonType S4U

# Check if task already exists
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    $confirm = Read-Host "Task '$TaskName' already exists. Overwrite? (Y/N)"
    if ($confirm -ne 'Y') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Processes pending scheduled DNS deployments via BlueCat DNS Manager"

Write-Host "`nScheduled task '$TaskName' registered successfully." -ForegroundColor Green
Write-Host "  Interval: Every $IntervalMinutes minute(s)" -ForegroundColor Cyan
Write-Host "  Script:   $deployScript" -ForegroundColor Cyan
Write-Host "  Server:   $BamServer" -ForegroundColor Cyan
Write-Host "`nThe task will check for pending scheduled deployments every $IntervalMinutes minutes." -ForegroundColor White
Write-Host "Use the GUI's 'Schedule' feature to queue future deployments." -ForegroundColor White
