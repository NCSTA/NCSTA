[CmdletBinding(DefaultParameterSetName = 'Collect')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Collect')]
    [ValidateNotNullOrEmpty()]
    [string]$ClientName,

    [Parameter(ParameterSetName = 'Collect')]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot = $PSScriptRoot,

    [Parameter(ParameterSetName = 'Collect')]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Config\AuditTargets.psd1'),

    [Parameter(ParameterSetName = 'Collect')]
    [switch]$IncludeGpoBackup,

    [Parameter(Mandatory, ParameterSetName = 'Verify')]
    [switch]$Verify,

    [Parameter(Mandatory, ParameterSetName = 'Verify')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$VerifyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Modules\Audit.Common.psm1') -Force

if ($Verify) {
    $result = Test-AuditManifest -AuditDirectory $VerifyPath
    $result | Format-Table -AutoSize
    if ($result.Where({ -not $_.Match }).Count -gt 0) { exit 1 }
    exit 0
}

Import-Module (Join-Path $PSScriptRoot 'Modules\Audit.Collectors.psm1') -Force

if (-not (Test-AuditAdministrator)) {
    throw 'This audit must be run from an elevated PowerShell session.'
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Configuration file not found: $ConfigPath"
}

$context = $null
$targets = Import-PowerShellDataFile -LiteralPath $ConfigPath
$context = New-AuditContext -ClientName $ClientName -OutputRoot $OutputRoot -Targets $targets -IncludeGpoBackup:$IncludeGpoBackup

try {
    Initialize-AuditReports -Context $context
    Write-Host "Writing audit reports to $($context.OutputDirectory)"

    Invoke-AuditSystemCollectors -Context $context
    Invoke-AuditPermissionCollectors -Context $context
    Invoke-AuditConfigurationCollectors -Context $context
    Invoke-AuditIdentityCollectors -Context $context
    Invoke-AuditSecurityPolicyCollector -Context $context
    New-AuditManifest -Context $context

    Write-Host 'Windows audit complete.'
    Write-Host "Output directory: $($context.OutputDirectory)"
}
catch {
    if ($context) {
        Write-AuditError -Context $context -Message $_.Exception.ToString()
    }
    throw
}
