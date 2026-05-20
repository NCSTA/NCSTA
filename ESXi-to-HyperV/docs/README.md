# ESXi to Hyper-V Migration Toolkit Docs

This folder documents how the migration helper scripts flow and where the major
logic lives.

## Files

- `Script1-PreMigration-Flow.md` explains VMware/vCenter collection, guest
  remoting, NIC classification, JSON output, and logging.
- `Script2-PostMigration-Flow.md` explains SCVMM lookup, Hyper-V adapter
  updates, PowerShell Direct, guest NIC configuration, and summary output.
- `CodeMap.md` is a quick lookup map for important functions and concepts.

## Current Script Entry Points

- `Collect-VMwareMigrationData.ps1`
- `Configure-HyperVMigrationNic.ps1`

The scripts remain full `.ps1` entry points. The markdown files are reference
material only.
