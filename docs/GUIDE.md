# oxyde-win-maintenance — Guide

Windows maintenance toolkit: read-only scanners (probes) produce a report of
criticalities; a guarded action layer can fix selected items with dry-run,
confirmation, transcript and verification.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built into Windows)
- Optional: `winget` (App Installer) for the Winget probe
- Internet access for the report's CDN assets (Bootstrap, jQuery, DataTables,
  Chart.js, Inter font)

No installation needed: copy the `oxyde-win-maintenance` folder anywhere and run it.

## Quick start

```powershell
# Scan and open the HTML report
.\PcScan.ps1 -Open

# Or without changing the execution policy for the session
powershell -NoProfile -ExecutionPolicy Bypass -File .\PcScan.ps1 -Open
```

GUI: double-click `Start-Console.cmd` (or run `.\PcConsole.ps1`).

## Running on another PC (no install)

oxyde-win-maintenance is portable: copy the whole `oxyde-win-maintenance` folder (you can exclude `out\`)
to any Windows 10/11 machine and run it there. Requirements:

- Windows PowerShell 5.1 (built into Windows);
- internet access for the report's CDN assets (styles/charts);
- optional: `winget` for the Winget probe.

No administrator rights are needed for scanning. The GUI requests elevation
only when applying actions that need it (a single UAC prompt per batch).

Possible future packaging options (not implemented yet): a zip release with
the launcher, a PowerShell module, or a Start Menu shortcut created by a
small bootstrap script.

## Commands

| Command | Purpose |
|---|---|
| `PcScan.ps1` | Scan: runs the probes, writes `out\scan_<ts>.json` + `.html` (+ `scan_latest.*`) |
| `PcPlan.ps1` | Builds `out\plan_<ts>.json` (+ `plan_latest.json`) with candidate actions from the last scan |
| `PcApply.ps1` | Dry-run / apply the plan with per-action confirmation, one UAC per batch, post-apply re-scan + diff |
| `PcConsole.ps1` | WinForms GUI: Scan / Findings / Actions / Log tabs |

### PcScan options

| Option | Default | Description |
|---|---|---|
| `-Areas` | all | Comma-separated area filter (case-insensitive) |
| `-OutDir` | `out` | Output directory |
| `-TimeoutSeconds` | 300 | Per-probe timeout |
| `-NoHtml` | off | Skip the HTML render, JSON only |
| `-Open` | off | Open the HTML report when done |

### PcApply options

| Option | Description |
|---|---|
| `-Plan <file>` | Plan file (default `out\plan_latest.json`) |
| `-Apply` | Actually execute (default is dry-run) |
| `-Yes` | Skip per-action prompts (unattended) |
| `-Only id,kind` | Restrict to actions by id or kind |
| `-SkipRestorePoint` | Exclude the restore point safety step |
| `-NoVerify` | Skip the post-apply re-scan and diff |
| `-NoElevate` | Never relaunch elevated; admin actions end as `denied` |

## Actions (Phase 2)

Workflow: **scan → plan → apply**.

```powershell
.\PcScan.ps1                     # 1. find criticalities (read-only)
.\PcPlan.ps1                     # 2. candidate actions -> out\plan_latest.json
.\PcApply.ps1                    # 3. dry run: shows every exact command
.\PcApply.ps1 -Apply             # 4. interactive apply, one UAC per batch
```

Safety rails (see DECISIONS.md D7/D8 and ROADMAP.md):

- dry-run by default; the apply mode must be requested explicitly;
- only catalog actions run (`actions\NN-kind.ps1`), never arbitrary commands;
- per-action confirmation in the CLI (`y` apply, `n` skip, `s` skip all);
- at most one elevation prompt per batch (self-relaunch via `-Verb RunAs`);
- undo artifacts are exported to `out\undo\` when possible;
- after applying, the affected areas are re-scanned and the before/after
  diff is written to `out\apply_<ts>.json` (transcript in `.log`).

First capability: **create restore point** (`actions\10-restorepoint.ps1`) —
handles the Windows 24h throttle (`throttled`, not a failure) and enables
System Protection when it is disabled. The GUI performs the same flow with
per-action checkboxes, a dry-run preview and a single confirmed elevated
batch.

## Areas and probes

| Area | Probe file | Checks | Elevation |
|---|---|---|---|
| WindowsUpdate | `probes\10-WindowsUpdate.ps1` | Pending updates + last hotfix | no |
| Apps | `probes\20-Apps.ps1` | Installed apps, broken uninstall entries | no |
| Winget | `probes\21-Winget.ps1` | Available package upgrades | no |
| Appx | `probes\22-Appx.ps1` | AppX/MSIX packages (current user) | no |
| OrphanServices | `probes\40-OrphanServices.ps1` | Services pointing to missing files | partial |
| SystemProtection | `probes\50-SystemProtection.ps1` | System Protection state, restore point age | partial |

## Report

- `out\scan_<timestamp>.json`: full machine-readable report (schema v4) with
  `host` (CPU, RAM, BIOS, OS dates, uptime, fixed disks), `probes` (run
  status/duration), `findings` (optionally with `actionKind`/`actionPayload`)
  and `datasets`.
- `out\scan_<timestamp>.html`: self-contained HTML report with:
  - sidebar navigation with per-area/table links and active-section highlight;
  - dark/light theme toggle (persisted, follows the OS preference by default);
  - gradient hero with verdict pill, KPI cards with explanatory tooltips;
  - Chart.js charts (findings by status and by area);
  - a priority-actions panel, per-area findings with filters/search;
  - an extended System card (CPU, cores/threads, RAM, BIOS, OS install date,
    last boot, uptime, disk free-space bars);
  - searchable data tables (DataTables).

Findings use four statuses: `CRIT` (urgent), `WARN` (action advised),
`INFO` (context) and `OK` (checked, nothing found).

## Architecture

```
oxyde-win-maintenance\
├─ PcScan.ps1              entry: scan (read-only)
├─ PcPlan.ps1              entry: scan report → action plan
├─ PcApply.ps1             entry: dry-run / apply / verify (CLI, interactive)
├─ PcConsole.ps1           entry: WinForms GUI
├─ probes\NN-Area.ps1      detection plugins (read-only)
├─ actions\NN-kind.ps1     action handlers (one capability each)
├─ lib\Common.psm1         shared contracts (findings, action results) and helpers
├─ render\Report-Html.ps1  HTML renderer
├─ docs\                   GUIDE.md, DECISIONS.md, ROADMAP.md
└─ out\                    reports, plans, apply results, transcripts, undo\
```

### Adding a probe

1. Create `probes\NN-Area.ps1` with parameters `-OutFile` (mandatory).
2. Import the shared module:
   `Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force`
3. Build findings with `New-Finding`; if the finding is remediable, add
   `-ActionKind` (and optional `-ActionPayload`). Emit with:
   `Write-ProbeResult -Findings $findings -Datasets @{ name = $rows } -OutFile $OutFile`
4. Run `.\PcScan.ps1 -Areas <Area>` to test it.

The engine discovers probes by filename pattern `NN-Area.ps1`, runs each in a
child process (isolated, with timeout) and merges the results.

### Adding an action

1. Create `actions\NN-kind.ps1` with parameters `-Mode dryrun|apply|verify`,
   `-ActionFile` (one plan action as JSON) and `-OutFile` (result JSON).
2. Build the exact command string once and return it in dry-run mode.
3. Return results with `New-ActionResult` + `Write-ActionResult` (contract in
   docs\ROADMAP.md). Export undo artifacts to `out\undo\` when possible.
4. Findings carrying `-ActionKind '<kind>'` will now produce plan actions.

## Safety and privacy

- Probes are read-only (DECISIONS.md D3). Actions run only from the catalog,
  dry-run first, with confirmation and transcripts (D7/D8).
- Everything runs locally; no data leaves the machine.
- Reports may contain machine inventory (installed apps, services); treat the
  `out\` folder as local data.

## Roadmap

See `docs\ROADMAP.md` for the phase plan and the status of upcoming
capabilities (winget upgrades, orphan service removal, app uninstall, REA
integration).
