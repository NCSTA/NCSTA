<#
.SYNOPSIS
    Resolve-SID: tells whether unresolved SIDs (STIG WN22-00-000450) are genuinely orphaned or
    belong to a domain the scanned server simply could not reach.

.NOTES
    HOW TO USE

    Needs the RSAT ActiveDirectory module and an account that can read every domain in scope.

    1. List your domains (DNS names) in $DomainsInScope just below.
       While it is empty, domains are discovered from the current forest and its trusts.

    2. Load the functions: paste this file into the ISE / VS Code script pane and press F5,
       or dot-source it:
           . .\Resolve-SID.ps1

    3. Build the domain map once and check that every domain shows Contacted = True:
           $map = Get-SidDomainMap
           $map | Format-Table DnsName, NetBIOSName, DomainSid, Contacted, Note

    4. Resolve SIDs. A leading * is ignored; a CSV needs a column named SID:
           Resolve-SID 'S-1-5-21-1004336348-1177238915-682003330-51234' -DomainMap $map
           Get-Content .\sids.txt | Resolve-SID -DomainMap $map | Format-Table SID, Status, Name, Enabled
           Import-Csv .\scan.csv | Resolve-SID -DomainMap $map | Export-Csv .\resolved.csv -NoTypeInformation

    5. Read the Status column:
           Resolved, SidHistory     A live account owns the SID. Not orphaned.
           Deleted, NotFound        The owning domain has no such account. Orphaned.
           QueryFailed              The owning domain could not be queried. Not confirmed either way.
           UnknownDomain            No known or trusted domain issued this SID.
           WellKnown, NotDomainSid  Not an AD account SID (built-in, service, capability, Entra ID).

       Enabled is True/False for accounts and blank for groups, which have no enabled state.

    For a domain that needs other credentials, add this to both Get-SidDomainMap and Resolve-SID:
           -Credential @{ 'fabrikam.com' = $cred }

    Full help: Get-Help Resolve-SID -Full
#>

# DNS names of every domain in scope. Used whenever -Domain is not passed.
# While this is empty, domains are discovered from the current forest and its trusts instead.
$DomainsInScope = @(
    # 'corp.contoso.com'
    # 'emea.contoso.com'
    # 'fabrikam.com'
)

function Get-SidDomainMap {
    <#
    .SYNOPSIS
        Lists every domain Resolve-SID can attribute a SID to: DNS name, NetBIOS name and domain SID.
    .DESCRIPTION
        Contacts exactly the domains in -Domain, which defaults to $DomainsInScope at the top of this file.
        If both are empty, starts at the current forest and follows trusts until no new domain turns up.

        In both modes the trustedDomain objects of every contacted domain are read, so a trusted domain that
        cannot be contacted (or was not listed) still appears with its SID and Contacted = $false.
    .PARAMETER Domain
        DNS names of the domains to contact, e.g. 'corp.contoso.com'. Defaults to $DomainsInScope.
    .PARAMETER Credential
        Hashtable of DNS domain name -> PSCredential for domains the current identity cannot read.
    .EXAMPLE
        $map = Get-SidDomainMap -Domain (Get-Content .\domains.txt)
        $map | Format-Table DnsName, NetBIOSName, DomainSid, Contacted, Note
    #>
    [CmdletBinding()]
    param(
        [string[]]$Domain = $DomainsInScope,
        [hashtable]$Credential = @{}
    )

    if (-not (Get-Command Get-ADDomain -ErrorAction SilentlyContinue)) {
        throw 'The ActiveDirectory module (RSAT) is required.'
    }

    $crawl = -not $Domain
    if ($crawl) {
        try { $Domain = @((Get-ADForest -ErrorAction Stop).Domains) }
        catch { throw "Could not discover the current forest ($($_.Exception.Message)). Pass -Domain with the DNS names of the domains to search." }
    }

    $entries = [ordered]@{}     # DNS name -> entry
    $visited = @{}
    $queue   = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($d in $Domain) { $queue.Enqueue($d) }

    while ($queue.Count) {
        $name = $queue.Dequeue()
        if ($visited[$name]) { continue }
        $visited[$name] = $true

        $ad = @{ Server = $name; ErrorAction = 'Stop' }
        if ($Credential[$name]) { $ad.Credential = $Credential[$name] }

        try { $dom = Get-ADDomain @ad }
        catch {
            $why = "Could not be contacted: $($_.Exception.Message)"
            Write-Warning "$name $why"
            if ($entries.Contains($name)) { $entries[$name].Note = $why }
            else {
                $entries[$name] = [pscustomobject]@{
                    DnsName = $name; NetBIOSName = $null; DomainSid = $null; Forest = $null; Contacted = $false; Note = $why
                }
            }
            continue
        }

        $visited[$dom.DNSRoot] = $true
        $entries[$dom.DNSRoot] = [pscustomobject]@{
            DnsName = $dom.DNSRoot; NetBIOSName = $dom.NetBIOSName; DomainSid = $dom.DomainSID.Value
            Forest = $dom.Forest; Contacted = $true; Note = $null
        }

        if ($crawl) {
            try { foreach ($sibling in (Get-ADForest @ad).Domains) { $queue.Enqueue($sibling) } }
            catch { Write-Warning "Could not list the forest of $($dom.DNSRoot): $($_.Exception.Message)" }
        }

        try {
            $trusts = @(Get-ADObject @ad -SearchBase $dom.SystemsContainer -SearchScope OneLevel `
                    -LDAPFilter '(objectClass=trustedDomain)' -Properties trustPartner, flatName, securityIdentifier)
        }
        catch {
            Write-Warning "Could not read the trusts of $($dom.DNSRoot): $($_.Exception.Message)"
            $trusts = @()
        }

        foreach ($t in $trusts) {
            $sid = $t.securityIdentifier
            if (-not $sid) { continue }     # MIT realm trust: issues no SIDs
            if ($sid -is [byte[]]) { $sid = New-Object System.Security.Principal.SecurityIdentifier($sid, 0) }
            $sid = "$sid"
            $partner = $t.trustPartner

            if (-not $entries.Contains($partner)) {
                $entries[$partner] = [pscustomobject]@{
                    DnsName = $partner; NetBIOSName = $t.flatName; DomainSid = $sid; Forest = $null; Contacted = $false
                    Note = "Known only from a trust object in $($dom.DNSRoot)"
                }
            }
            elseif (-not $entries[$partner].DomainSid) {
                $entries[$partner].DomainSid = $sid
                $entries[$partner].NetBIOSName = $t.flatName
            }

            if ($crawl) { $queue.Enqueue($partner) }
        }
    }

    $entries.Values
}

function Resolve-SID {
    <#
    .SYNOPSIS
        Resolves a SID against every domain in a multi-forest environment and reports the account name,
        whether it is enabled, and whether the SID is genuinely orphaned.
    .DESCRIPTION
        Splits the SID into its domain SID and RID, matches the domain SID against the domain map
        (see Get-SidDomainMap), then asks that domain for the object. Status is one of:

          Resolved       Live object found. Name, ObjectClass and Enabled are filled in.
          SidHistory     No object owns the SID, but a live migrated account carries it in sIDHistory.
          Deleted        Object is in Deleted Objects of its domain. Orphaned.
          NotFound       The owning domain was queried and has no such object. Orphaned.
          QueryFailed    The owning domain is known but could not be queried. NOT confirmed orphaned.
          UnknownDomain  The domain SID matches no known or trusted domain.
          WellKnown      Built-in / well-known SID resolved by this computer.
          NotDomainSid   Not an AD account SID (service SID, capability SID, Entra ID object, ...).
          Invalid        Not a SID.

        Enabled is $true/$false for users, computers and service accounts and empty for groups,
        which have no enabled state.
    .PARAMETER SID
        One or more SIDs. A leading '*' (as written by secedit and scan output) is ignored.
    .PARAMETER Domain
        DNS names of the domains to search. Defaults to $DomainsInScope at the top of this file; if that
        is empty too, they are discovered from the current forest and its trusts.
    .PARAMETER Credential
        Hashtable of DNS domain name -> PSCredential for domains the current identity cannot read.
    .PARAMETER DomainMap
        Output of Get-SidDomainMap, to avoid rebuilding the map on every call.
    .EXAMPLE
        Resolve-SID 'S-1-5-21-1004336348-1177238915-682003330-51234'
    .EXAMPLE
        Import-Csv .\orphaned-sids.csv | Resolve-SID -Domain (Get-Content .\domains.txt) |
            Export-Csv .\resolved.csv -NoTypeInformation

        The CSV needs a column named SID.
    .EXAMPLE
        $creds = @{ 'fabrikam.com' = Get-Credential }
        $map = Get-SidDomainMap -Domain (Get-Content .\domains.txt) -Credential $creds
        Get-Content .\sids.txt | Resolve-SID -DomainMap $map -Credential $creds |
            Where-Object Status -in 'NotFound', 'Deleted'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$SID,

        [string[]]$Domain = $DomainsInScope,

        [hashtable]$Credential = @{},

        [object[]]$DomainMap
    )

    begin {
        if (-not $DomainMap) { $DomainMap = @(Get-SidDomainMap -Domain $Domain -Credential $Credential) }

        $bySid = @{}
        foreach ($d in $DomainMap) { if ($d.DomainSid) { $bySid[$d.DomainSid] = $d } }

        # Domains whose SID could not be learned; an unmatched SID might still belong to one of them.
        $blind = @($DomainMap | Where-Object { -not $_.DomainSid } | ForEach-Object DnsName)

        $failed = @{}   # DNS name -> error, so a dead domain is tried only once per run

        $find = {
            param([string]$Server, [string]$Filter, [switch]$Deleted)
            $ad = @{
                Server = $Server; LDAPFilter = $Filter; ErrorAction = 'Stop'
                Properties = 'sAMAccountName', 'userAccountControl', 'lastKnownParent', 'whenChanged'
            }
            if ($Credential[$Server]) { $ad.Credential = $Credential[$Server] }
            if ($Deleted) { $ad.IncludeDeletedObjects = $true }
            Get-ADObject @ad | Select-Object -First 1
        }

        $translate = {
            param($SidObject)
            try { $SidObject.Translate([System.Security.Principal.NTAccount]).Value } catch { $null }
        }
    }

    process {
        foreach ($item in $SID) {
            $text = $item.Trim().TrimStart('*')
            $r = [ordered]@{
                SID = $text; Status = $null; Name = $null; Enabled = $null; ObjectClass = $null
                Domain = $null; DistinguishedName = $null; Detail = $null
            }

            $sidObj = $text -as [System.Security.Principal.SecurityIdentifier]

            if (-not $sidObj) {
                $r.Status = 'Invalid'
                $r.Detail = 'Not a valid SID string.'
            }
            elseif (-not $sidObj.AccountDomainSid) {
                $r.Name = & $translate $sidObj
                if ($r.Name) { $r.Status = 'WellKnown' }
                else {
                    $r.Status = 'NotDomainSid'
                    $r.Detail = switch -Wildcard ($text) {
                        'S-1-5-80-*' { 'Service SID (NT SERVICE\...). Resolves only on a host where that service is installed.' }
                        'S-1-5-82-*' { 'IIS application pool identity. Resolves only on the host that owns the app pool.' }
                        'S-1-5-83-*' { 'Hyper-V virtual machine SID. Resolves only on the Hyper-V host.' }
                        'S-1-12-1-*' { 'Microsoft Entra ID object. Cannot be resolved against AD DS.' }
                        'S-1-15-2-*' { 'AppContainer (app package) SID.' }
                        'S-1-15-3-*' { 'Capability SID. Never resolves to a name, by design.' }
                        default      { 'Not an AD account SID and not resolvable on this computer.' }
                    }
                }
            }
            else {
                $origin = $bySid[$sidObj.AccountDomainSid.Value]
                $hit = $null
                $hitDomain = $origin
                $queryError = $null

                if ($origin) {
                    $r.Domain = $origin.DnsName
                    if ($failed.ContainsKey($origin.DnsName)) { $queryError = $failed[$origin.DnsName] }
                    else {
                        try { $hit = & $find $origin.DnsName "(objectSid=$text)" }
                        catch {
                            $queryError = $_.Exception.Message
                            $failed[$origin.DnsName] = $queryError
                        }
                    }
                }

                if ($hit) { $r.Status = 'Resolved' }
                else {
                    # A migrated account keeps its old SID in sIDHistory, in whichever domain it now lives.
                    foreach ($d in $DomainMap) {
                        if (-not $d.Contacted -or $failed.ContainsKey($d.DnsName)) { continue }
                        try { $hit = & $find $d.DnsName "(sIDHistory=$text)" }
                        catch { $failed[$d.DnsName] = $_.Exception.Message }
                        if ($hit) { $hitDomain = $d; break }
                    }

                    if ($hit) {
                        $r.Status = 'SidHistory'
                        $r.Domain = $hitDomain.DnsName
                        $r.Detail = 'Carried in sIDHistory of this migrated account, so the SID still grants it access.'
                    }
                    elseif ($queryError) {
                        $r.Status = 'QueryFailed'
                        $r.Detail = "Belongs to $($origin.DnsName), which could not be queried: $queryError"
                    }
                    elseif ($origin) {
                        # Reading Deleted Objects needs Domain Admins or delegated rights; without them this finds nothing.
                        try { $hit = & $find $origin.DnsName "(&(objectSid=$text)(isDeleted=TRUE))" -Deleted } catch { }
                        if ($hit) {
                            $r.Status = 'Deleted'
                            $r.Detail = "Deleted from $($hit.lastKnownParent); last changed $($hit.whenChanged)."
                        }
                        else {
                            $r.Status = 'NotFound'
                            $r.Detail = "No object with this SID exists in $($origin.DnsName)."
                        }
                    }
                    else {
                        $r.Name = & $translate $sidObj
                        if ($r.Name) {
                            $r.Status = 'Resolved'
                            $r.Detail = 'Resolved by this computer only (local account, or a domain missing from the map). Enabled state not checked.'
                        }
                        else {
                            $r.Status = 'UnknownDomain'
                            $r.Detail = "Domain SID $($sidObj.AccountDomainSid) matches no known or trusted domain: a local account of some computer, or a domain or trust that no longer exists."
                            if ($blind) { $r.Detail += " Unverified: the SID of $($blind -join ', ') could not be learned, so it may belong there." }
                        }
                    }
                }

                if ($hit) {
                    $account = $hit.sAMAccountName
                    if (-not $account) { $account = $hit.Name }
                    $r.Name = '{0}\{1}' -f $hitDomain.NetBIOSName, $account
                    $r.ObjectClass = $hit.ObjectClass
                    $r.DistinguishedName = $hit.DistinguishedName
                    if ($r.Status -ne 'Deleted' -and $null -ne $hit.userAccountControl) {
                        $r.Enabled = -not ($hit.userAccountControl -band 2)     # 2 = ACCOUNTDISABLE
                    }
                }
            }

            [pscustomobject]$r
        }
    }
}
