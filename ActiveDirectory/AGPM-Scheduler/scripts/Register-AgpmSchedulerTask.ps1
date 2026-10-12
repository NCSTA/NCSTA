[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string] $ConfigPath,

    [Parameter()]
    [string] $RunAsAccount,

    [Parameter()]
    [switch] $UseGmsa
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
$config = Get-AgpmSchedulerConfig -Path $ConfigPath

$runner = (Resolve-Path (Join-Path $scriptDirectory 'Invoke-AgpmDeploymentRunner.ps1')).Path
$resolvedConfig = (Resolve-Path $ConfigPath).Path
$arguments = '-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "{0}" -ConfigPath "{1}"' -f
    $runner, $resolvedConfig
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments `
    -WorkingDirectory (Split-Path -Parent $runner)
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes ([int]$config.Runner.PollMinutes)) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

if ($UseGmsa) {
    if ([string]::IsNullOrWhiteSpace($RunAsAccount) -or -not $RunAsAccount.EndsWith('$')) {
        throw 'For a gMSA, provide -RunAsAccount in DOMAIN\Account$ format.'
    }
    $principal = New-ScheduledTaskPrincipal -UserId $RunAsAccount -LogonType ServiceAccount `
        -RunLevel Highest
} elseif (-not [string]::IsNullOrWhiteSpace($RunAsAccount)) {
    $credential = Get-Credential -UserName $RunAsAccount -Message 'Scheduled task identity'
    $principal = New-ScheduledTaskPrincipal -UserId $credential.UserName -LogonType Password `
        -RunLevel Highest
} else {
    throw 'Specify -RunAsAccount and optionally -UseGmsa.'
}

$taskName = [string]$config.ScheduledTask.TaskName
$taskPath = [string]$config.ScheduledTask.TaskPath
if ($PSCmdlet.ShouldProcess("$taskPath$taskName", 'Register AGPM scheduler task')) {
    if ($UseGmsa) {
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action `
            -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    } else {
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action `
            -Trigger $trigger -Settings $settings -User $credential.UserName `
            -Password $credential.GetNetworkCredential().Password -RunLevel Highest -Force | Out-Null
    }
    Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath
}
