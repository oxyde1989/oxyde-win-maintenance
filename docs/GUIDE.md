# oxyde-win-maintenance — Guide

Windows maintenance toolkit: read-only scanners (probes) produce a report of
criticalities and a health verdict; a guarded action layer can fix selected
items with dry-run, confirmation, transcript and verification.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 (built into Windows)
- Optional: `winget` (App Installer) for the Winget probe
- No internet needed for scanning and reading the report (assets are vendored
  in `assets\`). Network-dependent data (Windows Update, winget) is labelled
  "Requires network" in the report.

No installation needed: copy the `oxyde-win-maintenance` folder anywhere and run it.

## Quick start

```powershell
# Fast health check (<10 s): verdict + score, opens the HTML report
.\PcScan.ps1 -Profile quick -Open

# Full picture (Windows Update search, winget, drivers)
.\PcScan.ps1 -Profile standard -Open

# Or without changing the execution policy for the session
powershell -NoProfile -ExecutionPolicy Bypass -File .\PcScan.ps1 -Profile quick -Open
```

GUI: double-click `Start-Console.cmd` (or run `.\PcConsole.ps1`): the primary
"Run health check" button shows a colored verdict banner (score, counts,
profile, top issue); "Run scan (standard)" runs the full scan and
"Deep scan (admin)" requests a single UAC prompt.

## Scan profiles and health verdict

Profiles are declared in `profiles.psd1` (areas, per-area timeouts, network
labels, elevation):

| Profile | Areas | Notes |
|---|---|---|
| `quick` (default) | Integrity (CBS read), EventLog, Space, Security (Defender + AV residue), WindowsUpdate (service state + last hotfix, no COM search), PendingReboot, OrphanServices | <10 s; the real health-check picture (shutdowns, integrity history, space, Defender) |
| `standard` | all probes, including the Windows Update search, winget, drivers and the firewall profiles | ~30 s |
| `deep` | standard, elevated (one UAC, declared in the report as `adminUsed`), adds the DISM /ScanHealth + sfc /verifyonly integrity run | requires elevation: without it the report carries an explicit notice |

`PcScan.ps1` writes a health block in the report
(`health.score`, `health.verdict` = `OK`/`WARNING`/`CRITICAL`, counts, top
issues, `coverage`) and sets the **exit code** accordingly: `0` OK,
`1` WARNING, `2` CRITICAL — usable from scripts. Score:
`100 - 25*CRIT - 8*WARN` (clamped), where roll-up "summary" findings are
excluded so a single issue is not counted twice (D18).

**Coverage:** `health.coverage` records which areas ran, which were skipped
(profile or `-Areas` filter), the network-dependent areas and the elevation
state; when something was skipped the verdict is labelled `(partial)` in the
report and the GUI banner — a partial verdict is never presented as complete.

## Running on another PC (no install)

oxyde-win-maintenance is portable: copy the whole `oxyde-win-maintenance` folder (you can exclude `out\`)
to any Windows 10/11 machine and run it there. Requirements:

- Windows PowerShell 5.1 (built into Windows);
- optional: `winget` for the Winget probe.

The report renders offline (vendored assets in `assets\`; a minimal inline
style is used if they are missing). No administrator rights are needed for
scanning. The GUI requests elevation only for the deep scan and when applying
actions that need it (a single UAC prompt per batch).

Possible future packaging options (not implemented yet): a zip release with
the launcher, a PowerShell module, or a Start Menu shortcut created by a
small bootstrap script.

## Commands

| Command | Purpose |
|---|---|
| `PcScan.ps1` | Scan: runs the probes, writes `out\scan_<ts>.json` + `.html` (+ `scan_latest.*`), health verdict in the exit code |
| `PcPlan.ps1` | Builds `out\plan_<ts>.json` (+ `plan_latest.json`) with candidate actions from the last scan (warns if it came from a quick profile) |
| `PcApply.ps1` | Dry-run / apply the plan with per-action confirmation, one UAC per batch, post-apply re-scan + diff |
| `PcConsole.ps1` | WinForms GUI: Scan / Findings / Actions / Log tabs, verdict banner, issues-only filter |
| `tools\Fetch-Assets.ps1` | Re-downloads the vendored report assets (dev-time only) |

### PcScan options

| Option | Default | Description |
|---|---|---|
| `-Profile` | `quick` | `quick`, `standard` or `deep` (see above) |
| `-Areas` | profile areas | Comma-separated area filter (case-insensitive); overrides the profile's areas |
| `-OutDir` | `out` | Output directory |
| `-TimeoutSeconds` | 300 | Global per-probe timeout fallback (profiles declare per-area timeouts) |
| `-NoHtml` | off | Skip the HTML render, JSON only |
| `-Open` | off | Open the HTML report when done |
| `-Version` | | Print version + schema and exit |

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
System Protection when it is disabled.

Second capability: **winget upgrades** (`actions\20-winget-upgrade.ps1`) —
the plan offers a bulk action ("Upgrade all winget packages") plus one action
per package; bulk and per-package selections are mutually exclusive in the
GUI and deduplicated in the CLI. The exact command is
`winget upgrade --all|--id <id> --source winget --silent
--accept-package-agreements --accept-source-agreements
--disable-interactivity`; winget actions are marked admin so the batch runs
under a single UAC prompt, and results flag reboot requirements.

The GUI performs the same flow with per-action checkboxes, a dry-run preview
and a single confirmed elevated batch.

## Areas and probes

| Area | Probe file | Checks | Elevation |
|---|---|---|---|
| Integrity | `probes\05-Integrity.ps1` | CBS sessions (RepairNeeded/reboot) + servicing archive corruption history; deep: DISM /ScanHealth + sfc /verifyonly | no (deep: yes) |
| EventLog | `probes\06-EventLog.ps1` | Kernel-Power 41 / 6008 ungraceful shutdowns, BSOD 1001, top recurring system errors | no |
| WindowsUpdate | `probes\10-WindowsUpdate.ps1` | Pending updates + last hotfix; quick profile: service state only (no COM search) | no |
| Apps | `probes\20-Apps.ps1` | Installed apps, broken uninstall entries, last used / launches (UserAssist) | no |
| Winget | `probes\21-Winget.ps1` | Available package upgrades (requires network; tolerant of narrow output) | no |
| Appx | `probes\22-Appx.ps1` | AppX/MSIX packages (current user) | no |
| Drivers | `probes\30-Drivers.ps1` | Problem devices (Device Manager style) with installed driver version, driver inventory (consultative) | no |
| OrphanServices | `probes\40-OrphanServices.ps1` | Services pointing to missing files | partial |
| PendingReboot | `probes\41-PendingReboot.ps1` | CBS/WU reboot flags, PendingFileRenameOperations, pending computer rename | no |
| Security | `probes\60-Security.ps1` | Defender status + signature age, AV residue (Security Center), firewall profiles | no |
| Space | `probes\70-Space.ps1` | Free space per drive, main consumers (capped walks), pagefile, shadow storage | partial (shadow: yes) |
| SystemProtection | `probes\50-SystemProtection.ps1` | System Protection state, restore point age | partial |

## Report

- `out\scan_<timestamp>.json`: full machine-readable report (schema v5) with
  `profile`, `health` (score, verdict, counts, top issues, adminUsed), `host`
  (CPU, RAM, BIOS, OS dates, uptime, fixed disks), `probes` (run
  status/duration/network/timeout), `findings` (optionally with
  `actionKind`/`actionPayload`) and `datasets`.
- `out\scan_<timestamp>.html`: self-contained HTML report (renders offline
  from `assets\vendor\`; minimal inline style if the assets are missing) with:
  - sidebar navigation with per-area/table links and active-section highlight;
  - dark/light theme toggle (persisted, follows the OS preference by default);
  - gradient hero with verdict pill (HEALTHY/ATTENTION NEEDED/CRITICAL +
    score), profile badge, and a Top issues strip;
  - KPI cards with explanatory tooltips;
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
├─ PcScan.ps1              entry: scan (read-only), profiles, health verdict
├─ PcPlan.ps1              entry: scan report → action plan
├─ PcApply.ps1             entry: dry-run / apply / verify (CLI, interactive)
├─ PcConsole.ps1           entry: WinForms GUI
├─ profiles.psd1           scan profiles (areas, timeouts, network, deep)
├─ probes\NN-Area.ps1      detection plugins (read-only)
├─ actions\NN-kind.ps1     action handlers (one capability each)
├─ lib\Common.psm1         shared contracts (findings, action results) and helpers
├─ render\Report-Html.ps1  HTML renderer
├─ assets\vendor\          pinned report assets for offline rendering
├─ tools\Fetch-Assets.ps1  re-downloads the vendored assets (dev-time only)
├─ docs\                   GUIDE.md, DECISIONS.md, ROADMAP.md
├─ roadmap\                planning notes + implementation companions
└─ out\                    reports, plans, apply results, transcripts, undo\
```

### Adding a probe

1. Create `probes\NN-Area.ps1` with parameters `-OutFile` (mandatory).
2. Import the shared module:
   `Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force`
3. Build findings with `New-Finding`; if the finding is remediable, add
   `-ActionKind` (and optional `-ActionPayload`). Emit with:
   `Write-ProbeResult -Findings $findings -Datasets @{ name = $rows } -OutFile $OutFile`
4. To be profile-aware, read `$env:OXYDE_PROFILE` (set by the engine, D17).
5. Run `.\PcScan.ps1 -Areas <Area>` to test it.

The engine discovers probes by filename pattern `NN-Area.ps1`, runs each in a
child process (isolated, with per-profile timeout) and merges the results.

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
