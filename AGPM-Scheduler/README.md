# AGPM Deployment Scheduler

PowerShell 5.1 tooling for scheduling the deployment of already checked-in
Advanced Group Policy Management (AGPM) GPOs. It deliberately does not create,
edit, check out, check in, import, link, or delete GPOs.

## Safety model

When a deployment is scheduled, the job records the domain, GPO GUID, AGPM
`BackupID`, and user/computer versions. At execution time the runner retrieves a
fresh AGPM object and refuses to publish it if:

- the GPO cannot be found by GUID;
- the GPO is no longer `CHECKED_IN`;
- its `BackupID` changed;
- its user or computer version changed.

Live deployments are verified against the production GPO's AD versions using
the `GroupPolicy` module. Verification is retried to accommodate domain
controller replication visibility. Multiple GPOs are processed sequentially
and recorded individually.

## Requirements

- Windows PowerShell 5.1
- AGPM Client and the `Microsoft.Agpm` module
- GPMC/RSAT and the `GroupPolicy` module
- An identity with the required AGPM deployment permissions
- Connectivity to the configured domains and AGPM service

Run the GUI and scheduled task under an appropriately controlled Tier 0
automation identity. Do not embed credentials in the configuration.

## Initial setup

1. Copy `config\AgpmScheduler.config.example.json` to
   `config\AgpmScheduler.config.json`.
2. Configure the data path and domain list.
3. Leave `Runner.WhatIf` set to `true` so new jobs default to test mode.
4. Start the GUI:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned `
     -File .\Start-AgpmScheduler.ps1
   ```

5. Schedule a test job, then invoke the runner manually:

   ```powershell
   .\scripts\Invoke-AgpmDeploymentRunner.ps1
   ```

6. Review the completed job JSON and JSONL audit log under the configured
   `DataRoot`.
7. Test mode can be selected per job in the GUI. Switching a job to live mode
   requires an additional confirmation.

## Scheduled task

Register the permanent polling task from an elevated Windows PowerShell 5.1
session. For a gMSA:

```powershell
.\scripts\Register-AgpmSchedulerTask.ps1 `
  -RunAsAccount 'DOMAIN\agpm-runner$' `
  -UseGmsa
```

For a conventional service account, omit `-UseGmsa`; the registration script
will request its credential interactively.

The runner uses a named mutex to prevent overlapping executions. Each due job
is moved atomically from `Pending` to `Running` before processing.

## Email

The first version supports an internal SMTP relay through the `Email` section
of the configuration. When email is disabled or fails, deployment processing
continues and the failure is written to the audit log.

## Queue layout

The runner creates the following below `Paths.DataRoot`:

```text
Queue\
  Pending\
  Running\
  Completed\
  Failed\
  Cancelled\
Logs\
```

Treat the data root as Tier 0 data. Limit write access to scheduling operators
and the runner identity, and grant read access only to appropriate auditors.
