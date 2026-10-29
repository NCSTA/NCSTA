# gMSA Creation Utility

WPF GUI for creating group Managed Service Accounts (gMSA), and for maintaining existing ones: which servers, service accounts, and groups may retrieve the password, and which SPNs are registered on the account.

## Requirements

- Windows PowerShell 5.1
- `ActiveDirectory` module (RSAT)
- Rights to create service accounts in the target domain
- A KDS root key already present in the forest

## Usage

```powershell
.\gMSA-Creation-GUI.ps1
```

### Create gMSA tab

| Input | Purpose |
|---|---|
| Domain / AD Server | Domain the account is created in |
| gMSA Short Name | Account name without the trailing `$` |
| Allowed Principals | One per line: a server, service account, group, or gMSA, by name or distinguished name. These become the principals allowed to retrieve the managed password |
| Enable unconstrained delegation | Optional; sets `TrustedForDelegation` on the account after creation |

1. Fill in the inputs and select **Preview Command** to see the exact PowerShell that will run.
2. Select **Execute** to create the account. Execute stays disabled until a preview has been generated.
3. **Reset Form** clears the inputs.

The DNS host name is built as `<short name>.<domain>`.

### Managed Password Retrieval Lookup

Select **Run Lookup** to list the `PrincipalsAllowedToRetrieveManagedPassword` of an existing gMSA, each labelled `[Server]`, `[Service Account]`, `[Group]`, or `[gMSA]`. The lookup uses the domain and gMSA short name entered in the inputs above.

### Manage gMSA tab

For day-to-day changes to an existing gMSA. After a successful create, the tab is pre-filled with the new account.

1. Enter the domain and gMSA short name, then select **Load gMSA**. The two lists show the current allowed principals and SPNs.
2. **Allowed principals**
   - To add: pick the object type (**Auto-detect**, **Server**, **Service Account**, **Group**, or **gMSA**), enter one name per line, and select **Add Principals**.
   - To remove: select entries (Ctrl+click or Shift+click for several) and select **Remove Selected**.
3. **SPNs**
   - To add: enter one SPN per line in the form `service/host[:port]` (for example `MSSQLSvc/sqlserver01a.domain.com:1433`) and select **Add SPNs**.
   - To remove: select entries and select **Remove Selected**.

Every change asks for confirmation first and then reloads the lists. Changes always apply to the loaded account. Editing either field unloads it, so a typo can't redirect a change to another account.

Safeguards:

- An SPN already registered on another object in the domain is refused, since duplicate SPNs break Kerberos.
- The last allowed principal can't be removed. Add its replacement first.

### Console Log tab

Shows a timestamped log of every action and the full text of any error.

## Notes

- Each allowed principal must already exist in the domain. **Auto-detect** matches an exact account name first, then a computer with that name. If a service account and a server share a name, pick the type explicitly or use the distinguished name.
- The duplicate SPN check covers the gMSA's own domain only, not other domains in the forest.
- Managing SPNs needs write access to `servicePrincipalName` on the gMSA (Domain Admins, or delegated rights).
- Installing the account on the member servers (`Install-ADServiceAccount`) is a separate step and is not done by this tool.
