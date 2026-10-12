# Resolve-SID

Tells whether an unresolved SID found on a server is genuinely orphaned, or belongs to a domain that the scanned server simply could not reach.

Written for STIG finding WN22-00-000450 in multi-forest environments, where a scanner reports a raw SID because the server has no trust path to the domain that issued it.

## Requirements

- Windows PowerShell 5.1 or later
- `ActiveDirectory` module (RSAT)
- An account that can read every domain in scope

## Usage

1. List your domains in `$DomainsInScope` at the top of the script. If it is left empty, domains are discovered from the current forest and its trusts.

2. Load the functions by dot-sourcing the file:

   ```powershell
   . .\Resolve-SID.ps1
   ```

3. Build the domain map once and confirm every domain shows `Contacted = True`:

   ```powershell
   $map = Get-SidDomainMap
   $map | Format-Table DnsName, NetBIOSName, DomainSid, Contacted, Note
   ```

4. Resolve SIDs. A leading `*` is ignored, and a CSV needs a column named `SID`:

   ```powershell
   Resolve-SID 'S-1-5-21-1004336348-1177238915-682003330-51234' -DomainMap $map
   Get-Content .\sids.txt | Resolve-SID -DomainMap $map | Format-Table SID, Status, Name, Enabled
   Import-Csv .\scan.csv | Resolve-SID -DomainMap $map | Export-Csv .\resolved.csv -NoTypeInformation
   ```

For a domain that needs different credentials, pass `-Credential @{ 'fabrikam.com' = $cred }` to both functions.

## Reading the result

| Status | Meaning |
|---|---|
| `Resolved`, `SidHistory` | A live account owns the SID. Not orphaned. |
| `Deleted`, `NotFound` | The owning domain has no such account. Orphaned. |
| `QueryFailed` | The owning domain could not be queried. Not confirmed either way. |
| `UnknownDomain` | No known or trusted domain issued this SID. |
| `WellKnown`, `NotDomainSid` | Not an AD account SID (built-in, service, capability, Entra ID). |

`Enabled` is `True` or `False` for accounts and blank for groups.

Full help is available with `Get-Help Resolve-SID -Full` once the file is loaded.
