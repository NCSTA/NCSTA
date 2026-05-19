<#
.SYNOPSIS
    Wrapper for the VMware pre-migration data collection command.

.DESCRIPTION
    This wrapper keeps scheduled/file-based execution available. For console
    testing, import Collect-VMwareMigrationData.psm1 and run
    Invoke-VMwareMigrationDataCollection directly.
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$VMName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$VMListPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$vCenterServer,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = 'C:\MigrationData',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = 'C:\MigrationLogs',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$MigrationAccountUserName = 'Hypervmigrate',

    [Parameter()]
    [System.Management.Automation.PSCredential]$vCenterCredential,

    [Parameter()]
    [System.Management.Automation.PSCredential]$GuestCredential,

    [Parameter()]
    [switch]$SkipMigrationAccountCreation,

    [Parameter()]
    [switch]$IgnoreInvalidCertificate
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Collect-VMwareMigrationData.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

Invoke-VMwareMigrationDataCollection @PSBoundParameters
