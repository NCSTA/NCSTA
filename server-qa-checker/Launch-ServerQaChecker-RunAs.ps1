#Requires -Version 5.1
<#
.SYNOPSIS
    Launches Server QA Checker as an alternate user.
.DESCRIPTION
    Uses runas to start ServerQaChecker-GUI.ps1 under a specified account.
    Windows prompts for the password natively. The working directory is set
    to the project folder so all relative paths resolve correctly.
.NOTES
    Syntax: .\Launch-ServerQaChecker-RunAs.ps1 -Username DOMAIN\user
    If -Username is omitted you will be prompted to enter it.
#>

param(
    [string]$Username
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$guiScript = Join-Path $scriptDir 'ServerQaChecker-GUI.ps1'

if (-not (Test-Path $guiScript)) {
    Write-Error "Cannot find ServerQaChecker-GUI.ps1 at: $guiScript"
    exit 1
}

if (-not $Username) {
    $Username = Read-Host "Enter username (e.g. DOMAIN\tieraccount)"
}
if (-not $Username) { exit 0 }

$psArgs = "-ExecutionPolicy Bypass -NoProfile -STA -File `"$guiScript`""

runas /user:$Username "powershell.exe $psArgs"
