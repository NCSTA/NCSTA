# VMware → Hyper-V Migration Scripts

## Overview

Handles pre- and post-migration automation for Commvault-driven VMware-to-Hyper-V migrations.
Commvault moves the VM; these scripts handle everything Commvault does not:

| Task | Script |
|------|--------|
| Collect VMware NIC/route config pre-migration | `1_Collect-VMwareNetworkConfig.ps1` |
| Add vNICs, enable Secure Boot + Guest Services | `lib/Set-HyperVVMConfig.ps1` |
| Configure IPs/routes inside guest (no network required) | `lib/Set-GuestNetworking.ps1` |
| Orchestrate all post-migration steps | `2_Invoke-PostMigration.ps1` |
| Retrieve LAPS password for any domain | `lib/Get-LapsPassword.ps1` |

---

## Architecture

```
Management Server
├── Queries SCVMM          → finds which Hyper-V host each VM landed on
├── Queries AD (LAPS)      → gets local admin credential per domain
└── Invoke-Command ──────→ Hyper-V Host
                               ├── Set-HyperVVMConfig (NIC add, SecureBoot, GuestSvc)
                               └── Invoke-Command -VMName ─→ Guest VM (PowerShell Direct / VMBus)
                                                               └── Set-GuestNetworking
```

**Why PowerShell Direct?**
Migrated VMs have no network until this script runs. PowerShell Direct communicates
over the Hyper-V VMBus — the host is the transport, not TCP/IP. It requires local
credentials (hence LAPS) because domain auth cannot reach a DC without network.

---

## Prerequisites

### Management Server
- `VirtualMachineManager` module — SCVMM console/PowerShell
- `VMware.PowerCLI` — for the pre-migration collector only
- PS Remoting enabled to all Hyper-V hosts
- AD read rights with `ExtendedRight` on `ms-Mcs-AdmPwd` for all target domains

### Hyper-V Hosts
- Windows Server 2016+ (PowerShell Direct requirement)
- `RSAT-AD-PowerShell` — LAPS is queried here, not on the management server
- Running account must have `ExtendedRight` read on `ms-Mcs-AdmPwd` in all target domains
- PS Remoting enabled (WinRM) inbound from management server
- Correct vSwitch names matching VMware portgroup names (like-for-like)

### Guest VMs
- Windows Server 2019–2025
- Hyper-V Integration Services present (Commvault typically preserves these)
- Local Administrator account active (LAPS manages this)

---

## File Structure

```
.
├── README.md                            ← You are here
├── 1_Collect-VMwareNetworkConfig.ps1    ← Step 1: Run before migration
├── 2_Invoke-PostMigration.ps1           ← Step 2: Run after Commvault restore
├── lib/
│   ├── Get-LapsPassword.ps1             ← Helper: LAPS credential by FQDN
│   ├── Set-HyperVVMConfig.ps1           ← Helper: Runs ON the Hyper-V host
│   └── Set-GuestNetworking.ps1          ← Helper: Injected into guest via PSdirect
└── data/
    ├── vm_input_list.txt                ← Input: one FQDN per line
    ├── migration_servers.csv            ← State: NIC config + migration status
    └── migration_routes.csv             ← State: custom back-interface routes
```

---

## Step-by-Step Usage

### Step 1 — Pre-Migration Data Collection (VMware side)

Add target server FQDNs to `data/vm_input_list.txt`, one per line:
```
server01.corp.contoso.com
server02.dmz.contoso.com
```

Run the collector:
```powershell
.\1_Collect-VMwareNetworkConfig.ps1 `
    -vCenter        "vcenter.corp.contoso.com" `
    -FrontPGPattern "Front*" `
    -BackPGPattern  "Back*"
```

Outputs:
- `data/migration_servers.csv` — NIC config for each server, Status = `Pending`
- `data/migration_routes.csv` — custom routes per server

> **Before running:** Add your route collection function to the `USER-DEFINED ROUTE COLLECTION BLOCK`
> in `1_Collect-VMwareNetworkConfig.ps1`.

---

### Step 2 — Commvault Restore

Perform the restore via Commvault as normal. VMs will come up on Hyper-V with:
- Incorrect/missing vNICs (no network)
- Secure Boot may be off
- Guest Services may need enabling

Do **not** power on and attempt manual network config — let the orchestrator handle it.

---

### Step 3 — Post-Migration Orchestration (Hyper-V side)

Process all pending servers:
```powershell
.\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com"
```

Process a single server:
```powershell
.\2_Invoke-PostMigration.ps1 -SCVMMServer "scvmm.corp.contoso.com" -FQDN "server01.corp.contoso.com"
```

The orchestrator is **resume-safe** — it writes status after each step. If a server
fails at step 3, re-running will skip completed servers and retry only `Pending` ones.

#### Status lifecycle

| Status | Meaning |
|--------|---------|
| `Pending` | Not yet processed |
| `InProgress` | Started; killed mid-run |
| `NICsAdded` | Hyper-V hardware configured; guest net not yet done |
| `Complete` | All steps finished successfully |
| `Failed` | Error — see Notes column for detail |

---

## Multi-Domain LAPS

LAPS is queried per-server by splitting the FQDN:
```
server01.corp.contoso.com  →  serverName=server01, domain=corp.contoso.com
server02.dmz.fabrikam.com  →  serverName=server02, domain=dmz.fabrikam.com
```

The domain portion is passed as `-Server` to `Get-ADComputer`, targeting the correct DC automatically.
No configuration needed — just provide FQDNs.

---

## Completing the Stubs

Two empty blocks require your custom functions:

**1. Route collection (pre-migration, VMware side)**
File: `1_Collect-VMwareNetworkConfig.ps1`
Search: `USER-DEFINED ROUTE COLLECTION BLOCK`
Populate `$customRoutes` as `@{ Destination; PrefixLength; NextHop }[]`

**2. Route application (post-migration, inside guest)**
File: `lib/Set-GuestNetworking.ps1`
Search: `USER-DEFINED ROUTE BLOCK`
`$Routes` is already available as `hashtable[]`; the Back adapter is already renamed to `'Back'`

---

## Claude's Directory

*This section is for Claude Code to understand the codebase without parsing all files.*

### Key functions

| Function | File | Purpose |
|----------|------|---------|
| `Get-LapsPassword` | `lib/Get-LapsPassword.ps1` | Input: FQDN → Output: PSCredential (local admin). Splits FQDN to target correct domain. Legacy LAPS only (`ms-Mcs-AdmPwd`). |
| `Set-HyperVVMConfig` | `lib/Set-HyperVVMConfig.ps1` | Runs on Hyper-V host. Removes old NICs, adds Front+Back, sets VLAN, enables Secure Boot + Guest Services. Returns `@{FrontMAC; BackMAC}`. |
| Guest net script | `lib/Set-GuestNetworking.ps1` | Not a function — loaded as ScriptBlock and injected via PSdirect. Params: `$FrontNIC`, `$BackNIC`, `$Routes` (hashtables). Identifies adapters by MAC. Renames to Front/Back. |
| Main orchestrator | `2_Invoke-PostMigration.ps1` | Reads CSVs, loops pending servers. SCVMM → find host. `Invoke-Command` → HV host → `Set-HyperVVMConfig`. `Invoke-Command` → HV host → `Invoke-Command -VMName` (PSdirect) → guest. Writes status per step. |
| Pre-migration collector | `1_Collect-VMwareNetworkConfig.ps1` | PowerCLI. Matches NICs by portgroup name pattern. Invokes `Invoke-VMScript` for guest IP/DNS. Route stub. Writes both CSVs. |

### Data flow

```
vm_input_list.txt
      ↓ [1_Collect-VMwareNetworkConfig.ps1 + PowerCLI]
migration_servers.csv  (Status=Pending)
migration_routes.csv
      ↓ [Commvault restore — manual step]
      ↓ [2_Invoke-PostMigration.ps1]
migration_servers.csv  (Status=Complete|Failed + HyperVHost filled in)
```

### Critical design decisions

- **MAC-based NIC identification in guest:** Hyper-V synthetic adapter descriptions are not unique inside the guest. MACs from `Get-VMNetworkAdapter` on the host are passed into the guest script and matched via `Get-NetAdapter`.
- **LAPS queried on the Hyper-V host, not the management server:** `PSCredential` deserialized through `Invoke-Command -ArgumentList` arrives as `Deserialized.PSCredential`, which `Invoke-Command -VMName -Credential` rejects (strictly typed). Avoiding serialization entirely by querying LAPS locally on the HV host means PSdirect receives a native `PSCredential` with no type mismatch. `Get-LapsPassword.ps1` is passed as a raw string and dot-sourced inside the remote session.
- **Double Invoke-Command for PSdirect:** PSdirect (`-VMName`) only works from the Hyper-V host, not from a remote management server. The orchestrator remotes into the host first, then runs PSdirect from there. Only data (hashtables, strings) crosses the outer hop — no credentials.
- **SCVMM for host discovery, direct Hyper-V for execution:** SCVMM tells us where the VM landed; all actual Hyper-V operations run via the Hyper-V host's native cmdlets.
- **CSV as state store:** `Status` column is updated after each step, making the orchestrator safe to re-run after partial failures without reprocessing completed servers.
- **LAPS queried at runtime, not stored in CSV:** Passwords rotate; pulling at execution time ensures the credential is current.
