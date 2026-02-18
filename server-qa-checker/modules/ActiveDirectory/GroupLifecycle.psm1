function New-ActionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [ValidateSet('Success', 'NotNeeded', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Domain,

        [Parameter(Mandatory)]
        [string]$Message
    )

    [pscustomobject]@{
        TimeStamp = Get-Date
        Target    = $Target
        Action    = $Action
        Status    = $Status
        Domain    = $Domain
        Message   = $Message
    }
}

function Remove-ServerFromPatchGroups {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$ComputerFQDN,

        [Parameter(Mandatory)]
        [array]$PatchGroups
    )

    begin {
        $results = New-Object System.Collections.Generic.List[object]

        if (-not (Get-Module -Name ActiveDirectory)) {
            Import-Module ActiveDirectory -ErrorAction Stop
        }
    }

    process {
        foreach ($fqdn in $ComputerFQDN) {
            if ([string]::IsNullOrWhiteSpace($fqdn)) {
                continue
            }

            $targetFqdn = $fqdn.Trim()
            $firstDot = $targetFqdn.IndexOf('.')
            if ($firstDot -lt 1) {
                $results.Add((New-ActionResult -Target $targetFqdn -Action 'Resolve Computer' -Status 'Failed' -Domain '' -Message 'Computer FQDN must include a domain.'))
                continue
            }

            $computerName = $targetFqdn.Substring(0, $firstDot)
            $computerDomain = $targetFqdn.Substring($firstDot + 1)

            try {
                $computer = Get-ADComputer -Identity $computerName -Server $computerDomain -Properties DistinguishedName, memberOf -ErrorAction Stop
            }
            catch {
                $results.Add((New-ActionResult -Target $targetFqdn -Action 'Resolve Computer' -Status 'Failed' -Domain $computerDomain -Message $_.Exception.Message))
                continue
            }

            foreach ($group in $PatchGroups) {
                $groupName = [string]$group.Name
                $groupDomain = [string]$group.Domain

                if ([string]::IsNullOrWhiteSpace($groupName) -or [string]::IsNullOrWhiteSpace($groupDomain)) {
                    $results.Add((New-ActionResult -Target $targetFqdn -Action 'Validate Patch Group Config' -Status 'Failed' -Domain $groupDomain -Message 'Patch group entry must include Name and Domain.'))
                    continue
                }

                $actionLabel = "Remove from $groupName"
                try {
                    $groupObject = Get-ADGroup -Identity $groupName -Server $groupDomain -Properties DistinguishedName -ErrorAction Stop
                    $groupDn = $groupObject.DistinguishedName

                    $memberOfBefore = @($computer.memberOf)
                    $isMemberBefore = $memberOfBefore -contains $groupDn

                    if (-not $isMemberBefore) {
                        $results.Add((New-ActionResult -Target $targetFqdn -Action $actionLabel -Status 'NotNeeded' -Domain $groupDomain -Message 'Not a member'))
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($targetFqdn, $actionLabel)) {
                        Remove-ADGroupMember -Identity $groupDn -Members $computer.DistinguishedName -Server $groupDomain -Confirm:$false -ErrorAction Stop
                    }
                    elseif ($WhatIfPreference) {
                        $results.Add((New-ActionResult -Target $targetFqdn -Action $actionLabel -Status 'NotNeeded' -Domain $groupDomain -Message 'WhatIf: no change applied'))
                        continue
                    }

                    $computerAfter = Get-ADComputer -Identity $computer.DistinguishedName -Server $computerDomain -Properties memberOf -ErrorAction Stop
                    $memberOfAfter = @($computerAfter.memberOf)
                    $isMemberAfter = $memberOfAfter -contains $groupDn

                    if (-not $isMemberAfter) {
                        $results.Add((New-ActionResult -Target $targetFqdn -Action $actionLabel -Status 'Success' -Domain $groupDomain -Message 'Membership removed'))
                    }
                    else {
                        $results.Add((New-ActionResult -Target $targetFqdn -Action $actionLabel -Status 'Failed' -Domain $groupDomain -Message 'Membership still present after removal attempt'))
                    }
                }
                catch {
                    $results.Add((New-ActionResult -Target $targetFqdn -Action $actionLabel -Status 'Failed' -Domain $groupDomain -Message $_.Exception.Message))
                }
            }
        }
    }

    end {
        $results
    }
}

Export-ModuleMember -Function New-ActionResult, Remove-ServerFromPatchGroups
