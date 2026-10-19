# NCSTA

PowerShell tooling and Splunk searches for Windows infrastructure administration, organized by area. Each project folder has its own README covering requirements, usage and output.

## Categories

| Category | Contents |
|---|---|
| [ActiveDirectory](ActiveDirectory/README.md) | Accounts, groups, Group Policy and AD reporting |
| [Compliance](Compliance/README.md) | Auditing, hardening and vulnerability-scan tooling |
| [DNS](DNS/README.md) | DNS management |
| [Hypervisor](Hypervisor/README.md) | Hyper-V, SCVMM and VMware to Hyper-V migration |
| [Splunk](Splunk/README.md) | Template Splunk searches |
| [Tools](Tools/README.md) | General server and file share administration |
| [VMware](VMware/README.md) | vSphere inventory, templates and VM maintenance |

## Projects

### ActiveDirectory

| Project | Description |
|---|---|
| [AD-Server-Report](ActiveDirectory/AD-Server-Report/README.md) | Exports enabled Windows Server computer accounts from multiple domains to Excel and HTML |
| [AGPM-Scheduler](ActiveDirectory/AGPM-Scheduler/README.md) | Schedules the deployment of already checked-in AGPM GPOs |
| [gMSA-GUI](ActiveDirectory/gMSA-GUI/README.md) | GUI for creating group Managed Service Accounts |
| [Group-Owners](ActiveDirectory/Group-Owners/README.md) | Fills in access group owners in a CSV from AD membership |
| [Keytab-Generator](ActiveDirectory/Keytab-Generator/README.md) | GUI around `ktpass` for generating Kerberos keytabs |

### Compliance

| Project | Description |
|---|---|
| [Crypto-Inventory](Compliance/Crypto-Inventory/README.md) | Remotely collects cryptographic posture data from Windows servers |
| [Nessus-Merge](Compliance/Nessus-Merge/README.md) | Merges Nessus scan exports into master workbooks per zone and role |
| [Resolve-SID](Compliance/Resolve-SID/README.md) | Tells orphaned SIDs apart from SIDs of unreachable domains |
| [Server-Protocol-Audit](Compliance/Server-Protocol-Audit/README.md) | Read-only check of SSL/TLS protocol status and cipher-suite order |
| [Server-QA-Checker](Compliance/Server-QA-Checker/README.md) | Validates Windows server build state against JSON templates |
| [Windows-Audit](Compliance/Windows-Audit/README.md) | Modular Windows configuration audit with auditor-compatible reports |

### DNS

| Project | Description |
|---|---|
| [BlueCat-DNS-Manager](DNS/BlueCat-DNS-Manager/README.md) | GUI for managing DNS records through the BlueCat Address Manager API |

### Hypervisor

| Project | Description |
|---|---|
| [Commvault-HyperV-PostMigration](Hypervisor/Commvault-HyperV-PostMigration/README.md) | Pre- and post-migration automation for Commvault VMware to Hyper-V migrations |
| [ESXi-to-HyperV](Hypervisor/ESXi-to-HyperV/README.md) | Carries a VM's network identity across an ESXi to Hyper-V migration |
| [SCVMM-V2V-HighAvailability](Hypervisor/SCVMM-V2V-HighAvailability/README.md) | SCVMM V2V conversion of a single VM with high availability |

### Splunk

| Project | Description |
|---|---|
| [LDAP-DC-Failures](Splunk/LDAP-DC-Failures/README.md) | LDAP bind, signing, channel binding and LDAPS TLS failures on DCs |

### Tools

| Project | Description |
|---|---|
| [Archive-Files](Tools/Archive-Files/README.md) | Moves listed files into a mirrored archive tree, with restore scripts |
| [Retire-Public-Share](Tools/Retire-Public-Share/README.md) | Retires a public share by moving its data to an archive |
| [Server-Retirement](Tools/Server-Retirement/README.md) | Dependency audit for Windows server retirement |

### VMware

| Project | Description |
|---|---|
| [Template-Patching](VMware/Template-Patching/README.md) | Monthly template patch cycle and orphaned template scan |
| [VM-Hardware-Tools-Upgrade](VMware/VM-Hardware-Tools-Upgrade/README.md) | VM hardware version staging and VMware Tools reporting |
| [VM-Location-Report](VMware/VM-Location-Report/README.md) | Report of Windows Server VM placement and host core counts |

## Conventions

- Every project lives in exactly one category folder and has a `README.md`.
- Folder names use `Pascal-Case-With-Hyphens`.
- Hostnames, domains, IP addresses and credentials in this repository are placeholders. Replace them with your own values before running a script.
