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

## Failure Logging

If any server fails at the Connect, Execute, or Copy stage, a `CollectionFailures_<timestamp>.csv` is written to the output path. The CSV is only created when at least one failure occurs.

## Files

| File | Purpose |
|---|---|
| `scripts\Start-CryptoCollection.ps1` | Management VM invoker - sessions, execution, ZIP retrieval |
| `scripts\CryptoInventory.ps1` | Target-side collection script pushed via PSRemoting |
