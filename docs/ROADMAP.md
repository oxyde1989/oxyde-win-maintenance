# oxyde-win-maintenance — Roadmap

Status of the project phases and the confirmed Phase 2 plan.

## Phase overview

| Phase | Scope | Status |
|---|---|---|
| 1 | Scan & report (read-only): engine, probes, JSON schema, HTML report | DONE (schema v5: profiles + health verdict) |
| 2 | Actions: plan → dry-run → apply, with guardrails and verification | IN PROGRESS — step 1 implemented, elevated acceptance pending |
| 3 | Reverse engineering (REA) for silent-uninstall discovery, driver packages | PLANNED |

## Phase 2 architecture

Actions are a second plugin layer, same philosophy as probes.

```
oxyde-win-maintenance\
├─ PcScan.ps1              entry: scan (Phase 1, unchanged behavior)
├─ PcPlan.ps1              entry: scan report → plan file (candidate actions)
├─ PcApply.ps1             entry: dry-run / apply / verify (CLI, interactive)
├─ PcConsole.ps1           entry: WinForms GUI (Scan / Findings / Actions / Log)
├─ probes\NN-Area.ps1      detection plugins (read-only)
├─ actions\NN-kind.ps1     action handlers (one capability each)
├─ lib\Common.psm1         shared contracts and helpers
├─ render\Report-Html.ps1  HTML renderer
├─ docs\                   GUIDE, DECISIONS, ROADMAP (this file)
└─ out\                    reports, plans, apply results, transcripts
```

### Safety rails (apply to every capability, no exceptions)

- CLI is **dry-run by default**; `-Apply` is explicit.
- **Catalog only**: actions run handler scripts from `actions\`, never
  arbitrary commands. Kinds are discovered by filename `NN-kind.ps1`.
- **Single UAC per batch**: if selected actions need admin and the session is
  not elevated, PcApply relaunches itself once via `-Verb RunAs`.
  `-NoElevate` skips the relaunch (admin actions then end as `denied`).
- **Interactive per-action confirmation** in CLI (Enter/y = apply, n = skip,
  s = skip remaining). `-Yes` for unattended runs (used by the GUI after its
  selection dialog).
- **Undo artifacts**: handlers export rollback material to `out\undo\` when
  possible (e.g. `.reg` exports before service deletion).
- **Verification**: after an apply, PcApply re-runs the affected scan areas
  and writes a before/after diff to `out\apply_<ts>.json`.
- Handlers never pass null argument lists to `Start-Process` (lesson learned
  from the parallel maintenance log: `ArgumentList` null → fatal).

### Action handler contract

Each file `actions\NN-kind.ps1` exposes:

```
-OutFile    result JSON (mandatory)     -Mode dryrun|apply|verify (mandatory)
-ActionFile one action entry as JSON (id, kind, title, payload, sourceFinding)
```

Result JSON (`New-ActionResult` in lib\Common.psm1):

```json
{ "id":"...", "kind":"...", "title":"...",
  "status":"dryrun|done|failed|skipped|denied|throttled",
  "precheck":"pass|fail|skipped", "command":"<exact command (dryrun)>",
  "exitCode":0, "output":"<truncated>",
  "verify":"pass|fail|unknown|skipped",
  "undoHint":"...", "undoFile":"...", "durationMs":0 }
```

`dryrun` must print the exact command the apply would run: command strings are
built once and shared by both modes.

### Plan file format (`out\plan_<ts>.json`)

```json
{ "planVersion":1, "generatedAt":"...", "sourceReport":"out\\scan_....json",
  "host":"...", "options":{ "restorePointFirst":true },
  "actions":[
    { "id":"restorepoint", "kind":"restorepoint",
      "title":"Create restore point (safety step)",
      "risk":"low", "adminRequired":true, "defaultSelected":true,
      "payload":{ "description":"oxyde-win-maintenance: pre-actions checkpoint" },
      "sourceFinding":"" }
  ] }
```

Findings opt into remediation by carrying `actionKind` (+ optional
`actionPayload`) — report schema v4. PcPlan maps them to plan actions
(`id = "<kind>:<findingId>"`); unknown kinds are listed under `unsupported`.

## Step 1 — Action framework + Restore point + GUI (CONFIRMED 2026-10-17)

Deliverables, in implementation order:

1. **lib\Common.psm1** — `New-Finding` gains `ActionKind`/`ActionPayload`;
   new helpers: `Write-JsonFile`, `New-ActionResult`, `Write-ActionResult`.
2. **probes\50-SystemProtection.ps1** — System Protection state + restore
   point history; WARN when protection is disabled or the newest point is
   older than 30 days (findings carry `actionKind=create-restorepoint`);
   dataset `restorePoints`; reading without admin degrades to INFO with
   `adminRequired`.
3. **PcScan.ps1** — report `schemaVersion` 4 (fields pass through unchanged).
4. **actions\10-restorepoint.ps1** — precheck (elevation; enable System
   Protection via `Enable-ComputerRestore` if disabled, logged), apply
   (`Checkpoint-Computer -RestorePointType MODIFY_SETTINGS`), Windows
   24h-throttle handled as `throttled` (not a failure), verify compares the
   newest restore point before/after.
5. **PcPlan.ps1** — reads `out\scan_latest.json`, emits plan JSON
   (restore point always included as default-selected safety step).
6. **PcApply.ps1** — plan runner with dry-run default, per-action
   confirmation, single-UAC relaunch, transcript `out\apply_<ts>.log`,
   result JSON `out\apply_<ts>.json`, end-of-run re-scan + diff of affected
   areas (`out\verify_<ts>\`), exit code 1 when any action failed.
7. **PcConsole.ps1** — WinForms GUI: Scan tab (all/selected areas, live log),
   Findings tab (grid + "Build plan"), Actions tab (per-action checkboxes,
   "Create restore point first" toggle, Dry run preview, Apply selected with
   confirmation dialog → single UAC → elevated `PcApply -Yes`, live log tail),
   Log tab. Runs child processes with Timer-based log polling (no runspaces).
8. Docs: DECISIONS D7–D10; GUIDE updated; this roadmap kept in sync.

Acceptance: scan finds protection state; plan contains the restore point
action; dry-run shows the exact command; non-elevated apply degrades to
`denied` with `-NoElevate`; elevated apply creates a real restore point
(throttle-aware) and the diff is written; GUI performs scan → plan → apply.

Status 2026-10-17: implemented. Verified on the host: schema v4, plan
generation, dry-run output, denied path, transcripts and result JSON.
Acceptance pending (user action): run the GUI or `PcApply.ps1 -Apply` and
accept the single UAC prompt to create a real restore point.

## Step 2 — Winget upgrades — DONE 2026-10-17

- Findings opt in with `actionKind=winget-upgrade` and a payload of
  `{ source: 'dataset', dataset: 'wingetUpgrades' }` (declared by probe
  `21-Winget.ps1` on the summary finding).
- PcPlan expands the declared dataset into one **bulk** action
  (`winget-upgrade:all`, default-selected, `timeoutSeconds: 1800`) plus one
  action per package (`winget-upgrade:<packageId>`, `timeoutSeconds: 600`).
  In PcApply, when the bulk is selected the per-package actions are dropped
  (covered); in the GUI the two groups are mutually exclusive.
- Apply: `winget upgrade --all|--id <id> --source winget --silent
  --accept-package-agreements --accept-source-agreements
  --disable-interactivity` (command built once, shared by dry-run and apply).
- Winget actions are marked `adminRequired: true`: the whole batch runs under
  a single UAC prompt (machine-scope packages need it; user-scope works
  elevated too). Without elevation the handler reports `denied`.
- Targeted verification inside the handler: single → installed version via
  `winget list --id`; bulk → remaining upgrade count vs. the pre-run count.
  Global verification stays the post-apply re-scan diff (Winget area).
- Failure handling: access-denied/elevation hints and reboot hints are
  surfaced in the result output; unknown/failed upgrades leave the verify at
  `unknown` instead of a false failure.
- Plan actions may carry `timeoutSeconds` (used by PcApply per action).

Status 2026-10-17: implemented and verified (plan 22 actions: restore point +
bulk + 20 packages; dry-run commands exact; denied path exit code 1; real
upgrade left to the user's GUI run).

## P0 — Simple and fast (DONE 2026-10-18, plan in roadmap\_1_20261018_0931.md)

Executed per roadmap\_1_20261018_0931_implementation.md, committed task by task:

- **Winget parser fix**: redirected winget output uses single-space column
  separators; the parser now tolerates both layouts (ID-anchored regex with
  backtracking, verified on wide/narrow/dotted-name/source-column cases),
  plus UTF-8 output encoding and localized footer handling. Unparseable
  output and non-zero exits are `WARN` with evidence (never a silent `INFO`);
  all winget findings carry "Requires network" (D-notes in commit e150e99).
- **Scan profiles** (D14): `profiles.psd1` declarative; `-Profile
  quick|standard|deep`, quick is the default and runs in ~6 s engine time
  (WindowsUpdate light mode + PendingReboot + OrphanServices). Probes read
  the active profile via `OXYDE_PROFILE` (D17).
- **PendingReboot probe** (`41-PendingReboot.ps1`, pulled forward from P1):
  CBS/WU flags, PendingFileRenameOperations, pending computer rename.
- **Health verdict** (D15): schema v5 `health` block (score/verdict/counts/
  topIssues/profile/adminUsed), `-Version`, exit codes 0/1/2, scan retention
  (newest 30 pairs), PcPlan warns on quick-profile sources.
- **Offline report** (D16): vendored assets in `assets\vendor\`
  (~1.1 MB, `tools\Fetch-Assets.ps1`), relative links at render time, minimal
  inline fallback with zero network requests; JS init guards optional libs.
- **GUI health check**: "Run health check" (quick) with colored verdict
  banner + issues-only filter, "Run scan (standard)", "Deep scan (admin)"
  (single UAC, declared).

Acceptance: `PcScan.ps1 -Profile quick -Open` → verdict + score < 10 s, exit
code reflects the verdict; offline render verified with and without assets;
GUI alive after automatic scan with no UI errors.

Remaining P1/P2 per the plan: new probes (Integrity, EventLog, Storage,
Security, Space, Startup, UpdateHealth), remediation actions, packaging and
tests.

## P1 Batch 1 — Quick becomes a real health check (DONE 2026-10-18, plan in roadmap\_2_20261018_0954_implementation.md)

- **New probes** (read-only, quick part non-elevated):
  `05-Integrity.ps1` (CBS sessions + servicing archive fast scan; deep:
  DISM /ScanHealth + sfc /verifyonly elevated, timeout 900 s),
  `06-EventLog.ps1` (Kernel-Power 41 / 6008 / BSOD 1001 90 days + top
  recurring System errors 30 days), `70-Space.ps1` (free space, capped
  consumer walks, pagefile, shadow storage with graceful degradation),
  `60-Security.ps1` (Defender status/signatures, AV residue via
  SecurityCenter2, firewall in standard/deep).
- **Engine fixes** (residuals from the `_2` verification): `health.coverage` +
  "(partial)" disclosure (D18.1), summary findings excluded from
  score/verdict/topIssues (D18.2), deep-without-elevation warning + finding
  (D18.3); version 0.6.0; `wuauserv` light check no longer flags the normal
  Manual/trigger-start idle state.
- **Measured on the test host**: quick = 6.8–7.0 s engine / 8.4–9.0 s wall
  with 7 areas (< 10 s target), score 76 `(partial)` with 3 real issues
  (ungraceful shutdowns 27/90 d, orphan service, Malwarebytes WSC residue);
  standard = 23.9 s, score 52 with 6 real issues; quick catches the real
  session picture: 401 archive corruption markers (last 2026-10-17), 27
  ungraceful shutdowns, 370 MB Temp right in the report.
- **User-triggered acceptance still open** (like the restore point in P0):
  elevated deep run (DISM/SFC) and shadow-storage values.
- Batch 2 unchanged: `31-Storage.ps1`, `80-Startup.ps1`, UpdateHealth folded
  into `10-WindowsUpdate.ps1`, elevated deep hardening.

## Step 3 — Orphan service removal

- Precheck: file still missing, service still exists.
- Undo: export `HKLM\SYSTEM\CurrentControlSet\Services\<name>` to
  `out\undo\svc_<name>.reg` before deletion.
- Apply: `sc.exe delete`; fallback registry key delete.
- Denied (tamper-protected AV services) is an explicit `denied` outcome with
  a hint (remove/disable the parent product first). Verify accounts for
  "pending until reboot".

## Step 4 — Application uninstall

- MSI entries → `msiexec /x{GUID} /qn /norestart`; `QuietUninstallString`
  used directly; AppX → `Remove-AppxPackage` (per-user only).
- Entries without a known silent switch are not executable by the runner;
  they are marked for Phase 3 (REA).

## Drivers — consultative view (DONE 2026-10-18, see DECISIONS D12)

- Probe `30-Drivers.ps1`: problem devices (Device Manager style) classified
  via the `Problem` enum with benign/phantom states excluded
  (`CM_PROB_DEVICE_NOT_THERE`, `CM_PROB_PHANTOM`, `CM_PROB_DISABLED`,
  `CM_PROB_LEGACY_DEVICE`); missing drivers are `CM_PROB_FAILED_INSTALL`.
  Each problem device shows the currently installed driver version (via
  `Get-PnpDeviceProperty`). Datasets: `problemDevices`, `drivers` (inventory).
- Read-only: no actions. Driver *updates* remain under WindowsUpdate.
- Measured on the test machine: WU driver-only search ~145s (standard search
  ~10s) → never add a dedicated WU driver query; phantom PS/2 entries
  (`CM_PROB_DEVICE_NOT_THERE`) proved the need for classification.
- Candidate future step: `wu-install` action (per-update via
  `Identity.UpdateID` + bulk) which would also cover driver updates; video
  drivers to be excluded from the default bulk selection (risk of black
  screen). Vendor tools (Intel DSA/NVIDIA) remain out of scope.

## Phase 3 — REA integration (planned)

- `npx rea-agents setup` registers REA with the agent; stubborn installers
  are analyzed to discover silent switches (native binaries via
  Ghidra/IDA; .NET static analysis needs no engine).
- Discovered switches are stored as reusable recipes
  (`actions\uninstallers\<app>.yaml`) consumed by the app-uninstall handler.

## Suggested housekeeping

- DONE 2026-10-17: `git init` (branch `main`), `.gitignore` (`/out/`),
  `.gitattributes` (CRLF for PowerShell sources).
- DONE 2026-10-18: report assets vendored locally for offline rendering
  (DECISIONS D16 supersedes the D5 CDN clause).
