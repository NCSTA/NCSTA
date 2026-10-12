# gMSA Creation Utility

WPF GUI for creating group Managed Service Accounts (gMSA) and checking which servers are allowed to retrieve a gMSA's password.

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
| Allowed Servers | One computer name per line; these become the principals allowed to retrieve the managed password |
| Enable unconstrained delegation | Optional; sets `TrustedForDelegation` on the account after creation |

1. Fill in the inputs and select **Preview Command** to see the exact PowerShell that will run.
2. Select **Execute** to create the account. Execute stays disabled until a preview has been generated.
3. **Reset Form** clears the inputs.

The DNS host name is built as `<short name>.<domain>`.

### Managed Password Retrieval Lookup

Select **Run Lookup** to list the `PrincipalsAllowedToRetrieveManagedPassword` of an existing gMSA. The lookup uses the domain and gMSA short name entered in the inputs above.

### Console Log tab

Shows a timestamped log of every action and the full text of any error.

## Notes

- Each server in the allowed list must already exist as a computer object in the domain.
- Installing the account on the member servers (`Install-ADServiceAccount`) is a separate step and is not done by this tool.
