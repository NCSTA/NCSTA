function Remove-ServerFromPatchGroups {

    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerFQDN,

        [Parameter(Mandatory)]
        [array]$PatchGroups,

        [System.Management.Automation.PSCredential]$Credential
    )

    $credSplat = @{}
    if ($Credential) { $credSplat['Credential'] = $Credential }

    $computerName   = $ComputerFQDN.Split('.')[0]
    $computerDomain = $ComputerFQDN.Substring($ComputerFQDN.IndexOf('.') + 1)

    Write-Verbose "Resolving computer '$computerName' in '$computerDomain'"

    try {
        $computer = Get-ADComputer -Identity $computerName -Server $computerDomain @credSplat -ErrorAction Stop
    }
    catch {
        Write-Error "Computer $ComputerFQDN not found in $computerDomain"
        return
    }

    foreach ($group in $PatchGroups) {

        $groupName   = $group.Name
        $groupDomain = $group.Domain

        Write-Verbose "Processing group '$groupName' in '$groupDomain'"

        try {

            if ($PSCmdlet.ShouldProcess($ComputerFQDN, "Remove from $groupName")) {

                Remove-ADGroupMember `
                    -Identity   $groupName `
                    -Members    $computer `
                    -Server     $groupDomain `
                    @credSplat `
                    -Confirm:$false `
                    -ErrorAction Stop

                [PSCustomObject]@{
                    Computer  = $ComputerFQDN
                    Group     = $groupName
                    Domain    = $groupDomain
                    Status    = 'Removed'
                    TimeStamp = (Get-Date)
                }
            }
        }
        catch {
            Write-Verbose "$ComputerFQDN not in $groupName ($groupDomain)"
        }
    }
}

Export-ModuleMember -Function Remove-ServerFromPatchGroups
