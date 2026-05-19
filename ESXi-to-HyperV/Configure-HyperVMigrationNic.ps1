<#
.SYNOPSIS
    Wrapper for the post-migration Hyper-V NIC configuration command.

.DESCRIPTION
    This wrapper keeps scheduled/file-based execution available. For console
    testing, import Configure-HyperVMigrationNic.psm1 and run
    Invoke-HyperVMigrationNicConfiguration directly.
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VMListPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$VMMServer = $env:COMPUTERNAME,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DataDirectory = 'C:\MigrationData',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = 'C:\MigrationLogs',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ProductionSwitchName = 'Production Switch',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$MigrationAccountUserName = 'Hypervmigrate',

    [Parameter()]
    [System.Management.Automation.PSCredential]$SCVMMCredential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$HostCredential,

    [Parameter()]
    [switch]$DisableHyperVFallback
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Configure-HyperVMigrationNic.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

Invoke-HyperVMigrationNicConfiguration @PSBoundParameters
