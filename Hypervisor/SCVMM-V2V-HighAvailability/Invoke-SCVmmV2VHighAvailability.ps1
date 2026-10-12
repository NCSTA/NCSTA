#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#
# Configuration
#
$Config = [ordered]@{
    VmmServerName                = 'scvmm01.domain.com'
    DestinationVmHostName        = 'hyperv01.domain.com'
    SourceVmName                 = 'server01'
    SourceVmId                   = '00000000-0000-0000-0000-000000000001'
    SourceVmHostName             = 'esxi01.domain.com'
    DestinationPath              = 'C:\ClusterStorage\Volume5'
    DestinationVmName            = 'server01'
    Description                  = ''
    Generation                   = 2
    CPUCount                     = 6
    MemoryMB                     = 16384
    DelayStartSeconds            = 120
    HAVMPriority                 = 2000
    GuestComputerName            = 'server01'
    GuestCredential              = $null
    VMwareToolsPackageName       = 'VMware Tools'
    RestartGuestAfterToolsRemove = $false
    RestartTimeoutMinutes        = 20
    LogRoot                      = 'C:\Logs\SCVMM-V2V'
}

$NetworkMappings = @(
    [pscustomobject]@{
        VirtualNetworkName      = 'Production Switch'
        VirtualNetworkHostId    = '00000000-0000-0000-0000-000000000002'
        VirtualNetworkAdapterId = '00000000-0000-0000-0000-000000000003'
        VMNetworkName           = '10.0.10.x Network'
        VMNetworkId             = '00000000-0000-0000-0000-000000000004'
        VLanId                  = 100
    }
    [pscustomobject]@{
        VirtualNetworkName      = 'Backend Switch'
        VirtualNetworkHostId    = '00000000-0000-0000-0000-000000000002'
        VirtualNetworkAdapterId = '00000000-0000-0000-0000-000000000005'
        VMNetworkName           = '10.0.20.x Network'
        VMNetworkId             = '00000000-0000-0000-0000-000000000006'
        VLanId                  = 200
    }
)

#
# Helper Functions
#
function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} [{1}] {2}' -f $timestamp, $Level, $Message
    Write-Host $line
    Add-Content -Path $script:LogFile -Value $line
}

function Resolve-SingleItem {
    param(
        [Parameter(Mandatory)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not $InputObject -or $InputObject.Count -eq 0) {
        throw "Unable to resolve $Label."
    }

    if ($InputObject.Count -gt 1) {
        throw "Resolved more than one result for $Label."
    }

    return $InputObject[0]
}

function Wait-SCVmmJob {
    param(
        [Parameter(Mandatory)]
        [object]$Job,

        [Parameter(Mandatory)]
        [object]$VmmServer,

        [int]$PollSeconds = 15
    )

    $jobId = $Job.ID
    if (-not $jobId) {
        throw 'The VMM job object did not include an ID.'
    }

    while ($true) {
        $currentJob = Get-SCJob -VMMServer $VmmServer -ID $jobId
        Write-Log -Message ("VMM job '{0}' status: {1}" -f $currentJob.Name, $currentJob.Status)

        if ($currentJob.Status -in @('Completed', 'CompletedWithInfo', 'CompletedWithWarnings')) {
            return $currentJob
        }

        if ($currentJob.Status -in @('Failed', 'Canceled')) {
            $details = @(
                "Job Name: $($currentJob.Name)"
                "Status: $($currentJob.Status)"
                "ErrorCode: $($currentJob.ErrorCode)"
                "ErrorString: $($currentJob.ErrorString)"
            ) -join ' | '

            throw "VMM job failed. $details"
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function Remove-VMwareTools {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$PackageName,

        [pscredential]$Credential,

        [bool]$RestartAfterRemoval,

        [int]$RestartTimeoutMinutes
    )

    Write-Log -Message "Connecting to guest '$ComputerName' to uninstall '$PackageName'."

    $sessionParams = @{
        ComputerName = $ComputerName
    }

    if ($Credential) {
        $sessionParams.Credential = $Credential
    }

    $session = New-PSSession @sessionParams
    try {
        $result = Invoke-Command -Session $session -ScriptBlock {
            param($Name)

            $package = Get-Package -Name $Name -ErrorAction SilentlyContinue
            if (-not $package) {
                return [pscustomobject]@{
                    Found    = $false
                    Removed  = $false
                    Message  = "Package '$Name' was not found."
                    Rebooted = $false
                }
            }

            $package | Uninstall-Package -Force -ErrorAction Stop

            return [pscustomobject]@{
                Found    = $true
                Removed  = $true
                Message  = "Package '$Name' was removed."
                Rebooted = $false
            }
        } -ArgumentList $PackageName

        Write-Log -Message $result.Message

        if ($RestartAfterRemoval -and $result.Removed) {
            Write-Log -Message "Restarting guest '$ComputerName' after VMware Tools removal."
            Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force }
            Remove-PSSession -Session $session
            $session = $null

            $timeout = (Get-Date).AddMinutes($RestartTimeoutMinutes)
            while ((Get-Date) -lt $timeout) {
                Start-Sleep -Seconds 15
                if (Test-WSMan -ComputerName $ComputerName -ErrorAction SilentlyContinue) {
                    Write-Log -Message "Guest '$ComputerName' is reachable again after restart."
                    return
                }
            }

            throw "Guest '$ComputerName' did not come back within $RestartTimeoutMinutes minutes."
        }
    }
    finally {
        if ($session) {
            Remove-PSSession -Session $session
        }
    }
}

function Enable-HighAvailability {
    param(
        [Parameter(Mandatory)]
        [object]$VmmServer,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$Priority
    )

    Write-Log -Message "Resolving converted VM '$VmName' for HA enablement."
    $vm = Resolve-SingleItem -InputObject @(Get-SCVirtualMachine -VMMServer $VmmServer -Name $VmName) -Label "converted VM '$VmName'"

    if ($vm.IsHighlyAvailable) {
        Write-Log -Message "VM '$VmName' is already highly available."
        return $vm
    }

    Write-Log -Message "Enabling HA on VM '$VmName' with priority '$Priority'."
    $updatedVm = Set-SCVirtualMachine -VM $vm -HighlyAvailable $true -HAVMPriority $Priority
    Write-Log -Message "HA enablement completed for VM '$VmName'."
    return $updatedVm
}

#
# Script Start
#
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -Path $Config.LogRoot)) {
    New-Item -Path $Config.LogRoot -ItemType Directory -Force | Out-Null
}

$script:LogFile = Join-Path -Path $Config.LogRoot -ChildPath ("{0}-{1}.log" -f $Config.DestinationVmName, $timestamp)
Start-Transcript -Path (Join-Path -Path $Config.LogRoot -ChildPath ("{0}-{1}.transcript.txt" -f $Config.DestinationVmName, $timestamp)) -Force | Out-Null

try {
    Write-Log -Message "Starting SCVMM V2V workflow for '$($Config.SourceVmName)'."
    Write-Log -Message "Log file: $script:LogFile"

    Import-Module VirtualMachineManager -ErrorAction Stop
    Write-Log -Message 'VirtualMachineManager module loaded.'

    $guestStepSucceeded = $false
    try {
        Remove-VMwareTools `
            -ComputerName $Config.GuestComputerName `
            -PackageName $Config.VMwareToolsPackageName `
            -Credential $Config.GuestCredential `
            -RestartAfterRemoval $Config.RestartGuestAfterToolsRemove `
            -RestartTimeoutMinutes $Config.RestartTimeoutMinutes

        $guestStepSucceeded = $true
    }
    catch {
        Write-Log -Level WARN -Message ("Guest preparation step failed: {0}" -f $_.Exception.Message)
        throw
    }

    if ($guestStepSucceeded) {
        Write-Log -Message 'Guest preparation completed successfully.'
    }

    $vmmServer = Get-SCVMMServer -ComputerName $Config.VmmServerName
    Write-Log -Message "Connected to VMM server '$($Config.VmmServerName)'."

    $vmHost = Resolve-SingleItem `
        -InputObject @(Get-SCVMHost -VMMServer $vmmServer | Where-Object { $_.Name -eq $Config.DestinationVmHostName }) `
        -Label "destination VM host '$($Config.DestinationVmHostName)'"

    $sourceVm = Resolve-SingleItem `
        -InputObject @(Get-SCVirtualMachine -VMMServer $vmmServer -Name $Config.SourceVmName -ID $Config.SourceVmId | Where-Object { $_.VMHost.Name -eq $Config.SourceVmHostName }) `
        -Label "source VM '$($Config.SourceVmName)'"

    $jobGroup = [guid]::NewGuid()
    Write-Log -Message "Using VMM job group '$jobGroup'."

    foreach ($mapping in $NetworkMappings) {
        Write-Log -Message ("Preparing network mapping for adapter '{0}' on VM network '{1}'." -f $mapping.VirtualNetworkAdapterId, $mapping.VMNetworkName)

        $virtualNetwork = Resolve-SingleItem `
            -InputObject @(Get-SCVirtualNetwork -VMMServer $vmmServer -Name $mapping.VirtualNetworkName | Where-Object { $_.VMHostID -eq $mapping.VirtualNetworkHostId }) `
            -Label "virtual network '$($mapping.VirtualNetworkName)'"

        $virtualNetworkAdapter = Resolve-SingleItem `
            -InputObject @(Get-SCVirtualNetworkAdapter -VMMServer $vmmServer -Name $Config.SourceVmName -ID $mapping.VirtualNetworkAdapterId) `
            -Label "virtual network adapter '$($mapping.VirtualNetworkAdapterId)'"

        $vmNetwork = Resolve-SingleItem `
            -InputObject @(Get-SCVMNetwork -VMMServer $vmmServer -Name $mapping.VMNetworkName -ID $mapping.VMNetworkId) `
            -Label "VM network '$($mapping.VMNetworkName)'"

        New-SCV2V `
            -VMMServer $vmmServer `
            -VMHost $vmHost `
            -JobGroup $jobGroup `
            -VM $sourceVm `
            -VirtualNetwork $virtualNetwork `
            -VirtualNetworkAdapter $virtualNetworkAdapter `
            -VMNetwork $vmNetwork `
            -VLanEnabled $true `
            -VLanId $mapping.VLanId | Out-Null

        Write-Log -Message ("Queued network mapping '{0}' with VLAN {1}." -f $mapping.VMNetworkName, $mapping.VLanId)
    }

    Write-Log -Message 'Submitting V2V conversion job.'
    $conversionJob = New-SCV2V `
        -VMMServer $vmmServer `
        -VM $sourceVm `
        -VMHost $vmHost `
        -Path $Config.DestinationPath `
        -Name $Config.DestinationVmName `
        -Description $Config.Description `
        -RunAsynchronously `
        -JobGroup $jobGroup `
        -Trigger `
        -Generation $Config.Generation `
        -CPUCount $Config.CPUCount `
        -MemoryMB $Config.MemoryMB `
        -DelayStartSeconds $Config.DelayStartSeconds

    $completedJob = Wait-SCVmmJob -Job $conversionJob -VmmServer $vmmServer
    Write-Log -Message ("V2V conversion completed with status '{0}'." -f $completedJob.Status)

    Enable-HighAvailability -VmmServer $vmmServer -VmName $Config.DestinationVmName -Priority $Config.HAVMPriority | Out-Null

    Write-Log -Message "Workflow completed successfully for '$($Config.DestinationVmName)'."
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    Write-Log -Level ERROR -Message $_.ScriptStackTrace
    throw
}
finally {
    Stop-Transcript | Out-Null
}
