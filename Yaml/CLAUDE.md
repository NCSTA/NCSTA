# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

An infrastructure-automation monorepo for a Windows Server / Hyper-V environment. Three independent projects live here:

1. **VMware → Hyper-V migration toolkit** (root `1_*.ps1`, `2_*.ps1`, `lib/`, `data/`) — PowerShell scripts that automate pre- and post-migration steps around Commvault-driven VM migrations.
2. **MigrateOps YAML configs** (`DefaultYAML.yaml`, `Template.yaml`) — Cirrus Data Solutions `MIGRATEOPS_HYPERV_COMPUTE` recipe definitions for H2H migrations.
3. **VMFCaller** (`VMFCaller/`) — World of Warcraft addon (Lua) for a raid memory game; unrelated to infra work.
4. **RetirePublicShare** (`RetirePublicShare/`) — PowerShell toolkit for retiring a public file share with phased migration and grace period.

## Architecture — Migration toolkit

The migration scripts solve a specific problem: after Commvault restores a VMware VM onto Hyper-V, the guest has **no network**. PowerShell Direct (VMBus) is the only way in.

```
Management Server
 └─ 2_Invoke-PostMigration.ps1
      ├── SCVMM → find which HV host the VM landed on
      └── Invoke-Command → HV Host
            ├── Set-HyperVVMConfig (remove old NICs, add NIC1+NIC2, SecureBoot, GuestSvc)
            └── Get-LapsPassword (queried HERE, not mgmt server — avoids PSCredential deserialization bug)
                 └── Invoke-Command -VMName (PowerShell Direct / VMBus) → Guest
                      └── Set-GuestNetworking (MAC-match NICs, set IPs, DNS, routes)
```

### Why LAPS is queried on the HV host, not the management server

`PSCredential` passed through `Invoke-Command -ArgumentList` deserializes as `Deserialized.PSCredential`, which `Invoke-Command -VMName -Credential` rejects (strict type check). By querying LAPS locally on the HV host, `PSdirect` receives a native `PSCredential`. The `Get-LapsPassword.ps1` source is passed as a raw string and dot-sourced inside the remote session.

### NIC identification in the guest

Hyper-V synthetic adapter descriptions are identical inside the guest. The scripts pass MAC addresses from `Get-VMNetworkAdapter` on the host into the guest and match via `Get-NetAdapter`.

### Portgroup-to-IP matching (pre-migration collector)

VMware portgroup names **are the subnet address** (e.g. `192.168.1.0`). The collector derives the network address from each guest adapter's IP+prefix and matches against the portgroup name — no manual mapping needed.

### CSV as state store

`migration_servers.csv` tracks status per server (`Pending` → `InProgress` → `NICsAdded` → `Complete` | `Failed`). The orchestrator is resume-safe: re-running skips completed servers.

## Running the scripts

### Pre-migration (VMware side — VMs still have network)
```powershell
.\1_Collect-VMwareNetworkConfig.ps1 -vCenter "vcenter.corp.contoso.com"
```
Input: `data/vm_input_list.txt` (one FQDN per line). Outputs: `data/migration_servers.csv`, `data/migration_routes.csv`.

### Post-migration (Hyper-V side — after Commvault restore)
```powershell
# All pending servers
.\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com"

# Single server
.\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com" -FQDN "server01.corp.contoso.com"
```

### RetirePublicShare (run in PowerShell ISE — F5)
```powershell
.\RetirePublicShare\Retire-PublicShare.ps1 -PreFlight
.\RetirePublicShare\Retire-PublicShare.ps1 -RunAll
```

## Stubs that need user code

Two blocks are left empty for environment-specific logic:

1. **Route collection** — `1_Collect-VMwareNetworkConfig.ps1`, search `USER-DEFINED ROUTE COLLECTION BLOCK`. Populate `$customRoutes` as `@{ Destination; PrefixLength; NextHop }[]`.
2. **Route application** — `lib/Set-GuestNetworking.ps1`, search `USER-DEFINED ROUTE BLOCK`. `$Routes` is already available; NIC2 is already renamed.

## MigrateOps YAML

`Template.yaml` is the user-facing template with `<< FILL IN >>` placeholders. `DefaultYAML.yaml` is a completed example. Recipe is always `MIGRATEOPS_HYPERV_COMPUTE`. Cutover scripts (VMware Tools removal + backend route addition) are embedded in the YAML and should not be modified without the migration team.

## Conventions

- **PowerShell 5.1** target — no PS 7+ syntax. Scripts may run on Server 2016+.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in all scripts.
- Lib scripts are loaded as raw strings (`Get-Content -Raw`) and injected via `[ScriptBlock]::Create()` into remote sessions — they must be self-contained (no dot-source dependencies).
- FQDN is the universal key: `server.domain.tld` splits into hostname + domain for LAPS, SCVMM lookup, etc.
- Legacy LAPS only (`ms-Mcs-AdmPwd` attribute), not Windows LAPS.
