Set-StrictMode -Version 2.0

function Get-AgpmSchedulerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $config = Get-Content -LiteralPath $resolvedPath -Raw -ErrorAction Stop |
        ConvertFrom-Json -ErrorAction Stop

    if ($config.SchemaVersion -ne 1) {
        throw "Unsupported configuration schema version '$($config.SchemaVersion)'."
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.Paths.DataRoot)) {
        throw 'Paths.DataRoot is required.'
    }

    if (-not $config.Domains) {
        throw 'At least one domain must be configured.'
    }

    Add-Member -InputObject $config -NotePropertyName ConfigPath -NotePropertyValue $resolvedPath -Force
    return $config
}

function Initialize-AgpmSchedulerData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config
    )

    $root = [Environment]::ExpandEnvironmentVariables([string]$Config.Paths.DataRoot)
    $paths = [ordered]@{
        Root      = $root
        Pending   = Join-Path $root 'Queue\Pending'
        Running   = Join-Path $root 'Queue\Running'
        Completed = Join-Path $root 'Queue\Completed'
        Failed    = Join-Path $root 'Queue\Failed'
        Cancelled = Join-Path $root 'Queue\Cancelled'
        Logs      = Join-Path $root 'Logs'
    }

    foreach ($path in $paths.Values) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop | Out-Null
        }
    }

    return [pscustomobject]$paths
}

function Get-AgpmControlledGpo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Domain
    )

    Import-Module Microsoft.Agpm -ErrorAction Stop
    @(Microsoft.Agpm\Get-ControlledGpo -Domain $Domain -ErrorAction Stop)
}

function ConvertTo-NormalizedGuidString {
    param([Parameter(Mandatory)] $Value)
    return ([guid]([string]$Value).Trim('{}')).ToString('D').ToUpperInvariant()
}

function Write-AgpmJsonAtomic {
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [string] $Path
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f
        [IO.Path]::GetFileName($Path), [guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function New-AgpmDeploymentJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config,

        [Parameter(Mandatory)]
        [datetime] $ScheduledAt,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RequestedBy,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ChangeTicket,

        [Parameter()]
        [AllowEmptyString()]
        [string] $Comment,

        [Parameter()]
        [string[]] $NotifyTo,

        [Parameter()]
        [bool] $TestMode = $true,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [object[]] $Selections
    )

    if ($ScheduledAt -le (Get-Date).AddMinutes(-1)) {
        throw 'The scheduled time must be in the future.'
    }

    $paths = Initialize-AgpmSchedulerData -Config $Config
    $items = foreach ($selection in $Selections) {
        if ([string]$selection.State -ne 'CHECKED_IN') {
            throw "GPO '$($selection.Name)' is not checked in."
        }

        [ordered]@{
            Domain                 = [string]$selection.Domain
            Name                   = [string]$selection.Name
            GpoId                  = ConvertTo-NormalizedGuidString $selection.ID
            ExpectedBackupId       = ConvertTo-NormalizedGuidString $selection.BackupID
            ExpectedComputerVersion = [int]$selection.ComputerVersion
            ExpectedUserVersion     = [int]$selection.UserVersion
        }
    }

    $duplicate = $items | Group-Object Domain, GpoId | Where-Object Count -gt 1
    if ($duplicate) {
        throw 'The selection contains a duplicate domain/GPO combination.'
    }

    $jobId = [guid]::NewGuid().ToString('D')
    $job = [ordered]@{
        SchemaVersion = 1
        JobId          = $jobId
        Status         = 'Pending'
        ScheduledAt    = $ScheduledAt.ToString('o')
        CreatedAt      = (Get-Date).ToString('o')
        StartedAt      = $null
        CompletedAt    = $null
        RequestedBy    = $RequestedBy
        ChangeTicket   = $ChangeTicket
        Comment        = $Comment
        NotifyTo       = @($NotifyTo | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        WhatIf          = $TestMode
        Gpos            = @($items)
        Results         = @()
    }

    $path = Join-Path $paths.Pending "$jobId.json"
    Write-AgpmJsonAtomic -Value $job -Path $path
    return [pscustomobject]$job
}

function Get-AgpmDeploymentJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config,

        [ValidateSet('Pending', 'Running', 'Completed', 'Failed', 'Cancelled', 'All')]
        [string] $Status = 'All'
    )

    $paths = Initialize-AgpmSchedulerData -Config $Config
    $states = if ($Status -eq 'All') {
        @('Pending', 'Running', 'Completed', 'Failed', 'Cancelled')
    } else {
        @($Status)
    }

    foreach ($state in $states) {
        Get-ChildItem -LiteralPath $paths.$state -Filter '*.json' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                try {
                    $job = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                    Add-Member -InputObject $job -NotePropertyName QueuePath -NotePropertyValue $_.FullName -Force
                    $job
                } catch {
                    Write-Warning "Could not read job '$($_.FullName)': $($_.Exception.Message)"
                }
            }
    }
}

function Stop-AgpmDeploymentJob {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $JobId
    )

    $paths = Initialize-AgpmSchedulerData -Config $Config
    $source = Join-Path $paths.Pending "$JobId.json"
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Pending job '$JobId' was not found. Running or completed jobs cannot be cancelled."
    }

    if ($PSCmdlet.ShouldProcess($JobId, 'Cancel AGPM deployment job')) {
        $job = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
        $job.Status = 'Cancelled'
        Add-Member -InputObject $job -NotePropertyName CancelledAt -NotePropertyValue (Get-Date).ToString('o') -Force
        $destination = Join-Path $paths.Cancelled "$JobId.json"
        Write-AgpmJsonAtomic -Value $job -Path $destination
        Remove-Item -LiteralPath $source -Force
        return $job
    }
}

function Write-AgpmAuditRecord {
    param(
        [Parameter(Mandatory)] [psobject] $Paths,
        [Parameter(Mandatory)] $Record
    )

    $path = Join-Path $Paths.Logs ('AGPMScheduler-{0}.jsonl' -f (Get-Date -Format 'yyyy-MM'))
    $line = $Record | ConvertTo-Json -Depth 10 -Compress
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop
}

function Write-AgpmEvent {
    param(
        [Parameter(Mandatory)] [psobject] $Paths,
        [Parameter(Mandatory)] [string] $Event,
        [Parameter()] $Job,
        [Parameter()] [string] $Message,
        [Parameter()] $Details
    )

    $record = [ordered]@{
        Timestamp    = (Get-Date).ToString('o')
        Event        = $Event
        ProcessId    = $PID
        ComputerName = $env:COMPUTERNAME
        RunAs        = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    if ($null -ne $Job) {
        $record.JobId = [string]$Job.JobId
        $record.ChangeTicket = [string]$Job.ChangeTicket
    }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        $record.Message = $Message
    }
    if ($null -ne $Details) {
        $record.Details = $Details
    }
    Write-AgpmAuditRecord -Paths $Paths -Record $record
}

function Send-AgpmJobEmail {
    param(
        [Parameter(Mandatory)] [psobject] $Config,
        [Parameter(Mandatory)] $Job
    )

    if (-not $Config.Email.Enabled) {
        return [pscustomobject]@{
            Status = 'SkippedDisabled'
            Recipients = @()
        }
    }

    $recipients = @($Job.NotifyTo) + @($Config.Email.DefaultTo)
    $recipients = @($recipients | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | Select-Object -Unique)
    if (-not $recipients) {
        return [pscustomobject]@{
            Status = 'SkippedNoRecipients'
            Recipients = @()
        }
    }

    $rows = foreach ($result in $Job.Results) {
        $resultColor = if ($result.Status -eq 'Failed') { '#B42318' } else { '#157A55' }
        @'
<tr>
  <td style="padding:11px;font-size:12px;border-top:1px solid #d8e0ea;">{0}</td>
  <td style="padding:11px;font-size:12px;border-top:1px solid #d8e0ea;">{1}</td>
  <td style="padding:11px;font-size:12px;border-top:1px solid #d8e0ea;color:{4};font-weight:600;">{2}</td>
  <td style="padding:11px;font-size:12px;border-top:1px solid #d8e0ea;">{3}</td>
</tr>
'@ -f
            [Net.WebUtility]::HtmlEncode([string]$result.Domain),
            [Net.WebUtility]::HtmlEncode([string]$result.Name),
            [Net.WebUtility]::HtmlEncode(([string]$result.Status).ToUpperInvariant()),
            [Net.WebUtility]::HtmlEncode([string]$result.Message),
            $resultColor
    }
    $encodedStatus = [Net.WebUtility]::HtmlEncode([string]$Job.Status)
    $encodedTicket = [Net.WebUtility]::HtmlEncode([string]$Job.ChangeTicket)
    $encodedJobId = [Net.WebUtility]::HtmlEncode([string]$Job.JobId)
    $encodedRequester = [Net.WebUtility]::HtmlEncode([string]$Job.RequestedBy)
    $encodedComment = [Net.WebUtility]::HtmlEncode([string]$Job.Comment)
    $mode = if ($null -ne $Job.PSObject.Properties['WhatIf'] -and $Job.WhatIf) {
        'Test simulation'
    } else {
        'Live deployment'
    }
    $failureCount = @($Job.Results | Where-Object Status -eq 'Failed').Count
    $successCount = @($Job.Results).Count - $failureCount
    $summary = "$successCount succeeded and $failureCount failed."
    $badgeBackground = if ($failureCount -gt 0) { '#FFF4E5' } else { '#EAF8F2' }
    $badgeBorder = if ($failureCount -gt 0) { '#F0B45C' } else { '#65B99A' }
    $badgeText = if ($failureCount -gt 0) { '#8A4B00' } else { '#126144' }
    $body = @"
<!doctype html>
<html lang="en">
<body style="margin:0;padding:0;background:#eef2f6;color:#233142;font-family:'Segoe UI',Arial,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;background:#eef2f6;">
<tr><td align="center" style="padding:30px 14px;">
<table role="presentation" width="760" cellspacing="0" cellpadding="0" border="0" style="width:100%;max-width:760px;background:#ffffff;border:1px solid #d8e0ea;">
<tr><td style="padding:24px 28px;background:#17324d;color:#ffffff;">
<div style="font-size:22px;font-weight:600;">AGPM Deployment</div>
<div style="padding-top:6px;color:#c9d8e8;font-size:13px;">Scheduled Group Policy deployment report</div>
</td></tr>
<tr><td style="padding:24px 28px 10px 28px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0"><tr>
<td><div style="font-size:20px;font-weight:600;color:#17324d;">Deployment $encodedStatus</div>
<div style="padding-top:5px;color:#637083;font-size:13px;">$summary</div></td>
<td align="right"><span style="display:inline-block;padding:7px 12px;background:$badgeBackground;border:1px solid $badgeBorder;color:$badgeText;font-size:12px;font-weight:600;">$($encodedStatus.ToUpperInvariant())</span></td>
</tr></table>
</td></tr>
<tr><td style="padding:12px 28px 22px 28px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="border:1px solid #d8e0ea;background:#f8fafc;">
<tr><td width="150" style="padding:9px 12px;color:#637083;font-size:12px;">Change ticket</td><td style="padding:9px 12px;font-size:13px;font-weight:600;">$encodedTicket</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Job ID</td><td style="padding:9px 12px;font-size:12px;border-top:1px solid #e4e9ef;font-family:Consolas,monospace;">$encodedJobId</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Requested by</td><td style="padding:9px 12px;font-size:13px;border-top:1px solid #e4e9ef;">$encodedRequester</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Scheduled</td><td style="padding:9px 12px;font-size:13px;border-top:1px solid #e4e9ef;">$($Job.ScheduledAt)</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Completed</td><td style="padding:9px 12px;font-size:13px;border-top:1px solid #e4e9ef;">$($Job.CompletedAt)</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Mode</td><td style="padding:9px 12px;font-size:13px;border-top:1px solid #e4e9ef;">$mode</td></tr>
<tr><td style="padding:9px 12px;color:#637083;font-size:12px;border-top:1px solid #e4e9ef;">Comment</td><td style="padding:9px 12px;font-size:13px;border-top:1px solid #e4e9ef;">$encodedComment</td></tr>
</table>
</td></tr>
<tr><td style="padding:0 28px 10px 28px;font-size:16px;font-weight:600;color:#17324d;">Deployment results</td></tr>
<tr><td style="padding:0 28px 26px 28px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="border:1px solid #d8e0ea;border-collapse:collapse;">
<tr style="background:#17324d;color:#ffffff;">
<th align="left" style="padding:10px 11px;font-size:12px;">Domain</th>
<th align="left" style="padding:10px 11px;font-size:12px;">GPO</th>
<th align="left" style="padding:10px 11px;font-size:12px;">Result</th>
<th align="left" style="padding:10px 11px;font-size:12px;">Details</th>
</tr>
$($rows -join [Environment]::NewLine)
</table>
</td></tr>
<tr><td style="padding:16px 28px;background:#f8fafc;border-top:1px solid #d8e0ea;color:#637083;font-size:11px;">
This message was generated automatically by the AGPM Deployment Scheduler. Review the job audit record before retrying a failed deployment.
</td></tr>
</table>
</td></tr></table>
</body></html>
"@

    $parameters = @{
        SmtpServer = [string]$Config.Email.SmtpServer
        Port       = [int]$Config.Email.Port
        UseSsl     = [bool]$Config.Email.UseSsl
        From       = [string]$Config.Email.From
        To         = $recipients
        Subject    = "AGPM deployment $($Job.Status): $($Job.ChangeTicket)"
        Body       = $body
        BodyAsHtml = $true
        ErrorAction = 'Stop'
    }
    Send-MailMessage @parameters
    return [pscustomobject]@{
        Status = 'Sent'
        Recipients = @($recipients)
    }
}

function Invoke-AgpmGpoDeployment {
    param(
        [Parameter(Mandatory)] [psobject] $Config,
        [Parameter(Mandatory)] $Item,
        [Parameter(Mandatory)] $Job
    )

    $started = Get-Date
    $result = [ordered]@{
        Domain    = [string]$Item.Domain
        Name      = [string]$Item.Name
        GpoId     = [string]$Item.GpoId
        StartedAt = $started.ToString('o')
        EndedAt   = $null
        Status    = 'Failed'
        Message   = $null
    }

    try {
        $gpo = Get-AgpmControlledGpo -Domain $Item.Domain |
            Where-Object {
                (ConvertTo-NormalizedGuidString $_.ID) -eq
                    (ConvertTo-NormalizedGuidString $Item.GpoId)
            } |
            Select-Object -First 1

        if (-not $gpo) {
            throw "The controlled GPO was not found by ID '$($Item.GpoId)'."
        }
        if ([string]$gpo.State -ne 'CHECKED_IN') {
            throw "Current AGPM state is '$($gpo.State)', not CHECKED_IN."
        }
        if ((ConvertTo-NormalizedGuidString $gpo.BackupID) -ne
            (ConvertTo-NormalizedGuidString $Item.ExpectedBackupId)) {
            throw 'The AGPM archive revision changed after this deployment was scheduled.'
        }
        if ([int]$gpo.ComputerVersion -ne [int]$Item.ExpectedComputerVersion -or
            [int]$gpo.UserVersion -ne [int]$Item.ExpectedUserVersion) {
            throw 'The AGPM user or computer version changed after scheduling.'
        }

        $comment = '{0} | Job {1} | Requested by {2} | {3}' -f
            $Job.ChangeTicket, $Job.JobId, $Job.RequestedBy, $Job.Comment
        $publishParameters = @{
            ControlledGpos = @($gpo)
            Domain         = [string]$Item.Domain
            Comment        = $comment.Trim(' ', '|')
            PassThru       = $true
            Confirm        = $false
            ErrorAction    = 'Stop'
        }
        $jobWhatIf = if ($null -ne $Job.PSObject.Properties['WhatIf']) {
            [bool]$Job.WhatIf
        } else {
            [bool]$Config.Runner.WhatIf
        }
        if ($jobWhatIf) {
            $publishParameters.WhatIf = $true
        }

        Microsoft.Agpm\Publish-ControlledGpo @publishParameters | Out-Null

        if ($jobWhatIf) {
            $result.Status = 'WhatIf'
            $result.Message = 'Validation succeeded; deployment was simulated.'
        } else {
            Import-Module GroupPolicy -ErrorAction Stop
            $verified = $false
            $production = $null
            $attempts = [Math]::Max(1, [int]$Config.Runner.VerificationRetryCount + 1)
            for ($attempt = 1; $attempt -le $attempts; $attempt++) {
                $production = Get-GPO -Guid ([guid]$Item.GpoId) -Domain $Item.Domain `
                    -ErrorAction Stop
                $verified =
                    [int]$production.Computer.DSVersion -eq [int]$gpo.ComputerVersion -and
                    [int]$production.User.DSVersion -eq [int]$gpo.UserVersion
                if ($verified) {
                    break
                }
                if ($attempt -lt $attempts) {
                    Start-Sleep -Seconds ([int]$Config.Runner.VerificationRetryDelaySeconds)
                }
            }
            if (-not $verified) {
                throw ('Publish returned, but production versions did not match AGPM after ' +
                    "$attempts verification attempt(s). " +
                    "AGPM C/U=$($gpo.ComputerVersion)/$($gpo.UserVersion); " +
                    "production C/U=$($production.Computer.DSVersion)/$($production.User.DSVersion).")
            }
            $result.Status = 'Success'
            $result.Message = 'Published and production user/computer versions verified.'
        }
    } catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
    } finally {
        $result.EndedAt = (Get-Date).ToString('o')
    }

    return [pscustomobject]$result
}

function Invoke-AgpmDeploymentQueue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Config
    )

    $paths = Initialize-AgpmSchedulerData -Config $Config
    $mutex = [Threading.Mutex]::new($false, 'Global\AGPMSchedulerQueueRunner')
    $hasMutex = $false
    try {
        $hasMutex = $mutex.WaitOne(0)
        if (-not $hasMutex) {
            Write-AgpmEvent -Paths $paths -Event 'RunnerSkippedMutex' `
                -Message 'Another queue runner is already active.'
            Write-Verbose 'Another queue runner is already active.'
            return
        }

        Write-AgpmEvent -Paths $paths -Event 'RunnerStarted' -Details ([ordered]@{
            ConfigPath = [string]$Config.ConfigPath
        })
        $now = Get-Date
        $dueJobs = @(Get-AgpmDeploymentJob -Config $Config -Status Pending |
            Where-Object { [datetime]$_.ScheduledAt -le $now } |
            Sort-Object { [datetime]$_.ScheduledAt })
        Write-AgpmEvent -Paths $paths -Event 'QueueScanned' -Details ([ordered]@{
            DueJobCount = $dueJobs.Count
        })

        foreach ($pendingJob in $dueJobs) {
            $runningPath = Join-Path $paths.Running "$($pendingJob.JobId).json"
            try {
                Move-Item -LiteralPath $pendingJob.QueuePath -Destination $runningPath -ErrorAction Stop
            } catch {
                Write-AgpmEvent -Paths $paths -Event 'JobClaimFailed' -Job $pendingJob `
                    -Message $_.Exception.Message
                continue
            }

            $job = $null
            $results = [System.Collections.ArrayList]::new()
            try {
                $job = Get-Content -LiteralPath $runningPath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -ErrorAction Stop
                Write-AgpmEvent -Paths $paths -Event 'JobClaimed' -Job $job -Details ([ordered]@{
                    RunningPath = $runningPath
                })
                $job.Status = 'Running'
                Add-Member -InputObject $job -NotePropertyName StartedAt `
                    -NotePropertyValue (Get-Date).ToString('o') -Force
                Write-AgpmJsonAtomic -Value $job -Path $runningPath
                Write-AgpmEvent -Paths $paths -Event 'JobStarted' -Job $job -Details ([ordered]@{
                    GpoCount = @($job.Gpos).Count
                    WhatIf = [bool]$job.WhatIf
                })

                foreach ($item in $job.Gpos) {
                    Write-AgpmEvent -Paths $paths -Event 'GpoProcessingStarted' -Job $job `
                        -Details ([ordered]@{
                            Domain = [string]$item.Domain
                            Name = [string]$item.Name
                            GpoId = [string]$item.GpoId
                        })
                    $result = Invoke-AgpmGpoDeployment -Config $Config -Item $item -Job $job
                    [void]$results.Add($result)
                    Write-AgpmEvent -Paths $paths -Event 'GpoProcessingCompleted' -Job $job `
                        -Message ([string]$result.Message) -Details $result

                    if ($result.Status -eq 'Failed' -and -not [bool]$Config.Runner.ContinueOnError) {
                        break
                    }
                    if ([int]$Config.Runner.DelayBetweenGposSeconds -gt 0) {
                        Start-Sleep -Seconds ([int]$Config.Runner.DelayBetweenGposSeconds)
                    }
                }

                Write-AgpmEvent -Paths $paths -Event 'JobFinalizationStarted' -Job $job
                $job.Results = @($results)
                Add-Member -InputObject $job -NotePropertyName CompletedAt `
                    -NotePropertyValue (Get-Date).ToString('o') -Force
                $failureCount = @($results | Where-Object Status -eq 'Failed').Count
                $jobWhatIf = if ($null -ne $job.PSObject.Properties['WhatIf']) {
                    [bool]$job.WhatIf
                } else {
                    [bool]$Config.Runner.WhatIf
                }
                $job.Status = if ($failureCount -eq 0) {
                    if ($jobWhatIf) { 'WhatIfCompleted' } else { 'Completed' }
                } elseif ($failureCount -eq $results.Count) {
                    'Failed'
                } else {
                    'CompletedWithErrors'
                }

                $destinationFolder = if ($failureCount -eq 0) {
                    $paths.Completed
                } else {
                    $paths.Failed
                }
                $destinationPath = Join-Path $destinationFolder "$($job.JobId).json"
                Write-AgpmJsonAtomic -Value $job -Path $destinationPath
                Remove-Item -LiteralPath $runningPath -Force -ErrorAction Stop
                Write-AgpmEvent -Paths $paths -Event 'JobFinalized' -Job $job -Details ([ordered]@{
                    Status = [string]$job.Status
                    DestinationPath = $destinationPath
                    ResultCount = @($results).Count
                    FailureCount = $failureCount
                })
            } catch {
                $processingError = $_
                $auditJob = if ($null -ne $job) { $job } else { $pendingJob }
                Write-AgpmEvent -Paths $paths -Event 'JobProcessingFailed' -Job $auditJob `
                    -Message $processingError.Exception.Message -Details ([ordered]@{
                        ScriptStackTrace = $processingError.ScriptStackTrace
                        RunningPath = $runningPath
                    })

                if ($null -ne $job -and (Test-Path -LiteralPath $runningPath)) {
                    $job.Results = @($results)
                    $job.Status = 'ProcessingFailed'
                    Add-Member -InputObject $job -NotePropertyName CompletedAt `
                        -NotePropertyValue (Get-Date).ToString('o') -Force
                    Add-Member -InputObject $job -NotePropertyName ProcessingError `
                        -NotePropertyValue $processingError.Exception.Message -Force
                    $failedPath = Join-Path $paths.Failed "$($job.JobId).json"
                    try {
                        Write-AgpmJsonAtomic -Value $job -Path $failedPath
                        Remove-Item -LiteralPath $runningPath -Force -ErrorAction Stop
                        Write-AgpmEvent -Paths $paths -Event 'FailedJobArchived' -Job $job `
                            -Details ([ordered]@{ DestinationPath = $failedPath })
                    } catch {
                        Write-AgpmEvent -Paths $paths -Event 'FailedJobArchiveFailed' -Job $job `
                            -Message $_.Exception.Message
                    }
                }
            }

            if ($null -ne $job) {
                try {
                    Write-AgpmEvent -Paths $paths -Event 'EmailSendStarted' -Job $job
                    $emailResult = Send-AgpmJobEmail -Config $Config -Job $job
                    Write-AgpmEvent -Paths $paths -Event $emailResult.Status -Job $job `
                        -Details ([ordered]@{
                            Recipients = @($emailResult.Recipients)
                            SmtpServer = [string]$Config.Email.SmtpServer
                            Port = [int]$Config.Email.Port
                            UseSsl = [bool]$Config.Email.UseSsl
                        })
                } catch {
                    Write-AgpmEvent -Paths $paths -Event 'EmailFailed' -Job $job `
                        -Message $_.Exception.Message -Details ([ordered]@{
                            ScriptStackTrace = $_.ScriptStackTrace
                            SmtpServer = [string]$Config.Email.SmtpServer
                            Port = [int]$Config.Email.Port
                            UseSsl = [bool]$Config.Email.UseSsl
                        })
                }
            }
        }
        Write-AgpmEvent -Paths $paths -Event 'RunnerCompleted' -Details ([ordered]@{
            ProcessedJobCount = $dueJobs.Count
        })
    } catch {
        Write-AgpmEvent -Paths $paths -Event 'RunnerFailed' -Message $_.Exception.Message `
            -Details ([ordered]@{ ScriptStackTrace = $_.ScriptStackTrace })
        throw
    } finally {
        if ($hasMutex) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Get-AgpmSchedulerConfig',
    'Initialize-AgpmSchedulerData',
    'Get-AgpmControlledGpo',
    'New-AgpmDeploymentJob',
    'Get-AgpmDeploymentJob',
    'Stop-AgpmDeploymentJob',
    'Invoke-AgpmDeploymentQueue'
)
