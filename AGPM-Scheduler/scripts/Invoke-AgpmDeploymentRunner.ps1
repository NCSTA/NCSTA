[CmdletBinding()]
param(
    [Parameter()]
    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Join-Path (Get-Location).Path 'scripts'
} else {
    $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $scriptDirectory '..\config\AgpmScheduler.config.json'
}
$modulePath = Join-Path $scriptDirectory '..\modules\AgpmScheduler\AgpmScheduler.psd1'
Import-Module $modulePath -Force

try {
    $config = Get-AgpmSchedulerConfig -Path $ConfigPath
    Invoke-AgpmDeploymentQueue -Config $config
    exit 0
} catch {
    Write-Error ("AGPM scheduled deployment runner failed: {0}`n{1}" -f
        $_.Exception.Message, $_.ScriptStackTrace)
    exit 1
}
