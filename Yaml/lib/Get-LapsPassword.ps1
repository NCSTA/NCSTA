function Get-LapsPassword {
    <#
    .SYNOPSIS
        Retrieves the legacy LAPS password for a server and returns a PSCredential.
    .DESCRIPTION
        Accepts an FQDN, splits the hostname and domain, then queries the correct
        AD domain controller for the ms-Mcs-AdmPwd attribute. Supports multi-domain
        environments by targeting each server's native domain.
    .PARAMETER FQDN
        Fully qualified domain name of the target server (e.g. server01.corp.contoso.com).
    .OUTPUTS
        [PSCredential] Local Administrator credential using the LAPS password.
    .EXAMPLE
        $cred = Get-LapsPassword -FQDN "server01.corp.contoso.com"
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidatePattern('^[^.]+\..+\..+$')]
        [string]$FQDN
    )

    process {
        $parts      = $FQDN.Split('.')
        $serverName = $parts[0]
        $domain     = ($parts[1..($parts.Length - 1)]) -join '.'

        Write-Verbose "[$serverName] Querying LAPS via domain: $domain"

        try {
            $computer = Get-ADComputer `
                -Identity $serverName `
                -Server   $domain `
                -Properties 'ms-Mcs-AdmPwd' `
                -ErrorAction Stop
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            throw "[$serverName] Computer account not found in domain '$domain'."
        }
        catch {
            throw "[$serverName] AD query failed against '$domain': $($_.Exception.Message)"
        }

        $plainPassword = $computer.'ms-Mcs-AdmPwd'

        if ([string]::IsNullOrEmpty($plainPassword)) {
            throw "[$serverName] LAPS attribute (ms-Mcs-AdmPwd) is empty. " +
                  "Verify LAPS is deployed and the running account has ExtendedRight read access."
        }

        $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential(
            "$serverName\Administrator",
            $securePassword
        )
    }
}
