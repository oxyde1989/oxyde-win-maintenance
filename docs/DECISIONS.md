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

## D10 — Report schema v4 (action fields)

- Date: 2026-10-17
- Status: accepted
- Context: PcPlan builds the action list from the scan report.
- Decision: findings may carry `actionKind` and `actionPayload`; the report
  `schemaVersion` becomes 4. Fields are optional, so v3 readers still work.
- Consequences: probes decide what is remediable; the plan layer never
  guesses.
