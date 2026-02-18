#Requires -Version 5.1
<#
.SYNOPSIS
    Launches Server QA Checker as an alternate user.
.DESCRIPTION
    Prompts for credentials and starts ServerQaChecker-GUI.ps1 under the
    specified account. The working directory is set to the project folder so
    all relative paths (modules, templates, reports) resolve correctly.
#>

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$guiScript = Join-Path $scriptDir 'ServerQaChecker-GUI.ps1'

if (-not (Test-Path $guiScript)) {
    Write-Error "Cannot find ServerQaChecker-GUI.ps1 at: $guiScript"
    exit 1
}

$credential = Get-Credential -Message "Enter credentials to run Server QA Checker"
if (-not $credential) { exit 0 }

Start-Process powershell.exe `
    -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$guiScript`"" `
    -WorkingDirectory $scriptDir `
    -Credential $credential
