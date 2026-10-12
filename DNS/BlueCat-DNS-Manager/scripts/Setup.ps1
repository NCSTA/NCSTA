#Requires -Version 5.1
<#
.SYNOPSIS
    Setup script for BlueCat DNS Manager.
.DESCRIPTION
    Creates the lightweight data and log directories used by the GUI.
#>

if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptDir = $PSCommandPath | Split-Path -Parent
}

$scriptRoot = Split-Path -Parent $scriptDir
$dataPath = Join-Path $scriptRoot 'data'
$logsPath = Join-Path $scriptRoot 'logs'

Write-Host ''
Write-Host 'BlueCat DNS Manager - Setup' -ForegroundColor Cyan
Write-Host '===========================' -ForegroundColor Cyan
Write-Host ''
Write-Host "Project root: $scriptRoot" -ForegroundColor Gray
Write-Host ''

foreach ($dir in @($dataPath, $logsPath)) {
    if (-not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        Write-Host "  Created: $dir" -ForegroundColor Green
    } else {
        Write-Host "  Exists:  $dir" -ForegroundColor Green
    }
}

$logFile = Join-Path $logsPath "bluecat-dns-manager-$(Get-Date -Format 'yyyyMMdd').jsonl"
if (-not (Test-Path $logFile)) {
    New-Item -Path $logFile -ItemType File -Force | Out-Null
    Write-Host "  Created: $logFile" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Setup complete. No SQLite or native DLL dependencies are required.' -ForegroundColor Green
Write-Host ''
Write-Host 'Press any key to exit...' -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
