#Requires -Version 5.1
<#
.SYNOPSIS
    Launches the gMSA Management Utility as an alternate user.
.DESCRIPTION
    Uses runas to start gMSA-Creation-GUI.ps1 under a specified account.
    Windows prompts for the password natively.

    Use -NetOnly from a workstation that is not joined to the target domain:
    the account is then used only for network access such as Active Directory,
    while the window itself runs as the local user.
.NOTES
    Syntax: .\Launch-gMSA-GUI-RunAs.ps1 -Username DOMAIN\user [-NetOnly]
    If -Username is omitted you will be prompted to enter it.
#>

param(
    [string]$Username,
    [switch]$NetOnly
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$guiScript = Join-Path $scriptDir 'gMSA-Creation-GUI.ps1'

if (-not (Test-Path $guiScript)) {
    Write-Error "Cannot find gMSA-Creation-GUI.ps1 at: $guiScript"
    exit 1
}

if (-not $Username) {
    $Username = Read-Host "Enter username (e.g. DOMAIN\tieraccount)"
}
if (-not $Username) { exit 0 }

$psArgs = "-ExecutionPolicy Bypass -NoProfile -STA -File `"$guiScript`""

$runasArgs = @("/user:$Username")
if ($NetOnly) { $runasArgs = @('/netonly') + $runasArgs }

runas @runasArgs "powershell.exe $psArgs"
