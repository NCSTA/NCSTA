<#
.SYNOPSIS
    Finds VM/template folders left on datastores after being removed from
    inventory (e.g. Remove-Template without -DeletePermanently).
.DESCRIPTION
    Read-only. Nothing is deleted or modified.

    1. Connects to every vCenter in $Config.VCenters
    2. Collects the folders used by every registered VM and template on all of
       them (datastores shared between vCenters are matched by datastore URL)
    3. Browses each datastore once and flags any folder that holds a .vmtx or
       .vmx file but is not used by anything registered
    4. For each orphan:
         Name        - displayName read from its .vmtx/.vmx (falls back to folder name)
         DateDeleted - time of the matching "VM removed" event in vCenter, if the
                       event is still within vCenter's event retention; otherwise
                       the config file's last-modified time, marked with *

    Prints a table of Name, Datastore, DateDeleted and writes a CSV with the full
    details (path, size, vCenter, date source).

    False positives to expect: folders belonging to VMs registered on hosts or
    vCenters not in the list, and anything else that keeps .vmx files outside
    inventory (e.g. replication targets). Check each folder before deleting it.

    HOW TO RUN
    Paste into a new (unsaved) PowerShell ISE script pane, edit the CONFIGURATION
    block below, and press F5. Running unsaved pane contents is not subject to
    the script execution policy, so nothing needs to be signed or saved.
    After it finishes, $orphans stays in the session for further filtering, e.g.
        $orphans | Where-Object Name -like '*_unpatch' | Out-GridView
#>

# =============================================================================
#  CONFIGURATION
# =============================================================================
$Config = @{
    # Wildcard applied to the orphan's name: '*' = everything, '*_unpatch' = patching leftovers only
    NameFilter            = '*'
    CsvPath               = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "orphaned_templates_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    VCenters              = @('VCENTER-01', 'VCENTER-02', 'VCENTER-03', 'VCENTER-04')
    VCenterCredentialPath = 'C:\temp\credstore\ps.xml'

    # Datastore folders that never hold orphaned VMs
    ExcludeFolderPatterns = @('.sdd.sf*', '.vSphere-HA*', '.dvsData*', '.naa.*', 'contentlib-*', 'vmkdump*', '.locker*')
}

# =============================================================================
#  HELPERS
# =============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS')][string]$Level = 'INFO'
    )
    $colors = @{ INFO = 'Cyan'; WARNING = 'Yellow'; ERROR = 'Red'; SUCCESS = 'Green' }
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message" -ForegroundColor $colors[$Level]
}

function Get-StoredCredential {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Prompt
    )
    if (Test-Path $Path) { return Import-Clixml -Path $Path }

    $credential = Get-Credential -Message $Prompt
    if (-not $credential) { throw "No credential entered for: $Prompt" }
    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $credential | Export-Clixml -Path $Path
    return $credential
}

# "[datastore1] folder/file.vmx" -> "ds:///vmfs/volumes/<uuid>/folder/"
# Using the datastore URL means a datastore shared by two vCenters (possibly under
# different names) is treated as the same place.
function ConvertTo-FolderKey {
    param(
        [Parameter(Mandatory = $true)][string]$DatastorePath,
        [Parameter(Mandatory = $true)][hashtable]$NameToUrl,
        [switch]$IsFolder
    )

    if ($DatastorePath -notmatch '^\[(?<ds>[^\]]+)\]\s*(?<rel>.*)$') { return $null }
    $url = $NameToUrl[$Matches.ds]
    if (-not $url) { return $null }

    $rel = $Matches.rel
    if (-not $IsFolder) { $rel = $rel.Substring(0, $rel.LastIndexOf('/') + 1) }
    if ($rel -and -not $rel.EndsWith('/')) { $rel += '/' }

    return ($url.TrimEnd('/') + '/' + $rel).ToLowerInvariant()
}

# Returns every folder (as a folder key) used by a registered VM or template.
function Get-RegisteredFolders {
    param(
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][hashtable]$NameToUrl
    )

    $folders = [System.Collections.Generic.HashSet[string]]::new()
    $views = Get-View -ViewType VirtualMachine -Server $Server -Property Name, LayoutEx.File, Config.Files.VmPathName

    foreach ($view in $views) {
        $paths = @()
        if ($view.LayoutEx -and $view.LayoutEx.File) { $paths += $view.LayoutEx.File.Name }
        if ($view.Config -and $view.Config.Files)    { $paths += $view.Config.Files.VmPathName }

        foreach ($path in $paths) {
            $key = ConvertTo-FolderKey -DatastorePath $path -NameToUrl $NameToUrl
            if ($key) { [void]$folders.Add($key) }
        }
    }

    Write-Log "$($Server.Name): $($views.Count) registered VMs/templates"
    return , $folders
}

# Returns name -> sorted list of removal times for VmRemovedEvent still in the
# vCenter event history.
function Get-VmRemovedEvents {
    param([Parameter(Mandatory = $true)]$Server)

    $removed = @{}
    $eventManager = Get-View EventManager -Server $Server
    $filter = New-Object VMware.Vim.EventFilterSpec
    $filter.EventTypeId = @('VmRemovedEvent')

    $collector = Get-View ($eventManager.CreateCollectorForEvents($filter)) -Server $Server
    try {
        $collector.RewindCollector()   # start from the oldest retained event
        do {
            $page = $collector.ReadNextEvents(1000)
            foreach ($e in $page) {
                $name = $e.Vm.Name
                if (-not $removed.ContainsKey($name)) { $removed[$name] = [System.Collections.Generic.List[datetime]]::new() }
                $removed[$name].Add($e.CreatedTime.ToLocalTime())
            }
        } while ($page)
    } finally {
        $collector.DestroyCollector()
    }

    foreach ($list in $removed.Values) { $list.Sort() }
    Write-Log "$($Server.Name): $(($removed.Values | Measure-Object -Property Count -Sum).Sum) VM-removed events in history"
    return $removed
}

# Downloads a small .vmtx/.vmx and returns its displayName, or $null.
function Get-ConfigDisplayName {
    param(
        [Parameter(Mandatory = $true)]$Datastore,
        [Parameter(Mandatory = $true)][string]$RelativePath   # folder/file.vmtx
    )

    $driveName = 'orphscan'
    $tempFile  = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.cfg')
    try {
        New-PSDrive -Name $driveName -PSProvider VimDatastore -Root '\' -Location $Datastore -ErrorAction Stop | Out-Null
        Copy-DatastoreItem -Item ("${driveName}:\" + $RelativePath.Replace('/', '\')) -Destination $tempFile -ErrorAction Stop
        $match = Select-String -Path $tempFile -Pattern '^\s*displayName\s*=\s*"(.*)"' | Select-Object -First 1
        if ($match) { return $match.Matches[0].Groups[1].Value }
    } catch {
        Write-Log "Could not read $RelativePath on $($Datastore.Name): $($_.Exception.Message)" -Level WARNING
    } finally {
        Remove-PSDrive -Name $driveName -ErrorAction SilentlyContinue
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
    return $null
}

# Browses one datastore and returns a result object per orphaned VM folder.
function Find-OrphanedFolders {
    param(
        [Parameter(Mandatory = $true)]$Datastore,
        [Parameter(Mandatory = $true)]$Server,
        [Parameter(Mandatory = $true)][hashtable]$NameToUrl,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$RegisteredFolders
    )

    $browser = Get-View $Datastore.ExtensionData.Browser -Server $Server

    $spec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
    $spec.MatchPattern = @('*')
    $spec.Details = New-Object VMware.Vim.FileQueryFlags -Property @{
        FileType = $true; FileSize = $true; Modification = $true; FileOwner = $false
    }

    $results = $browser.SearchDatastoreSubFolders("[$($Datastore.Name)]", $spec)

    foreach ($folder in $results) {
        $relFolder = ($folder.FolderPath -replace '^\[[^\]]+\]\s*', '')
        $topLevel  = $relFolder.Split('/')[0]
        if (-not $relFolder) { continue }
        if ($Config.ExcludeFolderPatterns | Where-Object { $topLevel -like $_ }) { continue }

        $config = $folder.File | Where-Object { $_.Path -like '*.vmtx' -or $_.Path -like '*.vmx' } |
                  Sort-Object { $_.Path -notlike '*.vmtx' } | Select-Object -First 1
        if (-not $config) { continue }

        $key = ConvertTo-FolderKey -DatastorePath $folder.FolderPath -NameToUrl $NameToUrl -IsFolder
        if (-not $key -or $RegisteredFolders.Contains($key)) { continue }

        [pscustomobject]@{
            Datastore    = $Datastore
            FolderPath   = $folder.FolderPath
            RelFolder    = $relFolder
            ConfigFile   = $config.Path
            IsTemplate   = $config.Path -like '*.vmtx'
            LastModified = $config.Modification.ToLocalTime()
            SizeGB       = [math]::Round((($folder.File | Measure-Object -Property FileSize -Sum).Sum) / 1GB, 1)
        }
    }
}

# =============================================================================
#  MAIN
# =============================================================================
$connectedServers = @()
try {
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        throw "This session runs in $($ExecutionContext.SessionState.LanguageMode) mode (AppLocker/WDAC policy); the vSphere API calls this scan needs are blocked there."
    }

    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Set-PowerCLIConfiguration -Scope Session -DefaultVIServerMode Multiple -Confirm:$false | Out-Null

    $credential = Get-StoredCredential -Path $Config.VCenterCredentialPath -Prompt 'Credentials for the vCenter servers'
    foreach ($vCenter in $Config.VCenters) {
        try {
            $connectedServers += Connect-VIServer -Server $vCenter -Credential $credential -ErrorAction Stop
            Write-Log "Connected to $vCenter" -Level SUCCESS
        } catch {
            Write-Log "Failed to connect to $vCenter : $($_.Exception.Message)" -Level ERROR
        }
    }
    if ($connectedServers.Count -eq 0) { throw 'Could not connect to any vCenter' }
    if ($connectedServers.Count -lt $Config.VCenters.Count) {
        Write-Log 'Not every vCenter connected - VMs on the missing ones will show up as false orphans' -Level WARNING
    }

    # ---- Inventory from every vCenter --------------------------------------
    $registered   = [System.Collections.Generic.HashSet[string]]::new()
    $datastores   = @{}   # url -> @{ Datastore; Server }
    $removalsBy   = @{}   # vCenter name -> removed-events table
    $nameToUrlBy  = @{}   # vCenter name -> datastore name -> url

    foreach ($server in $connectedServers) {
        $nameToUrl = @{}
        foreach ($ds in (Get-Datastore -Server $server)) {
            $url = $ds.ExtensionData.Info.Url
            $nameToUrl[$ds.Name] = $url
            if (-not $datastores.ContainsKey($url) -and $ds.ExtensionData.Summary.Accessible) {
                $datastores[$url] = @{ Datastore = $ds; Server = $server }
            }
        }
        $nameToUrlBy[$server.Name] = $nameToUrl

        $registered.UnionWith((Get-RegisteredFolders -Server $server -NameToUrl $nameToUrl))
        $removalsBy[$server.Name] = Get-VmRemovedEvents -Server $server
    }

    # ---- Scan datastores ----------------------------------------------------
    $orphans = @()
    $i = 0
    foreach ($url in $datastores.Keys) {
        $i++
        $ds     = $datastores[$url].Datastore
        $server = $datastores[$url].Server
        Write-Progress -Activity 'Scanning datastores' -Status $ds.Name -PercentComplete ($i / $datastores.Count * 100)

        try {
            $found = @(Find-OrphanedFolders -Datastore $ds -Server $server -NameToUrl $nameToUrlBy[$server.Name] -RegisteredFolders $registered)
        } catch {
            Write-Log "Failed to scan $($ds.Name) on $($server.Name): $($_.Exception.Message)" -Level ERROR
            continue
        }

        foreach ($item in $found) {
            $name = Get-ConfigDisplayName -Datastore $ds -RelativePath ($item.RelFolder.TrimEnd('/') + '/' + $item.ConfigFile)
            if (-not $name) { $name = $item.RelFolder.TrimEnd('/') }
            if ($name -notlike $Config.NameFilter) { continue }

            # The same name (e.g. X_unpatch) is removed every month, so take the
            # first removal of that name after the config file was last written.
            $deleted = $null
            foreach ($removals in $removalsBy.Values) {
                if ($removals.ContainsKey($name)) {
                    $candidate = $removals[$name] | Where-Object { $_ -ge $item.LastModified } | Select-Object -First 1
                    if ($candidate -and (-not $deleted -or $candidate -lt $deleted)) { $deleted = $candidate }
                }
            }

            $orphans += [pscustomobject]@{
                Name        = $name
                Datastore   = $ds.Name
                DateDeleted = if ($deleted) { $deleted } else { $item.LastModified }
                DateSource  = if ($deleted) { 'vCenter event' } else { 'Config file last modified' }
                Type        = if ($item.IsTemplate) { 'Template' } else { 'VM' }
                SizeGB      = $item.SizeGB
                Path        = $item.FolderPath
                vCenter     = $server.Name
            }
        }
        Write-Log "$($ds.Name): $($found.Count) orphaned folder(s)"
    }
    Write-Progress -Activity 'Scanning datastores' -Completed

    # ---- Report -------------------------------------------------------------
    if ($orphans.Count -eq 0) {
        Write-Log "No orphaned VM/template folders found matching '$($Config.NameFilter)'" -Level SUCCESS
    } else {
        $orphans = $orphans | Sort-Object DateDeleted
        $orphans | Format-Table Name, Datastore, @{
            Name       = 'DateDeleted'
            Expression = {
                $stamp = $_.DateDeleted.ToString('yyyy-MM-dd HH:mm')
                if ($_.DateSource -eq 'vCenter event') { $stamp } else { "$stamp *" }
            }
        } -AutoSize | Out-String -Width 250 | Write-Host

        Write-Host '* No removal event left in vCenter history; showing when the config file was last modified.'
        Write-Log ("{0} orphaned folder(s), {1:N1} GB total" -f $orphans.Count, ($orphans | Measure-Object SizeGB -Sum).Sum) -Level WARNING

        $orphans | Export-Csv -Path $Config.CsvPath -NoTypeInformation
        Write-Log "Full details (path, size, vCenter) written to $($Config.CsvPath)" -Level SUCCESS
    }
} catch {
    # No 'exit' here - in the ISE that would close the whole editor
    Write-Log "Fatal error: $($_.Exception.Message)" -Level ERROR
} finally {
    foreach ($server in $connectedServers) {
        Disconnect-VIServer -Server $server -Confirm:$false -ErrorAction SilentlyContinue
    }
}
