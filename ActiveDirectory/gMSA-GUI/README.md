# gMSA Management Utility

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

### Running with admin credentials

By default, AD commands run as the signed-in user. Alternate credentials work the same way as in the Server QA Checker.

**Credentials button** (top-right corner)

- **Left-click** prompts for an account. If a domain is already filled in, the account is checked against it straight away.
- **Right-click** clears the alternate account and goes back to the signed-in user.
- While alternate credentials are set, the button shows the username in amber. The window title and the status bar (`User: ...`) show it too.

Every AD command uses the alternate account, including the PowerShell shown under **Show PowerShell**. Changing the account clears any finished review.

The status light next to the button shows which account is in use:

| Light | Meaning |
|---|---|
| Grey | Signed-in user |
| Amber | Alternate credentials set, not checked yet (no domain was filled in) |
| Green | Alternate credentials verified against the domain |

To start with credentials already set, run `.\gMSA-Creation-GUI.ps1 -Credential DOMAIN\admin`, which prompts for that account's password.

Credentials are held in memory only for the session. They are never written to disk or to the Console Log.

### Create gMSA tab

The tab walks through three steps.

**1 · Account details**

| Input | Purpose |
|---|---|
| Domain | Domain the account is created in, or a specific domain controller |
| gMSA name | Account name without the trailing `$`, up to 15 characters |
| Allowed principals | One per line: a server, service account, group, or gMSA, by name or distinguished name. These may retrieve the managed password |
| Advanced options | Optional unconstrained delegation (`TrustedForDelegation`), hidden by default and shown with a warning |

**2 · Review** checks the details against Active Directory without changing anything:

- Refuses a name that already exists in the domain.
- Resolves every allowed principal and lists it with its type.
- **Show PowerShell** shows the exact commands Create will run.

**3 · Create** is enabled only after a review of the current details. Editing any field means reviewing again. After a successful create, the new account opens in the Manage gMSA tab so SPNs can be added straight away.

The DNS host name is built as `<gMSA name>.<domain>`.

### Manage gMSA tab

For day-to-day changes to an existing gMSA.

1. Enter the domain and gMSA name, then select **Load gMSA**. The two tables show the current allowed principals and SPNs.
2. **Allowed principals**
   - To add: pick the object type (**Auto-detect**, **Server**, **Service Account**, **Group**, or **gMSA**), enter one name per line, and select **Add principals**.
   - To remove: select rows (Ctrl+click or Shift+click for several) and select **Remove selected**.
3. **SPNs**
   - To add: enter one SPN per line in the form `service/host[:port]` (for example `MSSQLSvc/sqlserver01a.domain.com:1433`) and select **Add SPNs**.
   - To remove: select rows and select **Remove selected**.

Every change asks for confirmation first and then reloads the tables. Changes always apply to the loaded account. Editing either field unloads it, so a typo can't redirect a change to another account.

Safeguards:

- An SPN already registered on another object in the domain is refused, since duplicate SPNs break Kerberos.
- The last allowed principal can't be removed. Add its replacement first.

### Console Log tab

Shows a timestamped log of every action, the commands that ran, and the full text of any error.

## Notes

- Each allowed principal must already exist in the domain. **Auto-detect** matches an exact account name first, then a computer with that name. If a service account and a server share a name, pick the type explicitly or use the distinguished name.
- The duplicate SPN check covers the gMSA's own domain only, not other domains in the forest.
- Managing SPNs needs write access to `servicePrincipalName` on the gMSA (Domain Admins, or delegated rights).
- Installing the account on the member servers (`Install-ADServiceAccount`) is a separate step and is not done by this tool.
