<#
.SYNOPSIS
    Monthly VMware template patching.
.DESCRIPTION
    For each template listed in the templates CSV:
      1. Clones <name> to <name>_patching and waits for the clone task
      2. Converts the clone to a VM, powers it on, records an Appx baseline,
         copies this month's patches in
      3. Registers the LoopingPatch scheduled task and reboots the guest
      4. Waits for the patch cycle to finish (the guest powers itself off)
      5. Powers on, shows the latest hotfixes, runs the Appx sysprep check
         (see below), pauses for operator review
      6. Shuts down, stamps the notes, and promotes:
           <name>_unpatch  -> removed (last month's rollback)
           <name>          -> <name>_unpatch
           <name>_patching -> <name>

    Every template is tracked independently. A template that fails any step is
    skipped for the rest of the run and is never promoted, so its production
    template and _unpatch rollback copy are left untouched. A summary table is
    printed at the end.

    APPX SYSPREP CHECK
    Sysprep (run by the VMware customization spec) fails when an Appx package
    is installed for a user but not provisioned for all users, or when a
    user's copy is newer than the provisioned one. Patching can cause this,
    e.g. an Edge update registering a package for Administrator. After the
    patch cycle every such package is removed with Remove-AppxPackage
    -AllUsers and the check is repeated. Anything that cannot be removed fails
    the template (it is not promoted, and its _patching VM is left powered on)
    and is written to appx_manual_intervention_<timestamp>.csv in the log
    directory. Framework, resource and system packages are ignored, as are
    packages installed for all users through provisioning.

    RESUMING
    Progress is saved after every step to template_patching_state.json in the
    log directory. To continue after a failure (for example once you have
    removed an Appx package by hand) or after the ISE was closed, set
    Resume = $true and run again. Each unfinished template picks up at the step
    it failed or stopped on; completed steps are skipped and finished templates
    are left alone. Templates are taken from the state file, not the CSV.
    ResumeTemplates limits the resume to specific templates.
    On resume the script also:
      - powers the _patching VM back on if the next step needs the guest
      - starts a template over from the clone if its _patching VM/template no
        longer exists (e.g. you deleted it to start again)
      - finishes a partly done promotion without touching the new rollback copy
    A new run (Resume = $false) archives the old state file first.

    Templates CSV columns:
      templateName      (required) must start with the OS year, e.g. 2022_Std_Core
      DataStoreCluster  (required) datastore cluster to place the clone on
      vCenter           (optional) pin the template to one vCenter when the same
                                   name exists on more than one

    Credentials are stored with Export-Clixml (DPAPI), so they only decrypt for
    the same user on the same machine that created them.

    HOW TO RUN
    Paste into a new (unsaved) PowerShell ISE script pane, edit the CONFIGURATION
    block below, and press F5. Running unsaved pane contents is not subject to
    the script execution policy, so nothing needs to be signed or saved.
    After it finishes, $jobs stays in the session with each template's status:
        $jobs | Where-Object Status -eq 'Failed' | Format-List
#>

# =============================================================================
#  CONFIGURATION
# =============================================================================
# Each setting is "Name = value" - no $ in front of the name. A line such as
# "$VCenters = @(...)" inside this block fails with "A null key is not allowed
# in a hash literal".
$Config = $null   # the ISE keeps variables between runs; never reuse an old config
$Config = @{
    # --- Run options ---------------------------------------------------------
    # $false = new run from the templates CSV.
    # $true  = continue the previous run from its state file (see RESUMING above).
    Resume                = $false

    # With Resume: only these templates, e.g. @('2022_Std_Core'). Empty = every
    # template from the previous run that has not completed.
    ResumeTemplates       = @()

    # Log clone progress percentage while waiting
    ShowTaskProgress      = $false

    # --- vCenter -------------------------------------------------------------
    VCenters              = @('VCENTER-01', 'VCENTER-02', 'VCENTER-03', 'VCENTER-04')
    VCenterCredentialPath = 'C:\temp\credstore\ps.xml'

    # --- Guest OS ------------------------------------------------------------
    # Local administrator on the templates. Prompted for and saved on first run.
    GuestCredentialPath   = 'C:\temp\credstore\template_guest_admin.xml'
    GuestPatchPath        = 'C:\temp'
    LoopingPatchScript    = 'C:\Users\Administrator\Desktop\LoopingPatch.ps1'
    GuestToolsWaitSeconds = 3600

    # --- File share ----------------------------------------------------------
    TemplatesFilePath     = '\\FILE-SERVER-01\f$\Templates\Data\AllTemplates_Exclude_2016_2019.csv'
    LogDirectory          = '\\FILE-SERVER-01\f$\Templates\logs'
    PatchesRootPath       = '\\FILE-SERVER-01\f$\Templates'

    # --- Patch source --------------------------------------------------------
    # Key = OS year (first 4 characters of the template name), value = test server
    # whose ccmcache holds that OS's patches for the month.
    TestServers           = [ordered]@{
        '2025' = 'TEST-SERVER-2025'
        '2022' = 'TEST-SERVER-2022'
        '2019' = 'TEST-SERVER-2019'
        '2016' = 'TEST-SERVER-2016'
    }
    PatchLookbackDays     = 30

    # --- Timeouts ------------------------------------------------------------
    CloneTimeoutMinutes      = 30
    PowerOnTimeoutMinutes    = 15
    PatchCycleTimeoutMinutes = 240
    PatchCyclePollSeconds    = 300
    ShutdownTimeoutMinutes   = 15

    # Clones to a datastore cluster already include Storage DRS placement, so
    # this extra wait is normally unnecessary.
    WaitForStorageDrs        = $false
    StorageDrsTimeoutMinutes = 30

    # --- Behaviour -----------------------------------------------------------
    # Stop after the hotfix report and wait for Enter (or ABORT) before promoting.
    PauseForReview              = $true

    # Remove Appx packages that would break sysprep (installed for a user but
    # not provisioned). $false only reports them and fails the template.
    AppxAutoRemove              = $true

    # $false only unregisters last month's _unpatch template, leaving its disks on
    # the datastore (the original script's behaviour). $true deletes the disks too.
    DeleteOldUnpatchPermanently = $false
}

# Stop here if the block above has a mistake, instead of failing later with
# unrelated-looking errors (e.g. Join-Path "cannot bind argument ... null").
if ($null -eq $Config) {
    throw 'The CONFIGURATION block did not load - see the first red error above. Settings must be written "Name = value" (no $ before the name).'
}
$missing = @('VCenters', 'VCenterCredentialPath', 'GuestCredentialPath', 'TemplatesFilePath', 'LogDirectory', 'PatchesRootPath', 'TestServers' |
    Where-Object { -not $Config[$_] })
if ($missing) { throw "CONFIGURATION is missing a value for: $($missing -join ', ')" }

$RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath      = Join-Path $Config.LogDirectory "template_patching_$RunTimestamp.log"
$StatePath    = Join-Path $Config.LogDirectory 'template_patching_state.json'

# Every recorded step, in run order. A resumed template continues at the first
# one it hasn't completed.
$StepOrder = @(
    'Start clone'
    'Wait for clone'
    'Convert to VM and power on'
    'Wait for power on (patching)'
    'Appx baseline'
    'Copy patches'
    'Register patch task'
    'Restart guest'
    'Wait for patch cycle'
    'Power on for validation'
    'Wait for power on (validation)'
    'Validate patches'
    'Appx sysprep check'
    'Review'
    'Shut down guest'
    'Wait for shutdown'
    'Update notes'
    'Promote'
)

# Steps that run commands inside the guest, so the VM must be powered on
$GuestSteps = @('Appx baseline', 'Copy patches', 'Register patch task', 'Restart guest', 'Validate patches', 'Appx sysprep check')

# =============================================================================
#  TYPES
# =============================================================================
class TemplateJob {
    [string]$Name
    [string]$PatchingName
    [string]$UnpatchName
    [string]$Year
    [string]$DatastoreCluster
    [string]$VCenter            # optional pin from the CSV
    [object]$Server             # VIServer that owns the template
    [object]$CloneTask
    [object]$AppxBefore         # guest Appx state before patching
    [string]$Status = 'Pending' # Pending | Completed | Failed
    [string]$FailedStep
    [string]$Message
    [System.Collections.Generic.List[string]]$CompletedSteps = [System.Collections.Generic.List[string]]::new()

    TemplateJob([string]$name, [string]$datastoreCluster, [string]$vCenter) {
        $this.Name             = $name
        $this.PatchingName     = "${name}_patching"
        $this.UnpatchName      = "${name}_unpatch"
        $this.Year             = if ($name.Length -ge 4) { $name.Substring(0, 4) } else { '' }
        $this.DatastoreCluster = $datastoreCluster
        $this.VCenter          = $vCenter
    }
}

# =============================================================================
#  HELPERS
# =============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')]
        [string]$Level = 'INFO'
    )

    $colors = @{ INFO = 'Cyan'; WARNING = 'Yellow'; ERROR = 'Red'; SUCCESS = 'Green' }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Get-StoredCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    if (Test-Path $Path) {
        return Import-Clixml -Path $Path
    }

    Write-Log "Credential file $Path not found, prompting" -Level WARNING
    $credential = Get-Credential -Message $Prompt
    if (-not $credential) { throw "No credential entered for: $Prompt" }

    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $credential | Export-Clixml -Path $Path
    Write-Log "Credential saved to $Path"
    return $credential
}

function Select-ActiveJob {
    param([AllowEmptyCollection()][TemplateJob[]]$Jobs)
    @($Jobs | Where-Object { $_.Status -ne 'Failed' })
}

function Set-JobFailed {
    param(
        [Parameter(Mandatory = $true)][TemplateJob]$Job,
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $Job.Status     = 'Failed'
    $Job.FailedStep = $Step
    $Job.Message    = $Message
    Write-Log "[$($Job.Name)] $Step failed: $Message" -Level ERROR
}

# Runs $Action once per still-active job that hasn't completed $Step yet. Any
# exception marks that job failed and the remaining jobs carry on. Completed
# steps are recorded and saved so a resumed run skips them. -Transient steps
# (checks that must run every time) are never recorded or skipped.
function Invoke-JobStep {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][TemplateJob[]]$Jobs,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [switch]$Transient
    )

    $ErrorActionPreference = 'Stop'
    $active = @(Select-ActiveJob $Jobs | Where-Object { $Transient -or -not $_.CompletedSteps.Contains($Step) })
    if ($active.Count -eq 0) { return }
    Write-Log "---- $Step ($($active.Count) template(s)) ----"

    foreach ($job in $active) {
        try {
            & $Action $job
            if (-not $Transient -and $job.Status -ne 'Failed') { $job.CompletedSteps.Add($Step) }
        } catch {
            Set-JobFailed -Job $job -Step $Step -Message $_.Exception.Message
        }
    }
    if (-not $Transient) { Save-RunState }
}

# First step in $StepOrder this job hasn't completed, or $null when all are done.
function Get-NextStep {
    param([Parameter(Mandatory = $true)][TemplateJob]$Job)
    $StepOrder | Where-Object { -not $Job.CompletedSteps.Contains($_) } | Select-Object -First 1
}

# Powers on a job's _patching VM if it isn't already. Returns $true if it was started.
function Start-PatchingVM {
    param([Parameter(Mandatory = $true)][TemplateJob]$Job)

    $vm = Get-VM -Name $Job.PatchingName -Server $Job.Server -ErrorAction Stop
    if ($vm.PowerState -eq 'PoweredOn') { return $false }
    Start-VM -VM $vm -Confirm:$false -ErrorAction Stop | Out-Null
    return $true
}

# =============================================================================
#  RUN STATE (resume support)
# =============================================================================

# Writes the run and every job's progress to the state file. Called after each
# step, so an interrupted or failed run can continue with $Config.Resume.
function Save-RunState {
    $state = [pscustomobject]@{
        RunTimestamp      = $RunState.RunTimestamp
        TemplatesFilePath = $RunState.TemplatesFilePath
        PatchRunFolder    = $RunState.PatchRunFolder
        SavedAt           = (Get-Date).ToString('s')
        Jobs              = @($allJobs | ForEach-Object {
            [pscustomobject]@{
                Name             = $_.Name
                DatastoreCluster = $_.DatastoreCluster
                VCenter          = $_.VCenter
                Status           = $_.Status
                FailedStep       = $_.FailedStep
                Message          = $_.Message
                CompletedSteps   = @($_.CompletedSteps)
                AppxBefore       = $_.AppxBefore
            }
        })
    }

    try {
        ConvertTo-Json -InputObject $state -Depth 6 | Set-Content -Path $StatePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Log "Could not save run state to $StatePath : $($_.Exception.Message)" -Level WARNING
    }
}

# Rebuilds TemplateJob objects from the state file.
function Import-RunState {
    param([Parameter(Mandatory = $true)][string]$Path)

    $state = Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    $jobs = foreach ($s in @($state.Jobs)) {
        $job = [TemplateJob]::new($s.Name, $s.DatastoreCluster, $s.VCenter)
        $job.Status     = $s.Status
        $job.FailedStep = $s.FailedStep
        $job.Message    = $s.Message
        foreach ($step in @($s.CompletedSteps | Where-Object { $_ })) { $job.CompletedSteps.Add($step) }
        if ($s.AppxBefore) {
            # ConvertFrom-Json turns one-element arrays into scalars; normalise
            $job.AppxBefore = [pscustomobject]@{
                Installed   = @($s.AppxBefore.Installed   | Where-Object { $_ })
                Provisioned = @($s.AppxBefore.Provisioned | Where-Object { $_ })
                Offenders   = @($s.AppxBefore.Offenders   | Where-Object { $_ })
            }
        }
        $job
    }

    return [pscustomobject]@{
        RunTimestamp      = $state.RunTimestamp
        TemplatesFilePath = $state.TemplatesFilePath
        PatchRunFolder    = $state.PatchRunFolder
        Jobs              = @($jobs)
    }
}

# Returns the connected VIServer that an inventory object (VM, template, ...)
# belongs to, so later calls can be scoped with -Server.
function Get-OwningServer {
    param([Parameter(Mandatory = $true)]$InventoryObject)

    $server = $global:DefaultVIServers |
        Where-Object { $InventoryObject.Uid.StartsWith($_.Uid, [StringComparison]::OrdinalIgnoreCase) } |
        Select-Object -First 1

    if (-not $server) {
        $hostName = ([uri]$InventoryObject.ExtensionData.Client.ServiceUrl).Host
        $server = $global:DefaultVIServers |
            Where-Object { $_.ServiceUri.Host -eq $hostName } |
            Select-Object -First 1
    }

    if (-not $server) { throw "Could not determine which vCenter owns $($InventoryObject.Name)" }
    return $server
}

# =============================================================================
#  vCENTER TASKS
# =============================================================================

# Polls the task object returned by a -RunAsync cmdlet. Its ExtensionData is
# bound to the vCenter that owns the task, so this never queries the other
# vCenters and still works after the task drops out of the recent-tasks list.
# Returns Success | Error | Gone | Timeout.
function Wait-CloneTask {
    param(
        [Parameter(Mandatory = $true)]$Task,
        [Parameter(Mandatory = $true)][string]$TemplateName,
        [int]$TimeoutMinutes = 30,
        [int]$PollSeconds = 15
    )

    $view     = $Task.ExtensionData
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        try {
            $view.UpdateViewData('Info')
        } catch {
            if ($_.Exception.Message -match 'ManagedObjectNotFound|already been deleted|not found') {
                return 'Gone'
            }
            Write-Log "[$TemplateName] Could not refresh clone task, retrying: $($_.Exception.Message)" -Level WARNING
            Start-Sleep -Seconds $PollSeconds
            continue
        }

        switch ($view.Info.State) {
            'success' { return 'Success' }
            'error' {
                Write-Log "[$TemplateName] Clone task error: $($view.Info.Error.LocalizedMessage)" -Level ERROR
                return 'Error'
            }
            default {
                if ($Config.ShowTaskProgress) {
                    Write-Log "[$TemplateName] Clone $($view.Info.Progress)% complete"
                }
                Start-Sleep -Seconds $PollSeconds
            }
        }
    }

    return 'Timeout'
}

function Wait-StorageDrsTask {
    param(
        [Parameter(Mandatory = $true)][string]$EntityName,
        [Parameter(Mandatory = $true)]$Server,
        [int]$TimeoutMinutes = 30,
        [int]$PollSeconds = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        $running = foreach ($t in (Get-Task -Status Running -Server $Server -ErrorAction SilentlyContinue)) {
            try {
                if ($t.Name -like '*Storage DRS*' -and $t.ExtensionData.Info.EntityName -like "*$EntityName*") { $t }
            } catch { }   # task vanished between the list call and the property read
        }

        if (-not $running) { return $true }
        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

# Waits until every active job's _patching VM reaches $PowerState. Jobs whose VM
# disappears are failed immediately; jobs still pending at the timeout are failed
# when -FailOnTimeout is set, otherwise just logged. Recorded like Invoke-JobStep.
function Wait-JobPowerState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][TemplateJob[]]$Jobs,
        [Parameter(Mandatory = $true)][ValidateSet('PoweredOn', 'PoweredOff')][string]$PowerState,
        [Parameter(Mandatory = $true)][string]$Step,
        [int]$TimeoutMinutes = 10,
        [int]$PollSeconds = 30,
        [switch]$FailOnTimeout,
        [switch]$Transient
    )

    $pending = @(Select-ActiveJob $Jobs | Where-Object { $Transient -or -not $_.CompletedSteps.Contains($Step) })
    if ($pending.Count -eq 0) { return }
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "---- $Step ($($pending.Count) template(s), timeout $TimeoutMinutes min) ----"

    $markDone = {
        param($job)
        if (-not $Transient) { $job.CompletedSteps.Add($Step) }
    }

    while ($pending.Count -gt 0) {
        $stillPending = @()
        foreach ($job in $pending) {
            $vm = Get-VM -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue
            if (-not $vm) {
                Set-JobFailed -Job $job -Step $Step -Message "VM $($job.PatchingName) not found"
            } elseif ($vm.PowerState -ne $PowerState) {
                $stillPending += $job
            } else {
                & $markDone $job
            }
        }
        $pending = $stillPending

        if ($pending.Count -eq 0) { break }

        if ((Get-Date) -ge $deadline) {
            foreach ($job in $pending) {
                $msg = "Did not reach $PowerState within $TimeoutMinutes minutes"
                if ($FailOnTimeout) {
                    Set-JobFailed -Job $job -Step $Step -Message $msg
                } else {
                    Write-Log "[$($job.Name)] $msg" -Level WARNING
                    & $markDone $job
                }
            }
            if (-not $Transient) { Save-RunState }
            return
        }

        Write-Log "Waiting for $PowerState : $(($pending | ForEach-Object PatchingName) -join ', ')"
        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $Transient) { Save-RunState }
    Write-Log "All active VMs are $PowerState" -Level SUCCESS
}

# =============================================================================
#  PATCH FILES
# =============================================================================

# Copies recent .cab/.msu files from each test server's ccmcache into
# <PatchesRoot>\Patches<MMMyy>\<year>\Patches and returns the run folder.
function Get-PatchesFromTestServer {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$TestServers,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [int]$LookbackDays = 30
    )

    $runFolder = Join-Path $DestinationRoot ("Patches" + (Get-Date -Format 'MMMyy'))
    $cutoff    = (Get-Date).AddDays(-$LookbackDays)

    foreach ($year in $TestServers.Keys) {
        $server = $TestServers[$year]
        $cache  = "\\$server\c$\Windows\ccmcache"
        Write-Log "Searching $cache for $year patches..."

        try {
            $dirs = @(Get-ChildItem -Path $cache -Directory -ErrorAction Stop |
                      Where-Object { $_.LastWriteTime -gt $cutoff })
            if ($dirs.Count -eq 0) {
                Write-Log "No ccmcache folders newer than $LookbackDays days on $server" -Level WARNING
                continue
            }

            $patches = @(Get-ChildItem -Path $dirs.FullName -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.Extension -in '.cab', '.msu' })
            if ($patches.Count -eq 0) {
                Write-Log "No .cab/.msu files found for $year on $server" -Level WARNING
                continue
            }

            $destination = Join-Path $runFolder "$year\Patches"
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Copy-Item -Path $patches.FullName -Destination $destination -Force -ErrorAction Stop
            Write-Log "Copied $($patches.Count) patch file(s) for $year" -Level SUCCESS
        } catch {
            Write-Log "Error collecting $year patches from $server : $($_.Exception.Message)" -Level ERROR
        }
    }

    return $runFolder
}

# Finds the folder to copy into a guest for a given OS year: this run's folder
# if it has that year, otherwise the newest Patches* folder that does.
$script:PatchSourceCache = @{}
function Resolve-PatchSource {
    param(
        [Parameter(Mandatory = $true)][string]$Year,
        [Parameter(Mandatory = $true)][string]$RunFolder,
        [Parameter(Mandatory = $true)][string]$PatchesRoot
    )

    if ($script:PatchSourceCache.ContainsKey($Year)) { return $script:PatchSourceCache[$Year] }

    $source = Join-Path $RunFolder $Year
    if (-not (Test-Path $source)) {
        $fallback = Get-ChildItem -Path $PatchesRoot -Directory -Filter 'Patches*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Where-Object { Test-Path (Join-Path $_.FullName $Year) } |
            Select-Object -First 1

        if ($fallback) {
            $source = Join-Path $fallback.FullName $Year
            Write-Log "No $Year patches collected this run; falling back to $source" -Level WARNING
        } else {
            $source = $null
        }
    }

    $script:PatchSourceCache[$Year] = $source
    return $source
}

# =============================================================================
#  TEMPLATE / VM OPERATIONS
# =============================================================================
function Start-TemplateClone {
    param([Parameter(Mandatory = $true)][TemplateJob]$Job)

    $template  = Get-Template -Name $Job.Name -Server $Job.Server -ErrorAction Stop
    $folder    = Get-Folder -Id $template.FolderId -Server $Job.Server -ErrorAction Stop
    $dsCluster = Get-DatastoreCluster -Name $Job.DatastoreCluster -Server $Job.Server -ErrorAction Stop

    $Job.CloneTask = New-Template -Template $template -Name $Job.PatchingName -Location $folder `
        -Datastore $dsCluster -Server $Job.Server -RunAsync -ErrorAction Stop
}

function Register-GuestPatchTask {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $scriptText = @'
$action  = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-ExecutionPolicy Bypass -NoProfile -File __SCRIPT__'
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -Action $action -Trigger $trigger -User 'NT AUTHORITY\SYSTEM' -TaskPath 'CustomTasks' -TaskName 'UpdateTask' -Description 'This task starts a looping patch cycle.' -Force | Out-Null
'@.Replace('__SCRIPT__', $Config.LoopingPatchScript)

    $result = Invoke-VMScript -VM $VM -ScriptText $scriptText -ScriptType Powershell `
        -GuestCredential $GuestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -ErrorAction Stop

    if ($result.ExitCode -ne 0) {
        throw "Register-ScheduledTask exited $($result.ExitCode): $($result.ScriptOutput.Trim())"
    }
}

# Replaces a trailing "Updated M/d/yyyy" line in the notes, or appends one.
function Update-TemplateNotes {
    param([Parameter(Mandatory = $true)]$VM)

    $stamp = 'Updated ' + (Get-Date).ToString('M/d/yyyy', [cultureinfo]::InvariantCulture)
    $lines = @()
    if ($VM.Notes) { $lines = @($VM.Notes.TrimEnd() -split "`r?`n") }

    if ($lines.Count -gt 0 -and $lines[-1] -match '^Updated\s') {
        $lines[-1] = $stamp
    } else {
        $lines += $stamp
    }

    Set-VM -VM $VM -Notes ($lines -join "`n") -Confirm:$false -ErrorAction Stop | Out-Null
}

# Converts <name>_patching to a template and rotates names:
#   <name>_unpatch -> removed,  <name> -> <name>_unpatch,  <name>_patching -> <name>
# Safe to rerun after a partial failure: each part checks whether it already happened.
function Publish-PatchedTemplate {
    param([Parameter(Mandatory = $true)][TemplateJob]$Job)

    $server = $Job.Server
    $vm = Get-VM -Name $Job.PatchingName -Server $server -ErrorAction SilentlyContinue

    if ($vm) {
        if ($vm.PowerState -ne 'PoweredOff') {
            Write-Log "[$($Job.Name)] $($Job.PatchingName) did not shut down cleanly; powering off" -Level WARNING
            $vm = Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
        }
        $patched = Set-VM -VM $vm -ToTemplate -Confirm:$false -ErrorAction Stop
    } else {
        # Already converted by an earlier attempt
        $patched = Get-Template -Name $Job.PatchingName -Server $server -ErrorAction SilentlyContinue
        if (-not $patched) { throw "Neither a VM nor a template named $($Job.PatchingName) exists" }
    }

    $current = Get-Template -Name $Job.Name -Server $server -ErrorAction SilentlyContinue
    if ($current) {
        $oldUnpatch = Get-Template -Name $Job.UnpatchName -Server $server -ErrorAction SilentlyContinue
        if ($oldUnpatch) {
            Remove-Template -Template $oldUnpatch -DeletePermanently:$Config.DeleteOldUnpatchPermanently `
                -Confirm:$false -ErrorAction Stop
            Write-Log "[$($Job.Name)] Removed old $($Job.UnpatchName)"
        }
        Set-Template -Template $current -Name $Job.UnpatchName -Confirm:$false -ErrorAction Stop | Out-Null
    } else {
        # An earlier attempt already moved production to _unpatch. Don't touch
        # _unpatch now - it is the rollback copy for this run.
        Write-Log "[$($Job.Name)] $($Job.Name) already renamed to $($Job.UnpatchName) by an earlier attempt" -Level WARNING
    }

    try {
        Set-Template -Template $patched -Name $Job.Name -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        throw ("Production template was renamed to $($Job.UnpatchName) but $($Job.PatchingName) could not be " +
               "renamed to $($Job.Name). Rename it manually. Error: $($_.Exception.Message)")
    }
}

# =============================================================================
#  APPX / SYSPREP SAFETY
# =============================================================================

# Runs inside the guest. Emits one line: APPXJSON:{Installed, Provisioned, Offenders}
#   Installed   - "Name|Version" of every non-framework, non-resource, non-system package
#   Provisioned - "Name|Version" of every provisioned package (highest version per name)
#   Offenders   - packages installed for at least one user that sysprep will reject:
#                 not provisioned at all, or newer than the provisioned version
$AppxStateScript = @'
$ErrorActionPreference = 'Stop'

$provisioned = @{}
foreach ($p in (Get-AppxProvisionedPackage -Online)) {
    $v = [version]$p.Version
    if (-not $provisioned.ContainsKey($p.DisplayName) -or $v -gt $provisioned[$p.DisplayName]) {
        $provisioned[$p.DisplayName] = $v
    }
}

$installed = @()
$offenders = @()
foreach ($pkg in (Get-AppxPackage -AllUsers)) {
    if ($pkg.IsFramework -or $pkg.IsResourcePackage -or "$($pkg.SignatureKind)" -eq 'System') { continue }
    $installed += "$($pkg.Name)|$($pkg.Version)"

    $users = @($pkg.PackageUserInformation |
        Where-Object { "$($_.InstallState)" -eq 'Installed' } |
        ForEach-Object { if ($_.UserSecurityId.Username) { $_.UserSecurityId.Username } else { $_.UserSecurityId.Sid } })
    if ($users.Count -eq 0) { continue }

    $reason = $null
    if (-not $provisioned.ContainsKey($pkg.Name)) {
        $reason = 'Installed for user(s) but not provisioned'
    } elseif ([version]$pkg.Version -gt $provisioned[$pkg.Name]) {
        $reason = "Newer than provisioned version $($provisioned[$pkg.Name])"
    }

    if ($reason) {
        $offenders += [pscustomobject]@{
            Name            = $pkg.Name
            Version         = [string]$pkg.Version
            PackageFullName = $pkg.PackageFullName
            Users           = $users -join ', '
            Reason          = $reason
            NonRemovable    = [bool]$pkg.NonRemovable
        }
    }
}

$state = [pscustomobject]@{
    Installed   = @($installed | Sort-Object -Unique)
    Provisioned = @($provisioned.Keys | Sort-Object | ForEach-Object { "$_|$($provisioned[$_])" })
    Offenders   = @($offenders)
}
'APPXJSON:' + (ConvertTo-Json -InputObject $state -Depth 4 -Compress)
'@

# Runs inside the guest. __PACKAGES__ is replaced with a quoted list of
# PackageFullNames. Emits APPXJSON:[{PackageFullName, Removed, Error}]
$AppxRemoveScript = @'
$results = foreach ($name in @(__PACKAGES__)) {
    try {
        Remove-AppxPackage -Package $name -AllUsers -ErrorAction Stop
        [pscustomobject]@{ PackageFullName = $name; Removed = $true; Error = '' }
    } catch {
        [pscustomobject]@{ PackageFullName = $name; Removed = $false; Error = ($_.Exception.Message -replace '\s+', ' ').Trim() }
    }
}
'APPXJSON:' + (ConvertTo-Json -InputObject @($results) -Depth 3 -Compress)
'@

# Runs a guest script that reports through an APPXJSON: line and returns the parsed object.
function Invoke-GuestJsonScript {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $result = Invoke-VMScript -VM $VM -ScriptText $ScriptText -ScriptType Powershell `
        -GuestCredential $GuestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -ErrorAction Stop

    $line = $result.ScriptOutput -split "`r?`n" | Where-Object { $_.StartsWith('APPXJSON:') } | Select-Object -Last 1
    if (-not $line) {
        throw "Guest script returned no data (exit code $($result.ExitCode)): $($result.ScriptOutput.Trim())"
    }
    return $line.Substring('APPXJSON:'.Length) | ConvertFrom-Json
}

function Get-GuestAppxState {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $state = Invoke-GuestJsonScript -VM $VM -ScriptText $AppxStateScript -GuestCredential $GuestCredential
    # ConvertFrom-Json turns one-element arrays into scalars; normalise
    return [pscustomobject]@{
        Installed   = @($state.Installed   | Where-Object { $_ })
        Provisioned = @($state.Provisioned | Where-Object { $_ })
        Offenders   = @($state.Offenders   | Where-Object { $_ })
    }
}

function Remove-GuestAppxPackage {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential,
        [Parameter(Mandatory = $true)][string[]]$PackageFullName
    )

    $quoted = ($PackageFullName | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
    $scriptText = $AppxRemoveScript.Replace('__PACKAGES__', $quoted)
    return @(Invoke-GuestJsonScript -VM $VM -ScriptText $scriptText -GuestCredential $GuestCredential)
}

# Logs which packages patching added or removed, for tracking down the cause.
function Write-AppxChanges {
    param(
        [Parameter(Mandatory = $true)][string]$TemplateName,
        $Before,
        [Parameter(Mandatory = $true)]$After
    )

    if (-not $Before) {
        Write-Log "[$TemplateName] No Appx baseline was recorded, so changes from patching can't be shown" -Level WARNING
        return
    }

    $sections = @(
        @{ Label = 'Installed';   Old = $Before.Installed;   New = $After.Installed }
        @{ Label = 'Provisioned'; Old = $Before.Provisioned; New = $After.Provisioned }
    )
    $changed = $false
    foreach ($s in $sections) {
        $added   = @($s.New | Where-Object { $_ -notin $s.Old })
        $removed = @($s.Old | Where-Object { $_ -notin $s.New })
        if ($added)   { Write-Log "[$TemplateName] $($s.Label) packages added by patching: $($added -join ', ')";   $changed = $true }
        if ($removed) { Write-Log "[$TemplateName] $($s.Label) packages removed by patching: $($removed -join ', ')"; $changed = $true }
    }
    if (-not $changed) { Write-Log "[$TemplateName] No Appx package changes from patching" }
}

# Post-patch gate. Removes sysprep-breaking packages (if AppxAutoRemove), checks
# again, records anything left in $ManualItems, and throws if anything is left.
function Invoke-AppxSysprepCheck {
    param(
        [Parameter(Mandatory = $true)][TemplateJob]$Job,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$ManualItems
    )

    $vm    = Get-VM -Name $Job.PatchingName -Server $Job.Server -ErrorAction Stop
    $state = Get-GuestAppxState -VM $vm -GuestCredential $GuestCredential
    Write-AppxChanges -TemplateName $Job.Name -Before $Job.AppxBefore -After $state

    $offenders = @($state.Offenders)
    if ($offenders.Count -eq 0) {
        Write-Log "[$($Job.Name)] Appx check passed: no per-user packages that would break sysprep" -Level SUCCESS
        return
    }

    foreach ($o in $offenders) {
        Write-Log "[$($Job.Name)] Sysprep blocker: $($o.Name) $($o.Version) for $($o.Users) - $($o.Reason)" -Level WARNING
    }

    $removalErrors = @{}
    if ($Config.AppxAutoRemove) {
        $results = Remove-GuestAppxPackage -VM $vm -GuestCredential $GuestCredential -PackageFullName $offenders.PackageFullName
        foreach ($r in $results) {
            if ($r.Removed) {
                Write-Log "[$($Job.Name)] Removed $($r.PackageFullName)" -Level SUCCESS
            } else {
                $removalErrors[$r.PackageFullName] = $r.Error
                Write-Log "[$($Job.Name)] Could not remove $($r.PackageFullName): $($r.Error)" -Level ERROR
            }
        }

        # Check again - removal can report success yet leave the package registered
        $offenders = @((Get-GuestAppxState -VM $vm -GuestCredential $GuestCredential).Offenders)
    }

    if ($offenders.Count -eq 0) {
        Write-Log "[$($Job.Name)] Appx check passed after removing blocking packages" -Level SUCCESS
        return
    }

    foreach ($o in $offenders) {
        $removalError = if ($removalErrors.ContainsKey($o.PackageFullName)) { $removalErrors[$o.PackageFullName] }
                        elseif ($Config.AppxAutoRemove) { 'Still registered after Remove-AppxPackage reported success' }
                        else { 'Not attempted (AppxAutoRemove is off)' }
        $ManualItems.Add([pscustomobject]@{
            Template        = $Job.Name
            VM              = $Job.PatchingName
            vCenter         = $Job.Server.Name
            Package         = $o.Name
            Version         = $o.Version
            PackageFullName = $o.PackageFullName
            Users           = $o.Users
            Reason          = $o.Reason
            NonRemovable    = $o.NonRemovable
            RemovalError    = $removalError
        })
    }

    throw ("$($offenders.Count) Appx package(s) would break sysprep and need manual removal: " +
           ($offenders.Name -join ', ') + ". $($Job.PatchingName) left powered on.")
}

# =============================================================================
#  MAIN
# =============================================================================
$jobs             = @()   # templates processed in this run
$allJobs          = @()   # every template in the state file (includes ones not resumed)
$connectedServers = @()
$appxManualItems  = [System.Collections.Generic.List[object]]::new()
$RunState         = @{ RunTimestamp = $RunTimestamp; TemplatesFilePath = $Config.TemplatesFilePath; PatchRunFolder = $null }

New-Item -ItemType Directory -Path $Config.LogDirectory -Force | Out-Null
Start-Transcript -Path $LogPath -Append | Out-Null

try {
    # ---- PowerCLI setup -----------------------------------------------------
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "This session runs in $($ExecutionContext.SessionState.LanguageMode) mode (AppLocker/WDAC policy); the vSphere API calls this script needs are blocked there."
    }

    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Set-PowerCLIConfiguration -Scope Session -DefaultVIServerMode Multiple -Confirm:$false | Out-Null

    $vCenterCredential = Get-StoredCredential -Path $Config.VCenterCredentialPath -Prompt 'Credentials for the vCenter servers'
    $guestCredential   = Get-StoredCredential -Path $Config.GuestCredentialPath   -Prompt 'Local administrator on the templates'

    foreach ($vCenter in $Config.VCenters) {
        try {
            $connectedServers += Connect-VIServer -Server $vCenter -Credential $vCenterCredential -ErrorAction Stop
            Write-Log "Connected to $vCenter" -Level SUCCESS
        } catch {
            Write-Log "Failed to connect to $vCenter : $($_.Exception.Message)" -Level ERROR
        }
    }
    if ($connectedServers.Count -eq 0) { throw 'Could not connect to any vCenter' }

    if ($Config.Resume) {
        # ---- Resume: load the previous run ---------------------------------
        if (-not (Test-Path $StatePath)) { throw "Resume is on but there is no state file at $StatePath" }

        $previous = Import-RunState -Path $StatePath
        $allJobs  = $previous.Jobs
        $RunState.RunTimestamp      = $previous.RunTimestamp
        $RunState.TemplatesFilePath = $previous.TemplatesFilePath
        $RunState.PatchRunFolder    = $previous.PatchRunFolder
        Write-Log "Resuming run $($previous.RunTimestamp) ($($allJobs.Count) template(s) from $($previous.TemplatesFilePath))"

        $unknown = @($Config.ResumeTemplates | Where-Object { $_ -notin $allJobs.Name })
        if ($unknown) { throw "ResumeTemplates not in the previous run: $($unknown -join ', ')" }

        foreach ($job in $allJobs) {
            $selected = $Config.ResumeTemplates.Count -eq 0 -or $job.Name -in $Config.ResumeTemplates
            if ($job.Status -eq 'Completed') {
                Write-Log "[$($job.Name)] Already completed - skipping"
            } elseif (-not $selected) {
                Write-Log "[$($job.Name)] Not in ResumeTemplates - left as is ($($job.Status))"
            } elseif ($job.FailedStep -eq 'Load CSV') {
                Write-Log "[$($job.Name)] Failed CSV validation - fix the CSV and start a new run" -Level WARNING
            } else {
                if ($job.Status -eq 'Failed') {
                    Write-Log "[$($job.Name)] Retrying '$($job.FailedStep)' (failed: $($job.Message))"
                } else {
                    Write-Log "[$($job.Name)] Continuing at '$(Get-NextStep $job)'"
                }
                $job.Status     = 'Pending'
                $job.FailedStep = $null
                $job.Message    = $null
                $jobs += $job
            }
        }
        if ($jobs.Count -eq 0) { throw 'Nothing to resume' }

        $patchRunFolder = $RunState.PatchRunFolder
    } else {
        # ---- New run: load templates from the CSV --------------------------
        if (Test-Path $StatePath) {
            $archive = Join-Path $Config.LogDirectory "template_patching_state_replaced_$RunTimestamp.json"
            Move-Item -Path $StatePath -Destination $archive -Force
            Write-Log "Previous state file archived to $archive (set Resume = `$true to continue a run instead)" -Level WARNING
        }

        if (-not (Test-Path $Config.TemplatesFilePath)) {
            throw "Templates file not found at $($Config.TemplatesFilePath)"
        }

        foreach ($row in (Import-Csv $Config.TemplatesFilePath)) {
            $vCenterPin = if ($row.PSObject.Properties['vCenter']) { $row.vCenter } else { '' }
            $job = [TemplateJob]::new($row.templateName, $row.DataStoreCluster, $vCenterPin)
            $jobs += $job

            if (-not $job.Name) {
                Set-JobFailed -Job $job -Step 'Load CSV' -Message 'Row has no templateName'
            } elseif ($job.Year -notmatch '^\d{4}$') {
                Set-JobFailed -Job $job -Step 'Load CSV' -Message "Template name must start with the OS year (got '$($job.Year)')"
            } elseif (-not $job.DatastoreCluster) {
                Set-JobFailed -Job $job -Step 'Load CSV' -Message 'Row has no DataStoreCluster'
            }
        }
        $allJobs = $jobs
        Write-Log "Loaded $($jobs.Count) template(s) from $($Config.TemplatesFilePath)" -Level SUCCESS

        # ---- Collect patches -----------------------------------------------
        $patchRunFolder = Get-PatchesFromTestServer -TestServers $Config.TestServers `
            -DestinationRoot $Config.PatchesRootPath -LookbackDays $Config.PatchLookbackDays
        $RunState.PatchRunFolder = $patchRunFolder
        Save-RunState
    }

    # ---- Locate templates (every run, including resumes) --------------------
    Invoke-JobStep -Step 'Locate template' -Jobs $jobs -Transient -Action {
        param($job)
        $query = @{ ErrorAction = 'SilentlyContinue' }
        if ($job.VCenter) { $query.Server = $job.VCenter }

        $found = @(Get-Template -Name $job.Name @query)
        if ($found.Count -eq 0 -and $job.CompletedSteps.Contains('Start clone')) {
            # Resuming a partly done promotion: production may already be renamed
            $found = @(Get-Template -Name $job.PatchingName @query) + @(Get-VM -Name $job.PatchingName @query)
        }
        if ($found.Count -eq 0) { throw 'Template not found on any connected vCenter' }
        if ($found.Count -gt 1) { throw "Template exists on $($found.Count) vCenters; add a vCenter column to the CSV" }

        $job.Server = Get-OwningServer $found[0]

        $patching = @(Get-Template -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue) +
                    @(Get-VM       -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue)

        if (-not $job.CompletedSteps.Contains('Start clone')) {
            if ($patching.Count -gt 0) {
                throw "$($job.PatchingName) already exists (left over from a previous run?). Remove or rename it first, or set Resume = `$true."
            }
        } elseif ($patching.Count -eq 0) {
            Write-Log "[$($job.Name)] $($job.PatchingName) no longer exists - starting this template over from the clone" -Level WARNING
            $job.CompletedSteps.Clear()
            $job.AppxBefore = $null
        }
        Write-Log "[$($job.Name)] Found on $($job.Server.Name)"
    }
    Save-RunState

    # ---- Resume: power VMs back on where the next step needs the guest -----
    if ($Config.Resume) {
        $restarted = [System.Collections.Generic.List[object]]::new()
        Invoke-JobStep -Step 'Resume: power on' -Jobs $jobs -Transient -Action {
            param($job)
            $next = Get-NextStep $job
            if ($next -in $GuestSteps -and (Start-PatchingVM -Job $job)) {
                Write-Log "[$($job.Name)] Powered on $($job.PatchingName) for '$next'"
                $restarted.Add($job)
            }
        }
        if ($restarted.Count -gt 0) {
            Wait-JobPowerState -Jobs $restarted.ToArray() -PowerState PoweredOn -Step 'Resume: wait for power on' `
                -TimeoutMinutes $Config.PowerOnTimeoutMinutes -FailOnTimeout -Transient
        }
    }

    # ---- Clone --------------------------------------------------------------
    Invoke-JobStep -Step 'Start clone' -Jobs $jobs -Action {
        param($job)
        Start-TemplateClone -Job $job
        Write-Log "[$($job.Name)] Clone to $($job.PatchingName) started"
    }

    Invoke-JobStep -Step 'Wait for clone' -Jobs $jobs -Action {
        param($job)
        if (-not $job.CloneTask) {
            # Resumed run: the task object from the earlier run is gone
            $exists = Get-Template -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue
            if ($exists) {
                Write-Log "[$($job.Name)] $($job.PatchingName) exists from the earlier run; assuming the clone finished" -Level WARNING
                return
            }
            Write-Log "[$($job.Name)] Clone from the earlier run did not finish; cloning again"
            Start-TemplateClone -Job $job
        }

        $result = Wait-CloneTask -Task $job.CloneTask -TemplateName $job.Name -TimeoutMinutes $Config.CloneTimeoutMinutes

        switch ($result) {
            'Error'   { throw 'Clone task failed (see error above)' }
            'Timeout' { throw "Clone did not finish within $($Config.CloneTimeoutMinutes) minutes" }
            'Gone' {
                # Task was purged before we got to it - confirm the clone exists
                if (-not (Get-Template -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue)) {
                    throw 'Clone task is gone and no _patching template exists'
                }
            }
        }

        if ($Config.WaitForStorageDrs -and
            -not (Wait-StorageDrsTask -EntityName $job.PatchingName -Server $job.Server -TimeoutMinutes $Config.StorageDrsTimeoutMinutes)) {
            throw 'Timed out waiting for Storage DRS task'
        }
        Write-Log "[$($job.Name)] Clone complete" -Level SUCCESS
    }

    # ---- Convert to VM and power on -----------------------------------------
    Invoke-JobStep -Step 'Convert to VM and power on' -Jobs $jobs -Action {
        param($job)
        $template = Get-Template -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue
        if ($template) { Set-Template -Template $template -ToVM -Confirm:$false | Out-Null }
        Start-PatchingVM -Job $job | Out-Null
        Write-Log "[$($job.Name)] $($job.PatchingName) converted and powered on" -Level SUCCESS
    }

    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOn -Step 'Wait for power on (patching)' `
        -TimeoutMinutes $Config.PowerOnTimeoutMinutes -FailOnTimeout

    # ---- Appx baseline ------------------------------------------------------
    # Not fatal: only used to show what patching changed. The real gate runs
    # after patching.
    Invoke-JobStep -Step 'Appx baseline' -Jobs $jobs -Action {
        param($job)
        try {
            $vm = Get-VM -Name $job.PatchingName -Server $job.Server
            $job.AppxBefore = Get-GuestAppxState -VM $vm -GuestCredential $guestCredential
        } catch {
            Write-Log "[$($job.Name)] Could not record Appx baseline: $($_.Exception.Message)" -Level WARNING
            return
        }

        $existing = @($job.AppxBefore.Offenders)
        if ($existing.Count -gt 0) {
            Write-Log ("[$($job.Name)] Template already has $($existing.Count) sysprep-breaking Appx package(s) " +
                       "BEFORE patching: $($existing.Name -join ', '). They will be handled after patching.") -Level WARNING
        } else {
            Write-Log "[$($job.Name)] Appx baseline recorded ($($job.AppxBefore.Installed.Count) installed, $($job.AppxBefore.Provisioned.Count) provisioned)"
        }
    }

    # ---- Copy patches -------------------------------------------------------
    Invoke-JobStep -Step 'Copy patches' -Jobs $jobs -Action {
        param($job)
        $source = Resolve-PatchSource -Year $job.Year -RunFolder $patchRunFolder -PatchesRoot $Config.PatchesRootPath
        if (-not $source) { throw "No patch folder found for $($job.Year)" }

        $vm = Get-VM -Name $job.PatchingName -Server $job.Server
        foreach ($item in (Get-ChildItem -Path $source)) {
            Copy-VMGuestFile -Source $item.FullName -Destination $Config.GuestPatchPath -VM $vm -LocalToGuest `
                -GuestCredential $guestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -Force
        }
        Write-Log "[$($job.Name)] Copied $source to $($Config.GuestPatchPath)" -Level SUCCESS
    }

    # ---- Start patch cycle --------------------------------------------------
    Invoke-JobStep -Step 'Register patch task' -Jobs $jobs -Action {
        param($job)
        $vm = Get-VM -Name $job.PatchingName -Server $job.Server
        Register-GuestPatchTask -VM $vm -GuestCredential $guestCredential
        Write-Log "[$($job.Name)] Patch task registered" -Level SUCCESS
    }

    Invoke-JobStep -Step 'Restart guest' -Jobs $jobs -Action {
        param($job)
        Get-VM -Name $job.PatchingName -Server $job.Server | Restart-VMGuest -Confirm:$false | Out-Null
        Write-Log "[$($job.Name)] Restarted; patch cycle running"
    }

    # LoopingPatch.ps1 powers the guest off when it has nothing left to install
    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOff -Step 'Wait for patch cycle' `
        -TimeoutMinutes $Config.PatchCycleTimeoutMinutes -PollSeconds $Config.PatchCyclePollSeconds -FailOnTimeout

    # ---- Validate -----------------------------------------------------------
    Invoke-JobStep -Step 'Power on for validation' -Jobs $jobs -Action {
        param($job)
        Start-PatchingVM -Job $job | Out-Null
    }

    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOn -Step 'Wait for power on (validation)' `
        -TimeoutMinutes $Config.PowerOnTimeoutMinutes -FailOnTimeout

    Invoke-JobStep -Step 'Validate patches' -Jobs $jobs -Action {
        param($job)
        $vm = Get-VM -Name $job.PatchingName -Server $job.Server
        $hotfixScript = 'Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn | Format-Table -AutoSize | Out-String -Width 200'
        $result = Invoke-VMScript -VM $vm -ScriptText $hotfixScript -ScriptType Powershell `
            -GuestCredential $guestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds
        Write-Log "[$($job.Name)] Most recent hotfixes:"
        Write-Host $result.ScriptOutput.Trim()
    }

    Invoke-JobStep -Step 'Appx sysprep check' -Jobs $jobs -Action {
        param($job)
        Invoke-AppxSysprepCheck -Job $job -GuestCredential $guestCredential -ManualItems $appxManualItems
    }

    # ---- Operator review ----------------------------------------------------
    $toReview = @(Select-ActiveJob $jobs | Where-Object { -not $_.CompletedSteps.Contains('Review') })
    if ($toReview.Count -gt 0) {
        $aborted = $false
        if ($Config.PauseForReview) {
            Write-Log "Ready to promote: $(($toReview | ForEach-Object Name) -join ', ')"
            $answer = Read-Host 'Review the hotfix and Appx output above. Press Enter to promote the patched templates, or type ABORT to stop'
            $aborted = $answer -eq 'ABORT'
        }
        foreach ($job in $toReview) {
            if ($aborted) {
                Set-JobFailed -Job $job -Step 'Review' -Message "Aborted by operator; $($job.PatchingName) left powered on"
            } else {
                $job.CompletedSteps.Add('Review')
            }
        }
        Save-RunState
    }

    # ---- Shut down ----------------------------------------------------------
    Invoke-JobStep -Step 'Shut down guest' -Jobs $jobs -Action {
        param($job)
        $vm = Get-VM -Name $job.PatchingName -Server $job.Server
        if ($vm.PowerState -eq 'PoweredOn') { Stop-VMGuest -VM $vm -Confirm:$false | Out-Null }
    }

    # Not fatal - Publish-PatchedTemplate hard powers off anything still running
    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOff -Step 'Wait for shutdown' `
        -TimeoutMinutes $Config.ShutdownTimeoutMinutes

    # ---- Promote ------------------------------------------------------------
    Invoke-JobStep -Step 'Update notes' -Jobs $jobs -Action {
        param($job)
        Update-TemplateNotes -VM (Get-VM -Name $job.PatchingName -Server $job.Server)
    }

    Invoke-JobStep -Step 'Promote' -Jobs $jobs -Action {
        param($job)
        Publish-PatchedTemplate -Job $job
        $job.Status = 'Completed'
        Write-Log "[$($job.Name)] Patched template promoted" -Level SUCCESS
    }

} catch {
    # No 'exit' anywhere - in the ISE that would close the whole editor
    Write-Log "Fatal error: $($_.Exception.Message)" -Level ERROR
} finally {
    if ($jobs.Count -gt 0) {
        Save-RunState

        Write-Log '==== Summary ===='
        $jobs | Sort-Object Status, Name |
            Format-Table Name, Status, FailedStep, Message -AutoSize -Wrap |
            Out-String -Width 250 | Write-Host

        $failed = @($jobs | Where-Object { $_.Status -ne 'Completed' })
        if ($failed.Count -gt 0) {
            Write-Log ("$($failed.Count) template(s) were not promoted. Their production and _unpatch templates are unchanged. " +
                       "Fix the cause and set Resume = `$true to continue them, or delete their _patching VMs/templates before a new run.") -Level WARNING
        }
    }

    if ($appxManualItems.Count -gt 0) {
        $appxCsv = Join-Path $Config.LogDirectory "appx_manual_intervention_$RunTimestamp.csv"
        Write-Log '==== Appx packages needing manual intervention ====' -Level ERROR
        $appxManualItems |
            Format-Table Template, Package, Version, Users, NonRemovable, RemovalError -AutoSize -Wrap |
            Out-String -Width 250 | Write-Host
        try {
            $appxManualItems | Export-Csv -Path $appxCsv -NoTypeInformation -ErrorAction Stop
            Write-Log "Written to $appxCsv" -Level WARNING
        } catch {
            Write-Log "Could not write $appxCsv : $($_.Exception.Message)" -Level ERROR
        }
    }

    foreach ($server in $connectedServers) {
        try {
            Disconnect-VIServer -Server $server -Confirm:$false -ErrorAction Stop
        } catch {
            Write-Log "Error disconnecting from $($server.Name) : $($_.Exception.Message)" -Level WARNING
        }
    }

    Stop-Transcript | Out-Null
}
