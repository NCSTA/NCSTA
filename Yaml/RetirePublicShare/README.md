# Retire Public Share — Migration Toolkit

## Purpose

Retires `G:\Public` by migrating all data to `G:\Archive\Public` while preserving the empty folder skeleton for 30 days. Users can still browse `G:\Public` to see folder paths, making it easy to request specific files from IT before final retirement.

## Prerequisites

- **Run as Administrator** with full NTFS permissions on both `G:\Public` and `G:\Archive`
- **Run in PowerShell ISE** — open the script in ISE and press `F5` (bypasses CarbonBlack script restrictions)
- **Clear all file locks** on `G:\Public` before running (share should be in read-only state)
- Enough free space on the `G:\Archive` volume (~600 GB)
- Windows Server with PowerShell 5.1+ and `robocopy.exe` (built-in)

## Quick Start

1. Open `Retire-PublicShare.ps1` in **PowerShell ISE**
2. Update the `$Script:Config` block at the top of the script (contact info, paths)
3. Run each phase in order:

```powershell
# Phase 0 — Scan and report baseline stats
.\Retire-PublicShare.ps1 -PreFlight

# Phase 1 — Recreate directory tree in archive (no files)
.\Retire-PublicShare.ps1 -MirrorStructure

# Phase 2 — Move all files, leave empty skeleton behind (has progress bar)
.\Retire-PublicShare.ps1 -MoveFiles

# Phase 3 — Drop _SHARE_RETIRED.txt notices in root + top-level folders
.\Retire-PublicShare.ps1 -DropNotices

# Phase 4 — Compare source vs archive, report discrepancies
.\Retire-PublicShare.ps1 -Validate

# Or run everything in sequence
.\Retire-PublicShare.ps1 -RunAll
```

## Phases

| Phase | Switch | What it does |
|-------|--------|-------------|
| 0 | `-PreFlight` | Validates paths, checks free space, counts files/folders, reports baseline |
| 1 | `-MirrorStructure` | Copies directory tree only (no files) from source to archive |
| 2 | `-MoveFiles` | Moves all files to archive; empty folders remain at source. **Progress bar included** |
| 3 | `-DropNotices` | Places `_SHARE_RETIRED.txt` in root and every top-level folder with contact info |
| 4 | `-Validate` | Compares file counts, reports any files that failed to move |

## Logging

All logs are written to `G:\Archive\Logs\RetirePublicShare\`:

- **Transcript** — full console output: `Transcript_<timestamp>.log`
- **Robocopy mirror log** — Phase 1 details: `RobocopyMirror_<timestamp>.log`
- **Robocopy move log** — Phase 2 details: `RobocopyMove_<timestamp>.log`
- **Validation report** — Phase 4 summary: `Validation_<timestamp>.log`

## Configuration

Edit the `$Script:Config` hashtable at the top of the script:

```powershell
$Script:Config = @{
    SourcePath     = 'G:\Public'                      # Source share
    ArchivePath    = 'G:\Archive\Public'               # Archive destination
    LogFolder      = 'G:\Archive\Logs\RetirePublicShare'
    NoticeFileName = '_SHARE_RETIRED.txt'
    ContactEmail   = 'IT@yourcompany.com'              # ← UPDATE
    ContactTeam    = 'IT Infrastructure'               # ← UPDATE
    TicketURL      = 'https://servicedesk.yourcompany.com'  # ← UPDATE
    GraceDays      = 30
}
```

## After Migration

- `G:\Public` will contain only the empty folder tree + notice files
- Users browse the skeleton to find paths, then contact IT to retrieve files from archive
- After 30 days with no requests, the server can be decommissioned

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| Robocopy exit code ≥ 8 | Check the robocopy log for `FAILED` entries — likely permissions or path length |
| Files remaining after move | Re-run `-MoveFiles` to retry; robocopy skips already-moved files |
| Long paths (>260 chars) | Robocopy handles these natively; no action needed |
| Script blocked by CB | Ensure you're running from **ISE script pane** (F5), not console |
