<div align="center">

# oxyde-win-maintenance

**A portable, read-only-first Windows health check you can run on any PC — with a verdict, a shareable report, and guarded fixes when you ask for them.**

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](https://unlicense.org/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue.svg)](https://learn.microsoft.com/powershell/scripting/overview)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-lightgrey.svg)](https://learn.microsoft.com/windows/)
[![Version](https://img.shields.io/badge/version-0.11.0-informational.svg)](#)
[![Schema](https://img.shields.io/badge/report_schema-v5-informational.svg)](#)
[![Dependencies](https://img.shields.io/badge/dependencies-none-success.svg)](#)

*Copy the folder. Run it. Read the verdict.*

</div>

---

## Table of contents

- [What it is](#what-it-is)
- [Why it exists](#why-it-exists)
- [Highlights](#highlights)
- [Quick start](#quick-start)
- [The health verdict](#the-health-verdict)
- [Scan profiles](#scan-profiles)
- [Scan areas](#scan-areas)
- [Actions](#actions)
- [Safety rails](#safety-rails)
- [Output](#output)
- [Feed the report to an AI](#feed-the-report-to-an-ai)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [Roadmap](#roadmap)
- [Requirements](#requirements)
- [Privacy](#privacy)
- [Disclaimer](#disclaimer)
- [AI assistance](#ai-assistance)
- [License](#license)

---

## What it is

`oxyde-win-maintenance` is a small Windows toolkit that answers one question
quickly and honestly: **is this PC healthy, and what should I do about it?**

It is built for the case where you inherited a machine — yours, a relative's, a
second-hand one — and you need a fast, factual picture before touching anything.
It inspects the machine with **read-only probes**, produces a **JSON + HTML
report**, and gives you a **single verdict with a score**. Only if you ask for it
does it propose **remediation actions**, each one dry-run first, individually
confirmed, and reversible where possible.

No installation, no modules, no compilation, no internet required for the core
scan. Windows PowerShell 5.1 is already on the machine.

## Why it exists

This tool was born out of a real maintenance session on a five-year-old
Windows 11 PC that had been quietly deteriorating for months. A full
investigation turned up things a generic "cleaner" would never have mentioned:

- **2 101 corruptions in the Windows component store** (401 payload + 1700 file
  flags), silently repaired by DISM, with **SFC clean afterwards**
- a long trail of **ungraceful shutdowns** (Kernel-Power 41 / EventLog 6008) —
  almost certainly the root cause of the corruption
- **Windows Update stalled for two months**
- roughly **32 GB of recoverable disk space** (leftover caches, an orphaned
  user-data folder, an over-provisioned component store)
- **real-time protection switched off**, plus **security-suite residue** from
  three uninstalled antivirus products, complete with orphaned services
- **pending reboot state** nobody had cleared

None of these are visible in a list of "installed programs". They are the reason
this project exists: the goal is to make that whole class of finding cheap to
detect, repeatable, and honest about what it did *not* check.

## Highlights

| | |
|---|---|
| **Portable** | One folder, copy it anywhere, nothing to install. |
| **Read-only first** | Scanning never changes the machine (probes are isolated child processes with their own timeout). |
| **Verdict + score** | `100 − 25×critical − 8×warning`, clamped (roll-up summaries are not counted twice), plus an absolute issue count; a machine-readable `health` block and an exit code for scripting. |
| **Fast by default** | The `quick` profile finishes in under 10 seconds on a mid-range PC. |
| **Honest about coverage** | Areas that need network or elevation are declared in the report instead of silently skipped. |
| **Reportable** | A polished HTML report with tabs (Overview / Areas / Data / Probes), deep-linkable and printable: one **self-contained file** by default (~1.4 MB, works moved anywhere alone), or ~136 KB with asset references (`-ExternalAssets`); plus the raw JSON. |
| **Guarded fixes** | Actions come only from a catalog, default to dry-run, are confirmed one by one, and are verified by re-scanning the affected areas afterwards. |
| **No dependencies** | PowerShell 5.1 and Windows built-ins only. `winget` is optional. |
| **Auditable** | ADR-style decision log and planning notes kept locally, plus transcripts and machine-readable results for every run. |

## Quick start

**GUI (no commands):** double-click `Start-Console.cmd`, press
**Run quick check**, read the colored verdict banner.

**Command line:**

```powershell
# Fast health check (default profile), opens the HTML report
.\PcScan.ps1 -Profile quick -Open

# Same thing without touching the execution policy for the session
powershell -NoProfile -ExecutionPolicy Bypass -File .\PcScan.ps1 -Profile quick -Open

# Full picture: update search, winget, drivers, everything
.\PcScan.ps1 -Profile standard -Open

# Tool version
.\PcScan.ps1 -Version
```

Nothing is changed by any of the above. When — and only when — you want to act:

```powershell
.\PcScan.ps1 -Profile standard      # 1. find criticalities (read-only)
.\PcPlan.ps1                         # 2. build the candidate action plan
.\PcApply.ps1                        # 3. dry run: prints the exact commands
.\PcApply.ps1 -Apply                 # 4. apply, interactively, one UAC prompt
```

## The health verdict

Every scan produces a single verdict in the console, in the report hero, in the
GUI banner and in the JSON:

| Verdict | Meaning | Score | Exit code |
|---|---|---|---|
| `OK` | Checks ran and found nothing that needs attention | 100 | `0` |
| `WARNING` | Action advised; the machine is usable but not clean | < 100 | `1` |
| `CRITICAL` | Urgent: failed checks or serious problems | ≤ 75 | `2` |

```
Verdict: WARNING (score 68, 4 issues)
CRIT 0 | WARN 5 | INFO 6 | OK 4  (8108 ms)
```

The exit code makes the tool usable from scheduled tasks and scripts: `0` healthy,
`1` attention needed, `2` urgent.

`INFO` and `OK` never penalize the score, and a skipped check is reported as such
rather than counted as a pass.

## Scan profiles

Profiles are declarative data in [`profiles.psd1`](profiles.psd1): they select
areas, per-area timeouts, which areas need the network, and whether elevation is
required.

| Profile | Areas | Elevation | Typical wall time |
|---|---|---|---|
| `quick` *(default)* | Integrity (CBS read), EventLog, Space, Security (Defender + AV residue), Windows Update (service state + last hotfix), Pending reboot, Orphan services | no | ~5–10 s |
| `standard` | All 13 areas: full update search + update health, apps, winget, AppX, drivers, integrity/events/space/security, firewall, autostart entries, System Protection | no | ~30 s |
| `deep` | As `standard` + Storage (disk health, SMART, wear) + the elevated DISM `/ScanHealth` + `sfc /verifyonly` integrity run; elevation declared in the report | yes | minutes |

Areas that inherently need the internet (the update search, winget) are labelled
`Requires network` in the report; they are never silently reported as "clean" when
they could not run. `(partial)` appears only when coverage was actually lost — an
explicit `-Areas` narrowing, a failed probe or a deep scan without elevation;
profile-declared scope is disclosed quietly in `health.coverage`, not as an alarm.

## Scan areas

| Area | What it looks at | Profile |
|---|---|---|
| `Integrity` | Component-store health: current CBS sessions, servicing-archive corruption history; deep adds DISM/SFC | quick / standard / deep |
| `EventLog` | Ungraceful shutdowns (Kernel-Power 41 / 6008), bug checks (BSOD), top recurring system errors | quick / standard / deep |
| `Space` | Free space per drive, main consumers, pagefile, shadow storage (needs elevation) | quick / standard / deep |
| `Security` | Defender status + signature age, AV residue (Security Center), firewall profiles; deep adds TPM, Secure Boot and activation | quick / standard / deep |
| `Storage` | Disk health and operational status; elevated: SMART predict-failure, wear, temperature, error counters | deep |
| `WindowsUpdate` | Pending updates, last installed hotfix, update service state; update-health history (events, SoftwareDistribution) | quick / standard / deep |
| `PendingReboot` | CBS servicing state, `RebootRequired`, `PendingFileRenameOperations`, pending rename | all |
| `OrphanServices` | Services whose `ImagePath` points to a file that no longer exists | all |
| `Startup` | Run/RunOnce keys, Startup folders, scheduled tasks with missing targets, third-party auto services | standard / deep |
| `Apps` | Installed application inventory, broken uninstall entries, last-used history | standard / deep |
| `Winget` | Package upgrades available through winget | standard / deep |
| `Appx` | Per-user AppX/MSIX packages | standard / deep |
| `Drivers` | Problem devices (Device Manager style, with installed driver version) and driver inventory | standard / deep |
| `SystemProtection` | System Protection state and restore point age | standard / deep |

Still on the way: **disk reliability trend**, **startup impact** — see
the [roadmap](#roadmap).

## Actions

An action is only ever proposed when a finding explicitly opts into one. Every
action runs dry-run first and prints the exact command it would execute.

| Action | What it does | Status |
|---|---|---|
| `restorepoint` | Creates a system restore point (throttle-aware) before any change | implemented |
| `shadow-resize` | Raises the shadow-storage limit so restore points survive (raise-only, never shrinks; offered from the eviction evidence, even unelevated) | implemented |
| `winget-upgrade` | Upgrades packages, bulk or one by one, with reboot hints | implemented |
| `wu-install` | Installs specific pending updates | planned |
| `app-uninstall` | Removes applications (MSI / quiet / AppX) | planned |
| `service-delete` | Removes leftover services after six safety guards, exporting the registry key for undo | implemented |
| `integrity-repair` | DISM component-store repair + SFC: restore point required from the same batch, live step markers, measured before/after | implemented |
| `clean-caches` | Recovers space from caches and leftovers | planned |

## Safety rails

These apply to every capability, without exception:

- **Scanning is read-only.** No probe modifies the machine.
- **Dry-run is the default.** Applying requires an explicit switch.
- **Catalog only.** Actions run from `actions\`, never arbitrary shell commands.
- **Confirmation per action** in the CLI (`y` apply, `n` skip, `s` skip all); the
  GUI shows a preview and one confirmation dialog.
- **Chain guarantee:** when the plan contains a component-store repair, the order
  is enforced — raise the shadow limit, create a restore point, then repair. The
  repair refuses to start without a restore point created in the same batch
  (explicit override otherwise).
- **One UAC prompt per batch**, never one per action.
- **Every action declares its budget.** The plan states each action's timeout; the
  runner prints the effective budget (`Handler killed at its N s budget` if it
  fires) and records it in every result. Long handlers get a 30 s heartbeat, so a
  blocked action still shows movement.
- **Failures are never silent.** Refusals and launch/outcome failures surface
  with the exact reason (message box in the GUI, warning in the CLI); the Actions
  tab shows a live status strip — phase, elapsed, last-output age — during any
  child run.
- **Undo material is exported** to `out\undo\` where the operation allows it.
- **Verification by re-scan**: after an apply, the affected areas are scanned
  again and a before/after diff is written.
- **Transcripts and result JSON** for every run, so a run can always be audited
  after the fact.
- **Provisional scope:** anything not listed in the action catalog is out of
  scope, even if it would be convenient.

## Output

Everything lands in `out\` (git-ignored):

| File | Content |
|---|---|
| `scan_<timestamp>.json` | Full machine-readable report: `host`, `health`, `probes`, `findings`, `datasets` |
| `scan_<timestamp>.html` | Shareable report: one self-contained file by default (assets embedded, works with `assets\` absent); `-ExternalAssets` keeps ~136 KB with relative asset references |
| `scan_latest.*` | Reference report used by the plan and the GUI |
| `plan_<timestamp>.json` | Candidate actions derived from a report |
| `apply_<timestamp>.json` / `.log` | Per-action results and the run transcript |
| `cleanup_<timestamp>.json` | Audit manifest of each `out\` cleanup (never deleted by it) |
| `undo\` | Registry exports and other rollback material |

The `out\` folder can be emptied of its timestamped reports from the GUI
("Clean out\") or with `.\tools\Clean-Out.ps1` — an allowlist that deletes only
`scan/plan/apply_<timestamp>.(json|html)` and never touches `*_latest.*`, the
transcripts, the subfolders or anything outside `out\`.

## Feed the report to an AI

A scan leaves two artifacts behind, and both are AI-friendly:

| File | Best for |
|---|---|
| `out\scan_latest.json` | Analysis by an AI assistant: structured, complete, no rendering quirks |
| `out\scan_latest.html` | Reading and sharing: one self-contained file with charts and the verdict banner |

The JSON is a stable, versioned format (`schemaVersion` travels inside the file),
so you can hand it to any assistant and get a real second opinion instead of
guessing what a warning means. Requests that tend to work well:

- *"Explain every CRIT and WARN finding in plain language, in priority order."*
- *"Which findings share a common root cause, and what is the smallest set of
  steps that resolves them all?"*
- *"Give me the exact commands to run, starting with a restore point, and
  explain the risk of each one."*
- *"Read this report as if you were the technician: what would you do first, and
  what would you deliberately not touch?"*

**Two scans are better than one.** Keep the JSON files and ask for a trend:
*"Between this report and the previous one, what changed, and did it get better
or worse?"* — a machine that stops logging ungraceful shutdowns, or whose
component-store history stops growing, is measurably healthier.

**Before you share anything.** Both files contain a machine inventory: host name,
user name, installed applications, services, driver and file paths. Review it, and
strip what you would not publish (at minimum `host.name` and `host.user`), or run
a local assistant instead of a cloud one.

**And the honest limits.** An AI reading the report can explain, prioritise and
draft steps. It cannot see your machine, cannot verify a command you have not run,
and can be confidently wrong about anything the report does not contain. Treat it
as a second opinion to review, not as an instruction to run. The tool's own
guardrails — dry-run first, confirmation, undo material — still apply.

## Architecture

```
oxyde-win-maintenance\
├─ PcScan.ps1               entry: scan (read-only), profiles, health verdict
├─ PcPlan.ps1               entry: scan report -> action plan
├─ PcApply.ps1              entry: dry-run / apply / verify (CLI, interactive)
├─ PcConsole.ps1            entry: WinForms GUI
├─ Start-Console.cmd        launcher: double-click to open the GUI
├─ profiles.psd1            scan profiles (areas, timeouts, network, elevation)
├─ probes\NN-Area.ps1       detection plugins (read-only)
├─ actions\NN-kind.ps1      action handlers (one capability each)
├─ lib\Common.psm1          shared contracts (findings, action results) and helpers
├─ render\Report-Html.ps1   renderer orchestrator (asset mode, writers)
├─ render\Report-View.ps1   report view model (findings -> stable object)
├─ render\Report-Sections.ps1  HTML section builders (tabs, areas, data, probes)
├─ assets\vendor\           pinned report libraries, embedded or referenced
├─ assets\report\           own stylesheet + script of the report
├─ tools\Fetch-Assets.ps1   re-downloads the vendored assets (maintenance only)
├─ tools\Clean-Out.ps1      CLI cleanup of out\ (allowlist: timestamped reports only)
├─ tools\Test-Smoke.ps1     regression smoke tests (126 assertions, zero deps, no network)
├─ docs\                    GUIDE / DECISIONS / ROADMAP (local only, not shipped)
├─ roadmap\                 planning + verification notes (local only, not shipped)
└─ out\                     reports, plans, apply results, transcripts, undo\
```

Two rules keep it extensible without a framework: a probe is one file named
`NN-Area.ps1`, and an action is one file named `NN-kind.ps1`. Both are discovered
automatically and communicate through JSON contracts, so adding capability never
means touching the engine.

## Documentation

The maintainer keeps these documents in the working copy, but they are **working
material and are not part of the repository** (see `.gitignore`). If you have
received only the repository, this README is enough to get started.

| Document | Purpose |
|---|---|
| `docs/GUIDE.md` | How to use it, all commands and options, how to add a probe or an action |
| `docs/DECISIONS.md` | ADR-style decision log (why the tool is built the way it is) |
| `docs/ROADMAP.md` | Phase status and the confirmed plan |
| `roadmap/` | Planning notes and verification reports, one file per decision cycle |

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Scan and report: engine, probes, JSON schema, HTML report | done (schema v5: profiles, health verdict, coverage disclosure, offline report; 14 areas: quick = real health check, standard/deep = full picture incl. autostart, update health, disk health) |
| 2 | Actions: plan -> dry-run -> apply, with guardrails and verification | in progress: restore point, winget upgrades, service-delete, shadow-resize and integrity-repair implemented (5 of 7); app and cache cleanup, update install next |
| 3 | Packaging, regression tests and distribution | planned |

The tool is a work in progress. Behaviour, schema and file layout may change
between versions.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built into Windows; no installation needed)
- Optional: `winget` (App Installer) for the package-upgrade area
- Network access only for the areas that declare `Requires network`
- Administrator rights only for apply operations and for the `deep` profile

## Privacy

Everything runs **locally on the machine**. The tool does not phone home, does
not upload anything, and has no telemetry. Reports contain a machine inventory
(OS, hardware, installed applications, services, problem devices) — treat the
`out\` folder as private data and do not publish it without reading it first.

## Disclaimer

This is a hobby project written for personal use and for friends. It is **not**
affiliated with, endorsed by, or supported by Microsoft or any hardware vendor.

It is provided **"as is", without warranty of any kind**, and is not a
professional product. It is **not** a substitute for a backup, for vendor
support, or for professional IT advice.

You run it on your own machines, at your own risk. Actions are system-changing by
definition. Always keep a tested backup, always read the dry-run output, and
never apply changes to a machine you cannot restore. The authors are not liable
for any damage, data loss, or downtime arising from the use of this software.

## AI assistance

This project was **developed with the assistance of AI coding agents**. The
architecture, the safety model, the design decisions, the code and this
documentation were produced and reviewed in an iterative loop between a human
maintainer and AI agents. Review everything before you trust it on a machine you
care about.

## License

Released into the **public domain** under [The Unlicense](https://unlicense.org/).
Do whatever you want with it — copy it, change it, ship it, sell it, ignore it.

```
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.

In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to the
detriment of our heirs and successors. We intend this dedication to be an overt
act of relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org/>
```