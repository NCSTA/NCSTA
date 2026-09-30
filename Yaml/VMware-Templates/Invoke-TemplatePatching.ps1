<#
.SYNOPSIS
    Monthly VMware template patching.
.DESCRIPTION
    For each template listed in the templates CSV:
      1. Clones <name> to <name>_patching and waits for the clone task
      2. Converts the clone to a VM, powers it on, copies this month's patches in
      3. Registers the LoopingPatch scheduled task and reboots the guest
      4. Waits for the patch cycle to finish (the guest powers itself off)
      5. Powers on, shows the latest hotfixes, pauses for operator review
      6. Shuts down, stamps the notes, and promotes:
           <name>_unpatch  -> removed (last month's rollback)
           <name>          -> <name>_unpatch
           <name>_patching -> <name>

    Every template is tracked independently. A template that fails any step is
    skipped for the rest of the run and is never promoted, so its production
    template and _unpatch rollback copy are left untouched. A summary table is
    printed at the end.

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
$Config = @{
    # --- Run options ---------------------------------------------------------
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

    # $false only unregisters last month's _unpatch template, leaving its disks on
    # the datastore (the original script's behaviour). $true deletes the disks too.
    DeleteOldUnpatchPermanently = $false
}

$RunTimestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath      = Join-Path $Config.LogDirectory "template_patching_$RunTimestamp.log"

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
    [string]$Status = 'Pending' # Pending | Completed | Failed
    [string]$FailedStep
    [string]$Message

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

# Runs $Action once per still-active job. Any exception marks that job failed
# and the remaining jobs carry on.
function Invoke-JobStep {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][TemplateJob[]]$Jobs,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    $ErrorActionPreference = 'Stop'
    $active = Select-ActiveJob $Jobs
    Write-Log "---- $Step ($($active.Count) template(s)) ----"

    foreach ($job in $active) {
        try {
            & $Action $job
        } catch {
            Set-JobFailed -Job $job -Step $Step -Message $_.Exception.Message
        }
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
# when -FailOnTimeout is set, otherwise just logged.
function Wait-JobPowerState {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][TemplateJob[]]$Jobs,
        [Parameter(Mandatory = $true)][ValidateSet('PoweredOn', 'PoweredOff')][string]$PowerState,
        [Parameter(Mandatory = $true)][string]$Step,
        [int]$TimeoutMinutes = 10,
        [int]$PollSeconds = 30,
        [switch]$FailOnTimeout
    )

    $pending  = Select-ActiveJob $Jobs
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    Write-Log "---- $Step ($($pending.Count) template(s), timeout $TimeoutMinutes min) ----"

    while ($pending.Count -gt 0) {
        $stillPending = @()
        foreach ($job in $pending) {
            $vm = Get-VM -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue
            if (-not $vm) {
                Set-JobFailed -Job $job -Step $Step -Message "VM $($job.PatchingName) not found"
            } elseif ($vm.PowerState -ne $PowerState) {
                $stillPending += $job
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
                }
            }
            return
        }

        Write-Log "Waiting for $PowerState : $(($pending | ForEach-Object PatchingName) -join ', ')"
        Start-Sleep -Seconds $PollSeconds
    }

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
function Publish-PatchedTemplate {
    param([Parameter(Mandatory = $true)][TemplateJob]$Job)

    $server = $Job.Server
    $vm = Get-VM -Name $Job.PatchingName -Server $server -ErrorAction Stop

    if ($vm.PowerState -ne 'PoweredOff') {
        Write-Log "[$($Job.Name)] $($Job.PatchingName) did not shut down cleanly; powering off" -Level WARNING
        $vm = Stop-VM -VM $vm -Confirm:$false -ErrorAction Stop
    }

    $patched = Set-VM -VM $vm -ToTemplate -Confirm:$false -ErrorAction Stop

    $oldUnpatch = Get-Template -Name $Job.UnpatchName -Server $server -ErrorAction SilentlyContinue
    if ($oldUnpatch) {
        Remove-Template -Template $oldUnpatch -DeletePermanently:$Config.DeleteOldUnpatchPermanently `
            -Confirm:$false -ErrorAction Stop
        Write-Log "[$($Job.Name)] Removed old $($Job.UnpatchName)"
    }

    $current = Get-Template -Name $Job.Name -Server $server -ErrorAction Stop
    Set-Template -Template $current -Name $Job.UnpatchName -Confirm:$false -ErrorAction Stop | Out-Null

    try {
        Set-Template -Template $patched -Name $Job.Name -Confirm:$false -ErrorAction Stop | Out-Null
    } catch {
        throw ("Production template was renamed to $($Job.UnpatchName) but $($Job.PatchingName) could not be " +
               "renamed to $($Job.Name). Rename it manually. Error: $($_.Exception.Message)")
    }
}

# =============================================================================
#  MAIN
# =============================================================================
$jobs             = @()
$connectedServers = @()

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

    # ---- Load templates -----------------------------------------------------
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
    Write-Log "Loaded $($jobs.Count) template(s) from $($Config.TemplatesFilePath)" -Level SUCCESS

    # ---- Collect patches ----------------------------------------------------
    $patchRunFolder = Get-PatchesFromTestServer -TestServers $Config.TestServers `
        -DestinationRoot $Config.PatchesRootPath -LookbackDays $Config.PatchLookbackDays

    # ---- Locate templates and check for leftovers ---------------------------
    Invoke-JobStep -Step 'Locate template' -Jobs $jobs -Action {
        param($job)
        $query = @{ Name = $job.Name; ErrorAction = 'SilentlyContinue' }
        if ($job.VCenter) { $query.Server = $job.VCenter }

        $found = @(Get-Template @query)
        if ($found.Count -eq 0) { throw 'Template not found on any connected vCenter' }
        if ($found.Count -gt 1) { throw "Template exists on $($found.Count) vCenters; add a vCenter column to the CSV" }

        $job.Server = Get-OwningServer $found[0]

        $leftover = @(Get-Template -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue) +
                    @(Get-VM       -Name $job.PatchingName -Server $job.Server -ErrorAction SilentlyContinue)
        if ($leftover.Count -gt 0) {
            throw "$($job.PatchingName) already exists (left over from a previous run?). Remove or rename it first."
        }
        Write-Log "[$($job.Name)] Found on $($job.Server.Name)"
    }

    # ---- Clone --------------------------------------------------------------
    Invoke-JobStep -Step 'Start clone' -Jobs $jobs -Action {
        param($job)
        Start-TemplateClone -Job $job
        Write-Log "[$($job.Name)] Clone to $($job.PatchingName) started"
    }

    Invoke-JobStep -Step 'Wait for clone' -Jobs $jobs -Action {
        param($job)
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
        $vm = Get-Template -Name $job.PatchingName -Server $job.Server | Set-Template -ToVM -Confirm:$false
        Start-VM -VM $vm -Confirm:$false | Out-Null
        Write-Log "[$($job.Name)] $($job.PatchingName) converted and powered on" -Level SUCCESS
    }

    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOn -Step 'Wait for power on' `
        -TimeoutMinutes $Config.PowerOnTimeoutMinutes -FailOnTimeout

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
        Get-VM -Name $job.PatchingName -Server $job.Server | Start-VM -Confirm:$false | Out-Null
    }

    Wait-JobPowerState -Jobs $jobs -PowerState PoweredOn -Step 'Wait for power on' `
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

    if ($Config.PauseForReview -and (Select-ActiveJob $jobs).Count -gt 0) {
        $answer = Read-Host 'Review the hotfix output above. Press Enter to promote the patched templates, or type ABORT to stop'
        if ($answer -eq 'ABORT') {
            foreach ($job in (Select-ActiveJob $jobs)) {
                Set-JobFailed -Job $job -Step 'Review' -Message "Aborted by operator; $($job.PatchingName) left powered on"
            }
        }
    }

    # ---- Shut down ----------------------------------------------------------
    Invoke-JobStep -Step 'Shut down guest' -Jobs $jobs -Action {
        param($job)
        Get-VM -Name $job.PatchingName -Server $job.Server | Stop-VMGuest -Confirm:$false | Out-Null
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
        Write-Log '==== Summary ===='
        $jobs | Sort-Object Status, Name |
            Format-Table Name, Status, FailedStep, Message -AutoSize -Wrap |
            Out-String -Width 250 | Write-Host

        $failed = @($jobs | Where-Object { $_.Status -ne 'Completed' })
        if ($failed.Count -gt 0) {
            Write-Log "$($failed.Count) template(s) were not promoted. Their production and _unpatch templates are unchanged; clean up any leftover _patching VMs/templates before the next run." -Level WARNING
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
