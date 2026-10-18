# oxyde-win-maintenance — Decisions

Log of project decisions, ADR-style. Newest last.

## D1 — English only in code and interfaces

- Date: 2026-10-17
- Status: accepted
- Context: the tool must run on any Windows PC and be maintainable by any
  contributor. A single language avoids duplicated strings, translation drift
  and locale-dependent parsing.
- Decision: all code, comments, identifiers, finding texts, console output,
  report UI and documentation are written in English.
- Consequences: existing Italian strings were refactored; acceptance tests
  verify that no Italian text remains in findings or interfaces. Data matched
  against localized system output (e.g. winget messages) may still contain
  non-English literals where required for detection.

## D2 — PowerShell 5.1, zero external dependencies

- Date: 2026-10-17
- Status: accepted
- Context: the tool must run on any Windows machine with no setup.
- Decision: implement the engine and probes in Windows PowerShell 5.1 using
  only built-in modules (CIM, registry provider, COM where needed). No modules
  to install, no compiled artifacts.
- Consequences: portable via folder copy; CI/dev machines also run the same
  script. Features requiring newer PowerShell are avoided.

## D3 — Phase 1 is read-only

- Date: 2026-10-17
- Status: accepted
- Context: remediation (uninstall, driver removal, updates) is planned for
  later phases and carries risk.
- Decision: Phase 1 only inspects and reports. No probe modifies the system;
  suggested actions are text only.
- Consequences: the scanner is safe to run anywhere, requires no elevation
  for most areas, and can be re-run freely.

## D4 — Probe plugin contract

- Date: 2026-10-17
- Status: accepted
- Context: scan areas must be added independently without touching the engine.
- Decision: each area is one file `probes\NN-Area.ps1`, executed in a child
  PowerShell process with `-OutFile`. It emits JSON with `findings` (schema:
  id, area, title, status CRIT|WARN|INFO|OK, evidence, suggestedAction,
  adminRequired, source) and optional `datasets` (tabular data for the report).
- Consequences: probe crashes/timeouts are isolated and reported as a CRIT
  finding; adding an area means adding one file.

## D5 — HTML report via CDN

- Date: 2026-10-17
- Status: accepted
- Context: the report must look modern with minimal implementation effort.
- Decision: the HTML renderer uses Bootstrap 5, Bootstrap Icons, jQuery and
  DataTables from public CDNs; no bundling or local assets.
- Consequences: internet is required for full styling; without connectivity
  the report remains readable but unstyled. A future decision may vendor the
  assets locally for offline use.

## D6 — Generic tool, no machine-specific data

- Date: 2026-10-17
- Status: accepted
- Context: an early iteration embedded decisions from a specific maintenance
  session (removal lists, decisions file) into the tool.
- Decision: oxyde-win-maintenance contains no machine-specific knowledge. It reports
  criticalities objectively; per-machine judgements (keep/remove) belong to
  later, optional layers.
- Consequences: the `rules\decisions.psd1` machinery was removed; probes and
  the report only carry findings and data.

## D7 — Actions layer with guardrails

- Date: 2026-10-17
- Status: accepted (implementation: ROADMAP step 1)
- Context: Phase 2 introduces remediation (restore points, updates, service
  cleanup, uninstalls). These are system-changing operations on arbitrary
  machines.
- Decision: actions live in `actions\NN-kind.ps1` handlers with the contract
  documented in `docs\ROADMAP.md`. Every capability runs dry-run by default,
  executes only catalog commands (never arbitrary shell), exports undo
  artifacts where possible, and is verified by re-scanning the affected areas
  with a before/after diff.
- Consequences: probes stay read-only (D3); findings opt into remediation by
  carrying `actionKind`/`actionPayload` (D10); transcripts and result JSON
  make every run auditable.

## D8 — CLI interaction model

- Date: 2026-10-17
- Status: accepted
- Context: users must stay in control of what gets executed.
- Decision: `PcApply.ps1` is dry-run by default, confirms each action
  interactively (Enter/y apply, n skip, s skip remaining), and performs at
  most one elevation prompt per batch (self-relaunch via `-Verb RunAs`).
  `-Yes` enables unattended runs; `-NoElevate` keeps everything unelevated
  (admin actions end as `denied`).
- Consequences: the GUI reuses the same engine: per-action granularity is
  expressed by checkboxes plus a dry-run preview, then a single confirmed
  elevated batch.

## D9 — WinForms GUI (PcConsole)

- Date: 2026-10-17
- Status: accepted
- Context: an interface is needed to gather scan, findings and actions in
  one place; zero-dependency constraint applies (D2).
- Decision: `PcConsole.ps1` is a WinForms UI (available in PowerShell 5.1)
  with four tabs: Scan, Findings, Actions, Log. It orchestrates the same
  entry scripts (PcScan / PcPlan / PcApply) as child processes, tails their
  log files with a UI timer, and requests elevation only for apply.
- Consequences: no external GUI framework; the HTML report remains the
  shareable artifact while the console is the operational dashboard.
- Implementation note (bugfix 2026-10-17): child output is captured by
  redirecting all streams to a log file (`*>&1 | Out-File -Encoding utf8`)
  and tailing it from the UI timer. .NET `OutputDataReceived` scriptblock
  events must NOT be used: their callbacks run on pool threads, race with
  the UI thread on shared state and crashed the process silently at scan
  completion. All UI handlers are additionally guarded (`Invoke-Guarded`)
  so an exception can never close the window.

## D10 — Report schema v4 (action fields)

- Date: 2026-10-17
- Status: accepted
- Context: PcPlan builds the action list from the scan report.
- Decision: findings may carry `actionKind` and `actionPayload`; the report
  `schemaVersion` becomes 4. Fields are optional, so v3 readers still work.
- Consequences: probes decide what is remediable; the plan layer never
  guesses.

## D11 — Dataset-driven action expansion

- Date: 2026-10-17
- Status: accepted
- Context: one finding can describe a class of remediable items (e.g. "20
  upgrades available via winget"). Emitting one finding per item would flood
  the report with noise.
- Decision: a finding may declare `actionPayload = { source: 'dataset',
  dataset: '<name>' }`. PcPlan expands that declared dataset into a bulk
  action plus one action per row (ids `<kind>:all` / `<kind>:<key>`). The
  probe stays read-only and the declaration is explicit, so the plan layer
  still does not guess.
- Consequences: report findings stay concise while the Actions tab gets full
  per-item granularity; bulk and per-item selections are deduplicated
  (bulk wins in PcApply; mutually exclusive in the GUI). First user:
  `winget-upgrade`.

## D12 — Drivers area is consultative

- Date: 2026-10-18
- Status: accepted
- Context: users asked for a winget-like view of driver updates. winget has
  no driver source; the Windows Update driver-only search measured ~145s on
  the test machine (vs ~10s for the standard search), while the standard
  search already includes driver updates. Device Manager-style checks risk
  phantom false positives (e.g. `CM_PROB_DEVICE_NOT_THERE` PS/2 placeholders).
- Decision: the new Drivers area (probe `30-Drivers.ps1`) is read-only and
  consultative: it lists devices with real problems (classified via the
  `Problem` enum; benign/phantom states excluded) together with the installed
  driver version, plus the installed-driver inventory. Driver updates remain
  under the WindowsUpdate area; a `wu-install` action (per-update via
  `Identity.UpdateID`, with bulk variant) is the discussed candidate for a
  future step and is not implemented yet.
- Consequences: no actions from this area for now; no extra WU searches in
  scans; the report gains two datasets (`problemDevices`, `drivers`).

## D13 — "Last used" comes from UserAssist (current user)

- Date: 2026-10-18
- Status: accepted
- Context: Windows has no direct "last used" field for classic Win32 apps.
  Options: prefetch (admin-only, rotating 128+ entries, exe-level), SRUM
  (admin, complex), UserAssist (readable per-user without elevation, records
  Explorer/GUI launches with last-use time and run count).
- Decision: probe `20-Apps.ps1` enriches rows with `lastUsed` and `launches`
  parsed from `HKCU\...\Explorer\UserAssist` (both the executables and the
  shortcuts key). Value names are ROT13-encoded; on modern builds the last-use
  FILETIME is at offset 60 (offset 8 only for legacy 16-byte entries).
  Matching priority: DisplayIcon executable name (generic names like
  `uninstall.exe`/`setup.exe` are blacklisted to avoid cross-attribution),
  then exact normalized name (AppID / shortcut), then containment with a
  minimum of 4 alphanumeric characters per side; ties resolve to the latest
  date. Consultative only: unknown usage stays empty.
- Consequences: usage reflects Explorer-launched GUI apps of the current
  user only (other launch paths and other users show no data); the containing
  folder is cleared during privacy cleanups, which empties the history.

## D14 — Scan profiles (quick / standard / deep)

- Date: 2026-10-18
- Status: accepted
- Context: a single "everything" scan (27.6 s on the test host, dominated by
  the Windows Update COM search and the per-probe child-process startup)
  discourages a fast health check. Per-probe child startup is ~1.2 s, so the
  profile must prune areas, not just tweak timeouts.
- Decision: declarative `profiles.psd1` with `areas`, per-area `timeouts`,
  `network` labels and a `deep` flag. `PcScan.ps1` gains `-Profile` with
  `quick` as the default; explicit `-Areas` overrides the profile areas.
  `quick` = WindowsUpdate light mode (service state + last hotfix, no COM
  search), PendingReboot, OrphanServices — ~6 s engine time on the test host.
  `standard` = all current probes. `deep` = standard + elevation, declared in
  the report (`health.adminUsed`); heavy P1 probes join it as they land.
- Consequences: `PcScan.ps1` without arguments is no longer a full scan
  (breaking change, documented); the GUI passes `-Profile standard`
  explicitly for its full scan; `PcPlan.ps1` warns when the latest report
  came from a quick profile.

## D15 — Health verdict: score, verdict, exit codes

- Date: 2026-10-18
- Status: accepted
- Context: the findings grid alone cannot answer "am I healthy?"; a verdict
  must never treat unchecked/unknown areas as healthy, and scripts need a
  machine-readable outcome.
- Decision: schema v5 adds `health = { score, verdict, counts, topIssues,
  profile, adminUsed }`. Score = `100 - 25*CRIT - 8*WARN` clamped to 0..100
  (only WARN/CRIT demote; INFO/OK never penalize). Verdict: any CRIT →
  `CRITICAL`, else any WARN → `WARNING`, else `OK`. Exit code: 0/1/2
  accordingly. `New-Finding` gains optional `category` metadata (no scoring
  weight yet: scoring derives from `status` only).
- Consequences: probe failures (already CRIT findings) automatically drive
  the verdict; the renderer and GUI show the verdict banner; older v4
  reports degrade gracefully (no health block → legacy pill). Amended by
  D18: scoring/verdict/topIssues exclude `category='summary'` roll-ups and
  `health.coverage` discloses skipped checks.

## D16 — Vendored report assets (supersedes the D5 CDN clause)

- Date: 2026-10-18
- Status: accepted
- Context: D5 loaded Bootstrap/jQuery/DataTables/Chart.js/Inter from CDNs;
  without internet the report is unstyled, which conflicts with use on other
  PCs.
- Decision: pin and vendor the same versions under `assets\vendor\`
  (~1.1 MB, committed; `tools\Fetch-Assets.ps1` re-downloads them). The
  renderer resolves assets relative to the report at render time (small
  relative-path helper; PS 5.1 has no `GetRelativePath`); if the assets are
  missing it emits a minimal inline fallback with **zero** external requests
  and the JS init guards optional libraries. The Inter variable font is the
  same woff2 for every weight: one file, five `@font-face` blocks.
- Consequences: reports render identically offline; the repo grows by
  ~1.1 MB; `D5`'s CDN requirement no longer applies.

## D17 — Probes read the active profile from OXYDE_PROFILE

- Date: 2026-10-18
- Status: accepted
- Context: quick mode needs profile-aware probe behaviour (e.g. the Windows
  Update probe skips the COM search), but adding a parameter to every probe
  would break the `-File` invocation contract.
- Decision: the engine sets `$env:OXYDE_PROFILE` before spawning probe child
  processes (children inherit it) and restores it afterwards. Probes opt in
  by reading the variable; probes that ignore it keep working unchanged.
- Consequences: no probe CLI changes; documented in GUIDE as the contract
  for profile-aware probes.

## D18 — Coverage disclosure, summary-exclusion scoring, deep-elevation notice

- Date: 2026-10-18
- Status: accepted (amends D15)
- Context: independent verification of P0 found three medium/low issues
  (roadmap\_2_20261018_0954.md): a quick scan could report `OK` on incomplete
  coverage (skipped checks were only INFO); the score double-counted roll-up
  findings (one orphan service counted −8 twice, item + summary); `-Profile
  deep` from the CLI neither elevated nor warned, producing misleading
  `profile=deep, adminUsed=false` reports.
- Decision:
  1. `health.coverage` (additive, schema stays v5) records `areasRun`,
     `areasSkipped` (vs the discovered probes, profile or `-Areas` filters),
     `networkDependent`, `elevated`, `deepWithoutElevation` and `partial`;
     the verdict pill and GUI banner append " (partial)" and the hero shows
     `coverage: X/Y areas` with the skipped list. A partial verdict is never
     presented as complete; it is not demoted (score stays findings-driven).
  2. Roll-up findings carry `category='summary'` (WindowsUpdate, Apps, Appx,
     Drivers, OrphanServices) and are excluded from score, verdict and
     topIssues — a single issue is never counted twice. The winget summary is
     NOT a roll-up (no per-item duplicates) and stays scored.
  3. Deep without elevation prints an explicit console warning, adds the
     `engine-deep-unelevated` INFO finding (area `System`) and sets
     `coverage.deepWithoutElevation`; no CLI self-elevation (surprising UAC
     from a scan is against D7's spirit; the GUI deep button elevates).
- Consequences: quick on the test host reports `WARNING … (partial)`,
  score 76 (3 real issues); standard reports 52 (6 real issues); the wizardly
  "healthy" on unchecked machines is now impossible to misread.
