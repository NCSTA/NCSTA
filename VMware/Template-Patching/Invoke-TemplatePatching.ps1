<#
.SYNOPSIS
    Monthly VMware template patching.
.DESCRIPTION
    For each template listed in the templates CSV:
      1. Clones <name> to <name>_patching and waits for the clone task
      2. Converts the clone to a VM, powers it on, records an Appx baseline,
         copies this month's patches and the guest patch-cycle script in
      3. Registers the patch-cycle scheduled task and reboots the guest
      4. Waits for the patch cycle to finish (the guest powers itself off)
      5. Powers on, checks the patch-cycle status, shows the latest hotfixes,
         runs the Appx sysprep check (see below), pauses for operator review
      6. Seals the guest (SCCM client cleanup) and shuts it down, stamps the
         notes, and promotes:
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

    GUEST PATCH CYCLE
    The script that runs inside the guest is embedded below ($GuestPatchCycleScript)
    and copied into each VM on every run, so nothing needs to live on the
    templates. It runs at each boot as SYSTEM and:
      - installs only .cab/.msu files, smallest first, and reboots only when
        a package needs it
      - skips packages that are not applicable, and gives up on a package
        after GuestPatchMaxAttempts failures (moving it to a Failed folder)
        instead of rebooting forever
      - writes progress to <GuestWorkPath>\status.json and patchcycle.log
      - always ends with a forced shutdown, whether it succeeded or not
    After the patch cycle, the status file is checked. A failed package or a
    cycle that did not finish fails the template with the error.

    SEAL
    The SCCM client cleanup (stop CcmExec, remove SMSCFG.INI and the SMS
    certificates) runs as the last action before the final shutdown, so the VM
    is never booted afterwards. A cleared client that boots again would create
    a new client identity and bake it into the template.

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
    # Patches are copied to <GuestPatchPath>\Patches
    GuestPatchPath        = 'C:\temp'
    # Patch-cycle script, its log and status file
    GuestWorkPath         = 'C:\temp\PatchCycle'
    GuestPatchTaskName    = 'TemplatePatchCycle'
    # A package that fails this many times is skipped and reported
    GuestPatchMaxAttempts = 2
    GuestToolsWaitSeconds = 3600

    # Scripts left on the templates by the old process. They are no longer used.
    # Set RemoveLegacyGuestScripts = $true once a run with the new patch cycle
    # has succeeded, and the seal step deletes them from each template.
    RemoveLegacyGuestScripts = $false
    LegacyGuestScripts    = @(
        'C:\Users\Administrator\Desktop\logoff.ps1'
        'C:\Users\Administrator\Desktop\LoopingPatch.ps1'
        'C:\Users\Administrator\Desktop\TriggerLoopingPatch.ps1'
    )

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
$missing = @('VCenters', 'VCenterCredentialPath', 'GuestCredentialPath', 'GuestPatchPath', 'GuestWorkPath', 'GuestPatchTaskName',
              'GuestPatchMaxAttempts', 'TemplatesFilePath', 'LogDirectory', 'PatchesRootPath', 'TestServers' |
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
    'Check patch status'
    'Validate patches'
    'Appx sysprep check'
    'Review'
    'Seal and shut down'
    'Wait for shutdown'
    'Update notes'
    'Promote'
)

# Steps that run commands inside the guest, so the VM must be powered on
$GuestSteps = @('Appx baseline', 'Copy patches', 'Register patch task', 'Restart guest', 'Check patch status',
                'Validate patches', 'Appx sysprep check', 'Seal and shut down')

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

# =============================================================================
#  GUEST PATCH CYCLE
# =============================================================================

# Copied into every VM as <GuestWorkPath>\Invoke-GuestPatchCycle.ps1 and run at
# each boot as SYSTEM by the patch-cycle scheduled task. Replaces the old
# LoopingPatch.ps1 / logoff.ps1 / TriggerLoopingPatch.ps1 on the templates.
$GuestPatchCycleScript = @'
# Template patch cycle. Runs at every boot as SYSTEM from a scheduled task.
# Copied in by Invoke-TemplatePatching.ps1 on each run - do not edit on a template.
param(
    [string]$PatchPath           = 'C:\temp\Patches',
    [string]$WorkPath            = 'C:\temp\PatchCycle',
    [string]$TaskName            = 'TemplatePatchCycle',
    [int]$MaxAttempts            = 2,
    [int]$MaxBoots               = 25,
    [int]$StartupDelaySeconds    = 60
)

$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $WorkPath 'status.json'
$logPath    = Join-Path $WorkPath 'patchcycle.log'
$failedPath = Join-Path $WorkPath 'Failed'
New-Item -ItemType Directory -Path $WorkPath, $failedPath -Force | Out-Null

function Write-CycleLog([string]$Message) {
    Add-Content -Path $logPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
}

function Save-Status($Status) {
    $Status.UpdatedAt = (Get-Date).ToString('s')
    ConvertTo-Json -InputObject $Status -Depth 5 | Set-Content -Path $statusPath -Encoding UTF8
}

function Test-RebootPending {
    Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
}

# Ends the cycle: records the result, removes the task and the patches, and
# always powers the VM off so the orchestrator never waits on a stuck guest.
function Complete-Cycle($Status, [string]$State, [string]$Message) {
    $Status.State   = $State
    $Status.Message = $Message
    Write-CycleLog "Patch cycle $State. $Message"
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch {
        Write-CycleLog "Could not remove scheduled task $TaskName : $($_.Exception.Message)"
    }
    Remove-Item -Path $PatchPath -Recurse -Force -ErrorAction SilentlyContinue
    Save-Status $Status
    & shutdown.exe /s /t 15 /f /d p:0:0 /c 'Template patch cycle finished'
    exit
}

# ---- Load progress from earlier boots ------------------------------------------
$status = $null
if (Test-Path $statusPath) {
    $saved = Get-Content -Path $statusPath -Raw | ConvertFrom-Json
    $attempts = @{}
    if ($saved.Attempts) { foreach ($p in $saved.Attempts.PSObject.Properties) { $attempts[$p.Name] = [int]$p.Value } }
    $status = @{
        State         = $saved.State
        Boot          = [int]$saved.Boot
        StartedAt     = $saved.StartedAt
        Installed     = @($saved.Installed     | Where-Object { $_ })
        NotApplicable = @($saved.NotApplicable | Where-Object { $_ })
        Failed        = @($saved.Failed        | Where-Object { $_ })
        Attempts      = $attempts
        Message       = $saved.Message
        UpdatedAt     = $saved.UpdatedAt
    }
}
if (-not $status) {
    $status = @{
        State = 'Running'; Boot = 0; StartedAt = (Get-Date).ToString('s')
        Installed = @(); NotApplicable = @(); Failed = @(); Attempts = @{}; Message = ''; UpdatedAt = ''
    }
}

try {
    $status.Boot++
    $status.State = 'Running'
    Write-CycleLog "Boot $($status.Boot): patch cycle starting"
    Save-Status $status

    if ($status.Boot -gt $MaxBoots) {
        Complete-Cycle $status 'Failed' "Stopped after $MaxBoots boots without finishing"
    }

    # Give the servicing stack time to finish its own startup work
    Start-Sleep -Seconds $StartupDelaySeconds

    # Only .cab/.msu files count; anything else in the folder is ignored
    $packages = @(Get-ChildItem -Path $PatchPath -File -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -in '.cab', '.msu' } |
                  Sort-Object Length)
    Write-CycleLog "$($packages.Count) package(s) left to install"

    $restartNeeded     = $false
    $retryLater        = $false
    $installedThisBoot = $false
    foreach ($pkg in $packages) {
        $name = $pkg.Name
        Write-CycleLog ('Installing {0} ({1:N0} MB)' -f $name, ($pkg.Length / 1MB))
        try {
            $result = Add-WindowsPackage -Online -PackagePath $pkg.FullName -NoRestart -ErrorAction Stop
            $needsRestart = [bool]$result.RestartNeeded
            $status.Installed += [pscustomobject]@{ File = $name; RestartNeeded = $needsRestart; At = (Get-Date).ToString('s') }
            Remove-Item -Path $pkg.FullName -Force
            $installedThisBoot = $true
            Write-CycleLog "Installed $name (restart needed: $needsRestart)"
            if ($needsRestart) { $restartNeeded = $true }
        } catch {
            $message = ($_.Exception.Message -replace '\s+', ' ').Trim()
            if ($message -match '0x800f081e') {
                # CBS_E_NOT_APPLICABLE - superseded or not for this OS; not an error
                $status.NotApplicable += $name
                Remove-Item -Path $pkg.FullName -Force
                Write-CycleLog "Not applicable, skipped: $name"
            } else {
                $count = [int]$status.Attempts[$name] + 1
                $status.Attempts[$name] = $count
                Write-CycleLog "Failed $name (attempt $count of $MaxAttempts): $message"
                if ($count -ge $MaxAttempts) {
                    $status.Failed += [pscustomobject]@{ File = $name; Attempts = $count; Error = $message }
                    Move-Item -Path $pkg.FullName -Destination $failedPath -Force
                } else {
                    $retryLater = $true
                }
            }
        }
        Save-Status $status

        # Install the rest after the restart this package asked for
        if ($restartNeeded) { break }
    }

    # Windows' own pending-reboot flag only counts on a boot that installed
    # something; a flag that is stuck would otherwise reboot until MaxBoots
    $pendingFromInstall = $installedThisBoot -and (Test-RebootPending)
    if ($restartNeeded -or $retryLater -or $pendingFromInstall) {
        Write-CycleLog 'Restarting to continue the patch cycle'
        Save-Status $status
        Restart-Computer -Force
        exit
    }

    if ($status.Failed.Count -gt 0) {
        Complete-Cycle $status 'Failed' ("$($status.Failed.Count) package(s) failed: " + (($status.Failed | ForEach-Object { $_.File }) -join ', '))
    }
    Complete-Cycle $status 'Completed' "$($status.Installed.Count) installed, $($status.NotApplicable.Count) not applicable"
} catch {
    Complete-Cycle $status 'Failed' "Unexpected error: $($_.Exception.Message)"
}
'@

# Paths are passed to guest scripts and a scheduled task unquoted
foreach ($key in 'GuestPatchPath', 'GuestWorkPath') {
    if ($Config[$key] -match '\s') { throw "CONFIGURATION $key must not contain spaces: $($Config[$key])" }
}
$GuestPatchFolder = Join-Path $Config.GuestPatchPath 'Patches'
$GuestCycleFile   = Join-Path $Config.GuestWorkPath 'Invoke-GuestPatchCycle.ps1'

# Turns a list of strings into a PowerShell array literal for a guest script.
function ConvertTo-GuestLiteral {
    param([AllowEmptyCollection()][string[]]$Values)
    '@(' + (($Values | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')'
}

# Clears leftovers from an earlier attempt and copies the patch-cycle script in.
function Initialize-GuestPatchCycle {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $prepare = @'
$ErrorActionPreference = 'Stop'
Remove-Item -Path '__WORK__', '__PATCHES__' -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path '__WORK__' -Force | Out-Null
'GUESTJSON:' + (ConvertTo-Json -InputObject @{ Ready = $true } -Compress)
'@.Replace('__WORK__', $Config.GuestWorkPath).Replace('__PATCHES__', $GuestPatchFolder)
    Invoke-GuestJsonScript -VM $VM -ScriptText $prepare -GuestCredential $GuestCredential | Out-Null

    $local = Join-Path $env:TEMP 'Invoke-GuestPatchCycle.ps1'
    Set-Content -Path $local -Value $GuestPatchCycleScript -Encoding UTF8
    Copy-VMGuestFile -Source $local -Destination $GuestCycleFile -VM $VM -LocalToGuest `
        -GuestCredential $GuestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -Force -ErrorAction Stop
}

function Register-GuestPatchTask {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $scriptText = @'
$ErrorActionPreference = 'Stop'
# The old process used a task called UpdateTask; make sure it can't run too
Get-ScheduledTask -TaskName 'UpdateTask' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
$argument  = '-ExecutionPolicy Bypass -NoProfile -File __SCRIPT__ -PatchPath __PATCHES__ -WorkPath __WORK__ -TaskName __TASK__ -MaxAttempts __ATTEMPTS__'
$action    = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument $argument
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName '__TASK__' -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Template patch cycle (Invoke-TemplatePatching.ps1)' -Force | Out-Null
'GUESTJSON:' + (ConvertTo-Json -InputObject @{ Registered = $true } -Compress)
'@.Replace('__SCRIPT__', $GuestCycleFile).Replace('__PATCHES__', $GuestPatchFolder).Replace('__WORK__', $Config.GuestWorkPath).
   Replace('__TASK__', $Config.GuestPatchTaskName).Replace('__ATTEMPTS__', [string]$Config.GuestPatchMaxAttempts)

    Invoke-GuestJsonScript -VM $VM -ScriptText $scriptText -GuestCredential $GuestCredential | Out-Null
}

# Reads status.json written by the patch cycle, plus the end of its log.
# State is Completed, Failed, Running (did not finish) or Missing (never ran).
function Get-GuestPatchStatus {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $scriptText = @'
$statusPath = Join-Path '__WORK__' 'status.json'
$logPath    = Join-Path '__WORK__' 'patchcycle.log'
if (Test-Path $statusPath) {
    $status = Get-Content -Path $statusPath -Raw | ConvertFrom-Json
} else {
    $status = [pscustomobject]@{ State = 'Missing' }
}
$tail = if (Test-Path $logPath) { @(Get-Content -Path $logPath -Tail 15) } else { @() }
$status | Add-Member -NotePropertyName LogTail -NotePropertyValue $tail -Force
'GUESTJSON:' + (ConvertTo-Json -InputObject $status -Depth 5 -Compress)
'@.Replace('__WORK__', $Config.GuestWorkPath)

    return Invoke-GuestJsonScript -VM $VM -ScriptText $scriptText -GuestCredential $GuestCredential
}

# Last action before the final shutdown: resets the SCCM client identity
# (stop CcmExec, remove SMSCFG.INI and the SMS certificates), removes the patch
# cycle files and, if enabled, the legacy template scripts, then shuts down.
# Does not shut down if any of the cleanup could not be confirmed.
function Invoke-GuestSeal {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $legacy = if ($Config.RemoveLegacyGuestScripts) { @($Config.LegacyGuestScripts) } else { @() }

    $scriptText = @'
$ErrorActionPreference = 'Stop'
$result = [ordered]@{ CcmExec = 'NotInstalled'; SmsCertsRemoved = 0; LegacyRemoved = @(); Problems = @(); ShutdownScheduled = $false }

$service = Get-Service -Name CcmExec -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name CcmExec -Force
        $service.WaitForStatus('Stopped', [TimeSpan]::FromMinutes(2))
    }
    $result.CcmExec = 'Stopped'
}

$smsCfg = 'C:\Windows\SMSCFG.INI'
if (Test-Path $smsCfg) { Remove-Item -Path $smsCfg -Force }
if (Test-Path $smsCfg) { $result.Problems += 'SMSCFG.INI is still present' }

if (Test-Path 'Cert:\LocalMachine\SMS') {
    $certs = @(Get-ChildItem -Path 'Cert:\LocalMachine\SMS')
    $certs | Remove-Item -Force
    $result.SmsCertsRemoved = $certs.Count
    if (@(Get-ChildItem -Path 'Cert:\LocalMachine\SMS').Count -gt 0) { $result.Problems += 'SMS certificates are still present' }
}

foreach ($path in __LEGACY__) {
    if (Test-Path $path) { Remove-Item -Path $path -Force; $result.LegacyRemoved += $path }
}

Get-ScheduledTask -TaskName '__TASK__' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
Remove-Item -Path '__WORK__', '__PATCHES__' -Recurse -Force -ErrorAction SilentlyContinue

if ($result.Problems.Count -eq 0) {
    & shutdown.exe /s /t 20 /f /d p:0:0 /c 'Template sealed' | Out-Null
    $result.ShutdownScheduled = $true
}
'GUESTJSON:' + (ConvertTo-Json -InputObject ([pscustomobject]$result) -Depth 3 -Compress)
'@.Replace('__LEGACY__', (ConvertTo-GuestLiteral $legacy)).Replace('__TASK__', $Config.GuestPatchTaskName).
   Replace('__WORK__', $Config.GuestWorkPath).Replace('__PATCHES__', $GuestPatchFolder)

    return Invoke-GuestJsonScript -VM $VM -ScriptText $scriptText -GuestCredential $GuestCredential
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

# Runs inside the guest. Emits one line: GUESTJSON:{Installed, Provisioned, Offenders}
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
'GUESTJSON:' + (ConvertTo-Json -InputObject $state -Depth 4 -Compress)
'@

# Runs inside the guest. __PACKAGES__ is replaced with a quoted list of
# PackageFullNames. Emits GUESTJSON:[{PackageFullName, Removed, Error}]
$AppxRemoveScript = @'
$results = foreach ($name in @(__PACKAGES__)) {
    try {
        Remove-AppxPackage -Package $name -AllUsers -ErrorAction Stop
        [pscustomobject]@{ PackageFullName = $name; Removed = $true; Error = '' }
    } catch {
        [pscustomobject]@{ PackageFullName = $name; Removed = $false; Error = ($_.Exception.Message -replace '\s+', ' ').Trim() }
    }
}
'GUESTJSON:' + (ConvertTo-Json -InputObject @($results) -Depth 3 -Compress)
'@

# Runs a guest script that reports through an GUESTJSON: line and returns the parsed object.
function Invoke-GuestJsonScript {
    param(
        [Parameter(Mandatory = $true)]$VM,
        [Parameter(Mandatory = $true)][string]$ScriptText,
        [Parameter(Mandatory = $true)][pscredential]$GuestCredential
    )

    $result = Invoke-VMScript -VM $VM -ScriptText $ScriptText -ScriptType Powershell `
        -GuestCredential $GuestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -ErrorAction Stop

    $line = $result.ScriptOutput -split "`r?`n" | Where-Object { $_.StartsWith('GUESTJSON:') } | Select-Object -Last 1
    if (-not $line) {
        throw "Guest script returned no data (exit code $($result.ExitCode)): $($result.ScriptOutput.Trim())"
    }
    return $line.Substring('GUESTJSON:'.Length) | ConvertFrom-Json
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
        Initialize-GuestPatchCycle -VM $vm -GuestCredential $guestCredential
        foreach ($item in (Get-ChildItem -Path $source)) {
            Copy-VMGuestFile -Source $item.FullName -Destination $Config.GuestPatchPath -VM $vm -LocalToGuest `
                -GuestCredential $guestCredential -ToolsWaitSecs $Config.GuestToolsWaitSeconds -Force
        }
        Write-Log "[$($job.Name)] Copied $source and the patch-cycle script into the guest" -Level SUCCESS
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

    # The patch-cycle script always powers the guest off when it finishes
    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOff -Step 'Wait for patch cycle' `
        -TimeoutMinutes $Config.PatchCycleTimeoutMinutes -PollSeconds $Config.PatchCyclePollSeconds -FailOnTimeout

    # ---- Validate -----------------------------------------------------------
    Invoke-JobStep -Step 'Power on for validation' -Jobs $jobs -Action {
        param($job)
        Start-PatchingVM -Job $job | Out-Null
    }

    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOn -Step 'Wait for power on (validation)' `
        -TimeoutMinutes $Config.PowerOnTimeoutMinutes -FailOnTimeout

    Invoke-JobStep -Step 'Check patch status' -Jobs $jobs -Action {
        param($job)
        $vm     = Get-VM -Name $job.PatchingName -Server $job.Server
        $status = Get-GuestPatchStatus -VM $vm -GuestCredential $guestCredential

        foreach ($i in @($status.Installed | Where-Object { $_ })) { Write-Log "[$($job.Name)] Installed $($i.File)" }
        foreach ($n in @($status.NotApplicable | Where-Object { $_ })) { Write-Log "[$($job.Name)] Not applicable: $n" }
        foreach ($f in @($status.Failed | Where-Object { $_ })) {
            Write-Log "[$($job.Name)] FAILED $($f.File) after $($f.Attempts) attempt(s): $($f.Error)" -Level ERROR
        }

        switch ($status.State) {
            'Completed' {
                Write-Log "[$($job.Name)] Patch cycle completed in $($status.Boot) boot(s): $($status.Message)" -Level SUCCESS
            }
            'Missing' {
                throw "No patch-cycle status in $($Config.GuestWorkPath) - the patch cycle never ran. Check the $($Config.GuestPatchTaskName) scheduled task."
            }
            default {
                Write-Log "[$($job.Name)] End of patchcycle.log:" -Level WARNING
                @($status.LogTail) | ForEach-Object { Write-Host "    $_" }
                if ($status.State -eq 'Failed') { throw "Patch cycle failed: $($status.Message)" }
                throw "Patch cycle did not finish (state '$($status.State)' at boot $($status.Boot)). The VM was powered off mid-cycle."
            }
        }
    }

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

    # ---- Seal and shut down -------------------------------------------------
    # Nothing may boot the VM after this - see SEAL in the header.
    Invoke-JobStep -Step 'Seal and shut down' -Jobs $jobs -Action {
        param($job)
        $vm   = Get-VM -Name $job.PatchingName -Server $job.Server
        $seal = Invoke-GuestSeal -VM $vm -GuestCredential $guestCredential

        Write-Log "[$($job.Name)] SCCM client: $($seal.CcmExec), $($seal.SmsCertsRemoved) SMS certificate(s) removed"
        foreach ($p in @($seal.LegacyRemoved | Where-Object { $_ })) { Write-Log "[$($job.Name)] Removed legacy script $p" }

        $problems = @($seal.Problems | Where-Object { $_ })
        if ($problems.Count -gt 0) {
            throw "Seal could not be confirmed, VM left running: $($problems -join '; ')"
        }
        Write-Log "[$($job.Name)] Sealed; guest shutting down" -Level SUCCESS
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
