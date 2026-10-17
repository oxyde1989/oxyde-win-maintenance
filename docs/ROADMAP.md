# oxyde-win-maintenance — Roadmap

Status of the project phases and the confirmed Phase 2 plan.

## Phase overview

| Phase | Scope | Status |
|---|---|---|
| 1 | Scan & report (read-only): engine, probes, JSON schema, HTML report | DONE (schema v4) |
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

## Step 2 — Winget upgrades (next, after step 1)

- Plan actions per package (`winget-upgrade:<id>` from the `wingetUpgrades`
  dataset) + a bulk variant.
- Apply: `winget upgrade --id <id> --silent --accept-package-agreements
  --accept-source-agreements --disable-interactivity`.
- Verify targeted: `winget list --id <id>`; fallback to re-running
  `21-Winget.ps1`.
- Failure handling: elevation-required failures are reported with a hint to
  rerun elevated; reboot-required packages flagged.

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

## Phase 3 — REA integration (planned)

- `npx rea-agents setup` registers REA with the agent; stubborn installers
  are analyzed to discover silent switches (native binaries via
  Ghidra/IDA; .NET static analysis needs no engine).
- Discovered switches are stored as reusable recipes
  (`actions\uninstallers\<app>.yaml`) consumed by the app-uninstall handler.

## Suggested housekeeping

- DONE 2026-10-17: `git init` (branch `main`), `.gitignore` (`/out/`),
  `.gitattributes` (CRLF for PowerShell sources).
- Vendor CDN assets locally if offline report rendering becomes a requirement
  (DECISIONS D5).
