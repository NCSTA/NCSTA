function New-ActionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [ValidateSet('Success', 'NotNeeded', 'Failed')] [string]$Status,
        [Parameter(Mandatory)] [string]$Domain,
        [Parameter(Mandatory)] [string]$Message
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
        $results = @()
    }

    process {

        foreach ($fqdn in $ComputerFQDN) {

            $computerName   = $fqdn.Split('.')[0]
            $computerDomain = $fqdn.Substring($fqdn.IndexOf('.') + 1)

            try {
                $computer = Get-ADComputer -Identity $computerName -Server $computerDomain -Properties memberOf -ErrorAction Stop
            }
            catch {
                $results += New-ActionResult $fqdn 'Resolve Computer' 'Failed' $computerDomain $_.Exception.Message
                continue
            }

            foreach ($group in $PatchGroups) {

                $groupName   = $group.Name
                $groupDomain = $group.Domain

                try {

                    $isMemberBefore = $computer.memberOf -match "CN=$groupName,"

                    if (-not $isMemberBefore) {
                        $results += New-ActionResult $fqdn "Remove from $groupName" 'NotNeeded' $groupDomain 'Not a member'
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($fqdn, "Remove from $groupName")) {

                        Remove-ADGroupMember `
                            -Identity $groupName `
                            -Members $computer `
                            -Server $groupDomain `
                            -Confirm:$false `
                            -ErrorAction Stop
                    }

                    $results += New-ActionResult $fqdn "Remove from $groupName" 'Success' $groupDomain 'Membership removed'

                }
                catch {
                    $results += New-ActionResult $fqdn "Remove from $groupName" 'Failed' $groupDomain $_.Exception.Message
                }
            }
        }
    }

    end {
        return $results
    }
}

Export-ModuleMember -Function New-ActionResult, Remove-ServerFromPatchGroups
