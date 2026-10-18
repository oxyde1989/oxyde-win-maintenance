<div align="center">

# oxyde-win-maintenance

**A portable, read-only-first Windows health check you can run on any PC — with a verdict, a shareable report, and guarded fixes when you ask for them.**

[![License: Unlicense](https://img.shields.io/badge/license-Unlicense-blue.svg)](https://unlicense.org/)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-blue.svg)](https://learn.microsoft.com/powershell/scripting/overview)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-lightgrey.svg)](https://learn.microsoft.com/windows/)
[![Version](https://img.shields.io/badge/version-0.6.0-informational.svg)](#)
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
| **Verdict + score** | `100 − 25×critical − 8×warning`, clamped, with a machine-readable `health` block and an exit code for scripting. |
| **Fast by default** | The `quick` profile finishes in under 10 seconds on a mid-range PC. |
| **Honest about coverage** | Areas that need network or elevation are declared in the report instead of silently skipped. |
| **Reportable** | A polished HTML report that renders **offline** (assets are vendored locally), plus the raw JSON. |
| **Guarded fixes** | Actions come only from a catalog, default to dry-run, are confirmed one by one, and are verified by re-scanning the affected areas afterwards. |
| **No dependencies** | PowerShell 5.1 and Windows built-ins only. `winget` is optional. |
| **Auditable** | ADR-style decision log, planning notes, transcripts and machine-readable results for every run. |

## Quick start

**GUI (no commands):** double-click `Start-Console.cmd`, press
**Run health check**, read the colored verdict banner.

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
Verdict: WARNING (score 76) [partial coverage]
CRIT 0 | WARN 4 | INFO 6 | OK 5  (6741 ms)
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
| `standard` | All areas: full update search, apps, winget, AppX, drivers, integrity/events/space/security, firewall, System Protection | no | ~25 s |
| `deep` | As `standard` + the elevated DISM `/ScanHealth` + `sfc /verifyonly` integrity run; elevation declared in the report | yes | minutes |

Areas that inherently need the internet (the update search, winget) are labelled
`Requires network` in the report; they are never silently reported as "clean" when
they could not run. When something was skipped (profile or `-Areas` filter, missing
elevation), the verdict is labelled `(partial)` and `health.coverage` lists exactly
what did not run.

## Scan areas

| Area | What it looks at | Profile |
|---|---|---|
| `Integrity` | Component-store health: current CBS sessions, servicing-archive corruption history; deep adds DISM/SFC | quick / standard / deep |
| `EventLog` | Ungraceful shutdowns (Kernel-Power 41 / 6008), bug checks (BSOD), top recurring system errors | quick / standard / deep |
| `Space` | Free space per drive, main consumers, pagefile, shadow storage (needs elevation) | quick / standard / deep |
| `Security` | Defender status + signature age, AV residue (Security Center), firewall profiles | quick / standard / deep |
| `WindowsUpdate` | Pending updates, last installed hotfix, update service state | quick / standard / deep |
| `PendingReboot` | CBS servicing state, `RebootRequired`, `PendingFileRenameOperations`, pending rename | all |
| `OrphanServices` | Services whose `ImagePath` points to a file that no longer exists | all |
| `Apps` | Installed application inventory, broken uninstall entries, last-used history | standard / deep |
| `Winget` | Package upgrades available through winget | standard / deep |
| `Appx` | Per-user AppX/MSIX packages | standard / deep |
| `Drivers` | Problem devices (Device Manager style, with installed driver version) and driver inventory | standard / deep |
| `SystemProtection` | System Protection state and restore point age | standard / deep |

Still on the way: **disk health** (SMART/reliability) and **startup entries** — see
the [roadmap](#roadmap).

## Actions

An action is only ever proposed when a finding explicitly opts into one. Every
action runs dry-run first and prints the exact command it would execute.

| Action | What it does | Status |
|---|---|---|
| `restorepoint` | Creates a system restore point (throttle-aware) before any change | implemented |
| `winget-upgrade` | Upgrades packages, bulk or one by one, with reboot hints | implemented |
| `wu-install` | Installs specific pending updates | planned |
| `app-uninstall` | Removes applications (MSI / quiet / AppX) | planned |
| `service-delete` | Removes leftover services, exporting the registry key for undo | planned |
| `integrity-repair` | DISM component-store repair + SFC | planned |
| `clean-caches` | Recovers space from caches and leftovers | planned |

## Safety rails

These apply to every capability, without exception:

- **Scanning is read-only.** No probe modifies the machine.
- **Dry-run is the default.** Applying requires an explicit switch.
- **Catalog only.** Actions run from `actions\`, never arbitrary shell commands.
- **Confirmation per action** in the CLI (`y` apply, `n` skip, `s` skip all); the
  GUI shows a preview and one confirmation dialog.
- **One UAC prompt per batch**, never one per action.
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
| `scan_<timestamp>.html` | Shareable report, renders offline |
| `scan_latest.*` | Reference report used by the plan and the GUI |
| `plan_<timestamp>.json` | Candidate actions derived from a report |
| `apply_<timestamp>.json` / `.log` | Per-action results and the run transcript |
| `undo\` | Registry exports and other rollback material |

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
├─ render\Report-Html.ps1   HTML renderer
├─ assets\vendor\           pinned report assets, so the report renders offline
├─ tools\Fetch-Assets.ps1   re-downloads the vendored assets (maintenance only)
├─ docs\                    GUIDE.md, DECISIONS.md, ROADMAP.md
├─ roadmap\                 planning notes + verification reports
└─ out\                     reports, plans, apply results, transcripts, undo\
```

Two rules keep it extensible without a framework: a probe is one file named
`NN-Area.ps1`, and an action is one file named `NN-kind.ps1`. Both are discovered
automatically and communicate through JSON contracts, so adding capability never
means touching the engine.

## Documentation

| Document | Purpose |
|---|---|
| [`docs/GUIDE.md`](docs/GUIDE.md) | How to use it, all commands and options, how to add a probe or an action |
| [`docs/DECISIONS.md`](docs/DECISIONS.md) | ADR-style decision log (why the tool is built the way it is) |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Phase status and the confirmed plan |
| [`roadmap/`](roadmap/) | Planning notes and verification reports, one file per decision cycle |

## Roadmap

| Phase | Scope | Status |
|---|---|---|
| 1 | Scan and report: engine, probes, JSON schema, HTML report | done (schema v5: profiles, health verdict, offline report, quick = real health check) |
| 2 | Actions: plan -> dry-run -> apply, with guardrails and verification | in progress: restore point + winget upgrades implemented; orphan-service removal, app uninstall, update install next |
| 3 | Reverse engineering (REA) for silent-uninstall discovery, driver packages | planned |

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