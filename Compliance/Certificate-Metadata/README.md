# Certificate-Metadata

Collects PKI / certificate metadata from Windows servers over PowerShell Remoting (WinRM). `Get-CertificateMetadata` returns one `PSCustomObject` per certificate, so results can be piped to `Select-Object`, `Format-Table`, `Out-GridView` or `Export-Csv`.

Written for the PKI / Certificate Metadata data call. The function reads metadata only. It never reads private keys, passwords or other key material, and `HasPrivateKey` is only a yes/no flag.

## Requirements

- Windows PowerShell 5.1 or later on the management machine and the targets
- WinRM enabled on the targets
- An account with admin rights on the targets is recommended, so that all bindings and stores can be read

## Usage

Load the function by dot-sourcing the file:

```powershell
. .\Get-CertificateMetadata.ps1
```

Query servers, with or without a credential:

```powershell
$cred = Get-Credential

Get-CertificateMetadata -ComputerName web01, web02 -Credential $cred |
    Format-Table ComputerName, CommonName, PublicKeyAlgorithm, KeySize, Curve, SignatureAlgorithm, Expiration, Status, Services -AutoSize
```

Use a CSV to supply asset details, which can't be read from the server itself. Columns: `ComputerName`, `AssetId`, `Environment`, `Owner`.

```powershell
Import-Csv .\servers.csv | Get-CertificateMetadata -Credential $cred |
    Export-Csv .\CertificateMetadata.csv -NoTypeInformation
```

Include trust stores and run an online chain/revocation check:

```powershell
Get-CertificateMetadata -ComputerName app01 -StoreName My, Root, CA -VerifyChain |
    Where-Object Status -ne 'Valid'
```

## Parameters

| Parameter | Purpose |
|---|---|
| `-ComputerName` | Targets; accepts pipeline input. Defaults to the local machine |
| `-Credential` | Optional credential for WinRM. Without it, the current identity is used |
| `-StoreName` | LocalMachine stores to read. Default `My`, `WebHosting`, `Remote Desktop` |
| `-ExpiringDays` | Window for the `ExpiringSoon` status (default 30) |
| `-VerifyChain` | Online chain and revocation check; can set `Revoked` / `Untrusted` |
| `-AssetId`, `-Environment`, `-Owner` | Stamped onto each result; can come from CSV columns |
| `-ThrottleLimit` | Maximum concurrent remote connections (default 32) |

Unreachable servers produce a warning and do not stop the run.

## Output

| Data call item | Properties |
|---|---|
| Common name and SANs | `CommonName`, `SubjectAlternativeNames`, `Subject` |
| Serial number and issuing CA | `SerialNumber`, `IssuingCA`, `Issuer` |
| Public-key algorithm and key size/curve | `PublicKeyAlgorithm`, `KeySize`, `Curve` |
| Signature algorithm | `SignatureAlgorithm`, `SignatureAlgorithmOid` |
| Valid-from and expiration | `ValidFrom`, `Expiration`, `DaysRemaining` |
| Certificate status | `Status` (Valid, ExpiringSoon, Expired, NotYetValid, Revoked, Untrusted), `ChainStatus` |
| Hostname, IP, store | `ComputerName`, `FQDN`, `IPAddress`, `CertificateStore` |
| Application/service | `Services` |
| Asset/CI, environment, owner | `AssetId`, `Environment`, `Owner` |
| Extra | `Thumbprint`, `EnhancedKeyUsage`, `Template`, `FriendlyName`, `HasPrivateKey` |

`Services` is built from HTTP.sys SSL bindings (IIS site names, WinRM HTTPS, SSTP), the RDP listener certificate and SQL Server's configured certificate. The binding lookup reads the output of `netsh http show sslcert`, which assumes English-language Windows.

## Files

| File | Purpose |
|---|---|
| `Get-CertificateMetadata.ps1` | `Get-CertificateMetadata` function |
