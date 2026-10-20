# CryptoInventory

Remotely collects cryptographic posture data from Windows servers via PowerShell Remoting (WinRM). Designed to run from a management VM against an array of target servers.

## What It Collects

Each target server produces a ZIP containing:

| File | Contents |
|---|---|
| `device.json` | Hostname, domain, OS, hardware, admin status |
| `certs.json` | Certificate inventory from LocalMachine stores |
| `schannel.json` | SChannel protocol/cipher configuration |
| `crypto_providers.json` | CSP/KSP providers, FIPS policy |
| `dpapi.json` | DPAPI provider posture (no secrets extracted) |
| `keys_and_stores.json` | Key storage metadata, SSH host keys, crypto artifact file counts |
| `protocols.json` | TLS, SSH, IPsec, SMB, RDP protocol settings |
| `algorithms.json` | Consolidated algorithm inventory across all protocols |
| `pqc_readiness.json` | Post-quantum readiness flags and weak crypto indicators |
| `summary.csv` | Flat per-certificate row for spreadsheet analysis |
| `runlog.txt` | Timestamped execution log |

## Prerequisites

- **Management VM**: PowerShell 5.1+, WinRM connectivity to targets
- **Target servers**: PowerShell 5.1+, WinRM enabled
- Running as an account with admin privileges on the target servers is recommended for full results

## Setup

1. Set the output path environment variable on the management VM:

   ```powershell
   $env:CRYPTO_OUTPUT_PATH = 'C:\CryptoResults'
   ```

2. Edit `scripts\Start-CryptoCollection.ps1` and populate the `$servers` array:

   ```powershell
   $servers = @(
       'server01.domain.com',
       'server02.domain.com',
   )
   ```

## Usage

```powershell
.\scripts\Start-CryptoCollection.ps1
```

The invoker connects to each server sequentially, pushes `CryptoInventory.ps1` via `Invoke-Command -FilePath`, then copies the resulting ZIP back to `$env:CRYPTO_OUTPUT_PATH`.

### Output structure

```
$env:CRYPTO_OUTPUT_PATH\
    CryptoInventory_SERVER01_20260303_120000.zip
    CryptoInventory_SERVER02_20260303_120015.zip
    CollectionFailures_20260303_120000.csv        # only if failures occurred
```

### Target server artifacts

The collection also leaves a copy on each target at:

```
C:\temp\CryptoInventory_<HOSTNAME>_<TIMESTAMP>\    # uncompressed folder
C:\temp\CryptoInventory_<HOSTNAME>_<TIMESTAMP>.zip  # ZIP
```

## Certificate Metadata Function

`scripts\Get-CertificateMetadata.ps1` is a standalone function for the PKI / Certificate Metadata data call. It returns one `PSCustomObject` per certificate instead of writing files, so you can pipe the results to `Select-Object`, `Format-Table` or `Export-Csv`.

```powershell
. .\scripts\Get-CertificateMetadata.ps1
$cred = Get-Credential

Get-CertificateMetadata -ComputerName web01, web02 -Credential $cred |
    Format-Table ComputerName, CommonName, PublicKeyAlgorithm, KeySize, SignatureAlgorithm, Expiration, Status, Services -AutoSize

# servers.csv columns: ComputerName, AssetId, Environment, Owner
Import-Csv .\servers.csv | Get-CertificateMetadata -Credential $cred |
    Export-Csv .\CertificateMetadata.csv -NoTypeInformation
```

| Parameter | Purpose |
|---|---|
| `-ComputerName` | Targets; accepts pipeline input. Defaults to the local machine |
| `-Credential` | Optional credential for WinRM |
| `-StoreName` | LocalMachine stores to read. Default `My`, `WebHosting`, `Remote Desktop`; add `Root`, `CA` for trust anchors |
| `-ExpiringDays` | Window for `ExpiringSoon` status (default 30) |
| `-VerifyChain` | Online chain and revocation check; sets `Revoked` / `Untrusted` |
| `-AssetId`, `-Environment`, `-Owner` | Stamped onto each result; can come from CSV columns |

Properties returned: `ComputerName`, `FQDN`, `IPAddress`, `CertificateStore`, `CommonName`, `SubjectAlternativeNames`, `Subject`, `IssuingCA`, `Issuer`, `SerialNumber`, `Thumbprint`, `PublicKeyAlgorithm`, `KeySize`, `Curve`, `SignatureAlgorithm`, `SignatureAlgorithmOid`, `ValidFrom`, `Expiration`, `DaysRemaining`, `Status`, `ChainStatus`, `Services`, `EnhancedKeyUsage`, `Template`, `FriendlyName`, `HasPrivateKey`, `AssetId`, `Environment`, `Owner`.

`Services` is built from HTTP.sys SSL bindings (IIS site names, WinRM HTTPS, SSTP), the RDP listener certificate and SQL Server's configured certificate. The function reads metadata only. It never reads private keys or key material, and `HasPrivateKey` is only a yes/no flag.

## Failure Logging

If any server fails at the Connect, Execute, or Copy stage, a `CollectionFailures_<timestamp>.csv` is written to the output path. The CSV is only created when at least one failure occurs.

## Files

| File | Purpose |
|---|---|
| `scripts\Start-CryptoCollection.ps1` | Management VM invoker - sessions, execution, ZIP retrieval |
| `scripts\CryptoInventory.ps1` | Target-side collection script pushed via PSRemoting |
| `scripts\Get-CertificateMetadata.ps1` | `Get-CertificateMetadata` function: one object per certificate over WinRM, optional `-Credential` |
