# oxyde-win-maintenance — Implementation note _2

> **Owner:** implementation & development role. Turns accepted planning notes
> into executable, file-by-file implementation plans and then executes them.
>
> **Naming convention:** `_<n>_<yyyyMMdd_HHmm>_implementation.md` — companion
> of the same-numbered planning note; one implementation note per planning note.
>
> **Companion of:** `_2_20261018_0954.md` (P0 verification and P1 plan).
> **Language:** English, per DECISIONS D1.

---

## _2-impl — 2026-10-18 — Residual verification and P1 Batch 1 plan

**Status:** residuals verified; plan ready to execute.

### 1. Verification of the residuals and of the technical assumptions

Method: independent executions on this host (unelevated session), code
inspection, timing with `System.Diagnostics.Stopwatch`.

#### 1a. Residual issues R1–R5

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| R1 | A quick scan can report healthy with incomplete coverage | **CONFIRMED** | `wu-summary` in quick is `INFO` ("Pending updates: not checked") and only WARN/CRIT demote the verdict (D15). On a host without other findings the verdict would be `OK`. Nuance: `wu-last-hotfix` WARN >45 days partially suppresses the stalled-updates case, but the verdict itself ignores coverage. |
| R2 | Score double-counts item + summary findings | **CONFIRMED** | Quick 84 = 100 − 8×2 where the two WARNs are one issue (`Orphan service: LibreOfficeMaintenance` + `Orphan services found: 1`). Also latent in `wu-summary` (duplicates per-update findings) and the Apps/Appx/Drivers roll-ups. |
| R3 | `-Profile deep` from CLI does not elevate or warn | **CONFIRMED** | PcScan has no elevation logic (`Test-IsAdmin` used only for `health.adminUsed`); only the GUI elevates. Report says `profile=deep, adminUsed=false`. |
| R4 | "D13 uses `-` while D1–D12 use `—`" | **NOT CONFIRMED as stated** | Actual drift: D1–D9 use `-`, D10–D17 use `—`. D13 is consistent with D10–D17. The real fix is normalizing D1–D9 to `—`. |
| R5 | `quick` is still thin (3 areas) | **CONFIRMED (by design)** | `profiles.psd1` quick = WindowsUpdate(light) + PendingReboot + OrphanServices. Batch 1 closes it. |

#### 1b. Technical assumptions for the Batch 1 probes (measured now)

| Assumption | Result | Consequence for the design |
|---|---|---|
| CBS.log readable unelevated | **YES** (2 MB, tail read ~50 ms; recent sessions all `RepairNeeded: no`) | Quick integrity check reads the CBS tail directly. |
| Historical corruption data available | **YES** — `CbsPersist_20261017150005.log` (133 MB, readable): 402 `Payload Corrupt` hits, line `CSI Payload Corruption: 401` at 2026-10-17 16:27:33 | Quick reports the archive history (INFO) + current CBS state (WARN if `RepairNeeded: yes`). |
| Fast full scan of a 133 MB log | **YES** — ReadAllBytes 46 ms + ASCII decode 138 ms + literal `IndexOf` count 507 ms ≈ **0.7 s** (the naive regex-per-chunk approach took 131 s: rejected) | Integrity quick uses bytes→ASCII→IndexOf, size-capped at 256 MB. |
| EventLog queries | **YES** — Kernel-Power 41 / 6008 / 1001 over 90 d: 27 events in **229 ms** (13×41 + 14×6008, last 2026-10-17); System Level 1–2 over 30 d: 69 events in **173 ms** (top: SCM 7000 ×36, 7009 ×18) | Quick runs both queries. Use `-MaxEvents` (not `-Maximum`). |
| Shadow storage without elevation | **NO** — `vssadmin list shadowstorage` exits 2 ("requires elevation") | **Deviation from the planner's acceptance #2**: quick reports shadow storage as INFO "requires elevation"; real values come from the elevated deep scan. |
| Defender status | **0.86 s** `Get-MpComputerStatus` (RTP on, signatures 2026-10-18) | Defender-lite goes in quick; it exceeds the planner's 0.5 s guidance but is the highest-value check. |
| AV residue detection | **YES** — SecurityCenter2 entry `Malwarebytes` with `MBAMWsc.exe` **missing** → exactly the real-session residue pattern; query costs 64 ms | WSC residue check runs in quick-lite (cheap, real finding on this host). |
| Firewall query | **2.7 s** `Get-NetFirewallProfile` (cold module load) | Firewall stays in standard/deep only — too heavy for quick. |
| pagefile / hiberfil | CIM `Win32_PageFileUsage` works (2048 MB); `Get-Item` on `pagefile.sys`/`hiberfil.sys` is denied/absent; hibernation is off on this host | Space uses CIM for pagefile, best-effort item for hiberfil. |
| Temp walk | Uncapped walk of %TEMP%: 370 MB / 1 461 files in 760 ms; naive PS `-Recurse` took 1 956 ms | Space uses a .NET capped enumerator (20 000 files / 1.2 s per root), reporting "≥X" when capped. |
| Child-process spawn overhead | **~250 ms warm** (was the main quick-budget risk) | 7 quick probes ≈ 1.75 s spawn + ~5 s work ≈ 7 s engine; batching stays a documented fallback, not needed. |

### 2. Design decisions for Batch 1

1. **R1 — `health.coverage`** (additive, schema stays v5):
   `coverage = { areasRun[], areasSkipped[], networkDependent[], elevated,
   deepWithoutElevation, partial }`. `partial = areasSkipped.Count > 0 or
   deepWithoutElevation`. Renderer pill and GUI banner append " (partial)"
   when `partial`; the report hero shows `coverage: X/Y areas` with the
   skipped list in the tooltip. The verdict is NOT demoted (score stays
   findings-driven); coverage is displayed, not hidden. The `_1` risk note
   ("unknown must never count as healthy") is satisfied by disclosure.
2. **R2 — summary findings excluded from score and topIssues.** Roll-up
   findings get `category = 'summary'` (the field exists since D15):
   Orphan summary, WindowsUpdate summary, Apps/Appx/Drivers summaries.
   The **winget summary is NOT tagged**: it is the only finding for that
   area (no duplicate) and available package updates are scored like pending
   updates. Score and `topIssues` use findings with
   `category ≠ 'summary'`; `health.counts` keeps raw counts (documented).
   Deviation from `_2`'s arithmetic: standard becomes **68** (4 scored
   issues: 2 broken uninstall entries + orphan + winget), not 76; quick with
   Batch 1 becomes **84** on this host (orphan + Malwarebytes residue — see
   decision 4), i.e. the same 84 as today but now for two *real* issues
   instead of one double-counted (a host without the residue gets 92).
3. **R3 — deep without elevation**: console `Write-Warning` + engine-level
   finding `engine-deep-unelevated` (Area `System`, INFO, title "Deep profile
   requested without elevation: elevated checks are skipped"), plus
   `coverage.deepWithoutElevation = true`. No CLI self-elevation (surprising
   UAC from a scan is against D7's spirit; the GUI deep button elevates).
   `System` becomes the first engine-generated area — renderer gets a
   fallback tooltip for unknown areas (verify it degrades).
4. **Malwarebytes WSC residue is a real finding**: Security-lite in quick
   includes Defender status + SecurityCenter2 residue (0.9 s), firewall
   excluded. Accepted consequence: quick verdict on this host stays WARNING
   with a genuinely new issue surfaced.
5. **Version 0.6.0** (additive health fields; schema v5 unchanged; v4/v5
   readers unaffected). `profiles.psd1`: quick gains
   Integrity, EventLog, Space, Security; standard/deep gain the four probes
   (deep: Integrity timeout 900 s for DISM/SFC, Security 300 s).
6. **Extra verified correction (R4, actual)**: normalize DECISIONS D1–D9
   headings from `-` to `—` (9 lines, docs-only commit at the end).
7. **Localized parsing** (CBS/DISM/sfc/vssadmin output can be Italian):
   prefer language-neutral markers (registry keys, CIM); where text parsing
   is unavoidable (DISM/SFC summaries, vssadmin) match both English and
   Italian markers and fall back to the raw tail in the evidence.

### 3. Batch 1 implementation plan (executable, file by file)

#### 3.1 `probes/05-Integrity.ps1` (new; quick read + deep run)

- **Quick (always)**
  - CBS tail: last 2 MB of `C:\Windows\Logs\CBS\CBS.log` via FileStream
    (verified readable unelevated); parse the last occurrences of
    `Session: ... RepairNeeded: (yes|no) ... Reboot required: (yes|no)`.
    Any recent `yes` → WARN, else OK ("no pending servicing repairs").
    Access denied → INFO with elevation hint (covered by coverage.gaps).
  - Archive: newest `CbsPersist_*.log` (max 256 MB, else tail-capped with a
    note): bytes → ASCII → `IndexOf` for `Payload Corrupt` (count + last
    line's leading timestamp + last `CSI Payload Corruption: N` summary).
    History found → INFO "Component store: N corruption markers in the
    servicing archive (last: date)" — historical context, not a current
    fault; dataset rows for both sources.
  - Datasets: `integritySessions` {source, sessions, repairNeeded, rebootRequired, last}, `integrityArchive` {file, sizeMB, payloadCorruption, lastMarkerAt}.
- **Deep branch** (only when `OXYDE_PROFILE=deep`, elevated): run
  `DISM /Online /Cleanup-Image /ScanHealth` then `sfc /verifyonly`
  (timeout 900 s), parse EN/IT summary markers, fall back to output tail in
  the evidence; unelevated deep → INFO "skipped: requires elevation".
- Read-only (D3); no elevation for the quick part.

#### 3.2 `probes/06-EventLog.ps1` (new; quick)

- Kernel-Power 41 / EventLog 6008 / BugCheck 1001 over 90 days
  (one `Get-WinEvent -FilterHashtable` query, verified 229 ms).
- Combined 41+6008 → WARN "Ungraceful shutdowns: N in the last 90 days
  (last: date)" + guidance (power loss / crash / forced power-off).
  1001 → WARN "Bug checks (BSOD): N" with the last event's summary line.
- Top recurring System errors: Level 1–2, 30 days, `-MaxEvents 3000`,
  grouped by Provider|Id, top 5 → INFO + dataset.
- Datasets: `shutdownEvents` {type, count, last}, `topSystemErrors` {provider, id, count, last, sample}.
- Verified signal on this host: 13×41 + 14×6008 (last 2026-10-17);
  top errors SCM 7000 ×36, 7009 ×18.

#### 3.3 `probes/70-Space.ps1` (new; quick + deep extras)

- Drives (fixed) from `Win32_LogicalDisk`: WARN per drive < 10% free or
  < 15 GB free; free/total values in the summary evidence.
- Consumers (capped .NET enumerator: 20 000 files / 1.2 s per root, "≥" when
  capped): `$env:TEMP`, `C:\Windows\Temp`, WER, `C:\$Recycle.Bin`,
  `C:\Windows.old` (if present).
- pagefile via `Win32_PageFileUsage` (verified); hiberfil via best-effort
  `Get-Item` (absent → note).
- Shadow storage: attempt `vssadmin list shadowstorage`; denied (verified
  exit 2) → INFO "shadow storage: requires elevation (deep scan)"; when
  readable, parse usage/limit with the EN/IT fallback above.
- WinSxS: quick does not measure it (cost); deep (elevated) may run
  `Dism /Online /Cleanup-Image /AnalyzeComponentStore` — implemented only if
  it parses cleanly; otherwise deferred to Batch 2.
- Datasets: `spaceConsumers` {item, path, sizeMB, note}, `shadowStorage` {usedGB, maxGB, source}. Findings: per-drive WARN + INFO summary (total recoverable candidates).

#### 3.4 `probes/60-Security.ps1` (new; quick-lite + full)

- Quick-lite: `Get-MpComputerStatus` (RTP off → **CRIT**; AV off → WARN;
  signature age > 7 d → WARN, else INFO) + SecurityCenter2 products with the
  exe-missing residue check (WARN; verified real finding here) — ~0.9 s.
- Full (standard/deep): + `Get-NetFirewallProfile` (WARN per disabled
  profile; 2.7 s, standard-only).
- Datasets: `avProducts` {product, exe, state}, `firewallProfiles` {name, enabled}.

#### 3.5 Engine changes

- `lib/Common.psm1`: version 0.6.0.
- `PcScan.ps1`:
  - coverage block as in §2.1 (areas discovered vs launched, network from
    the profile, elevated, deepWithoutElevation);
  - score/topIssues skip `category='summary'` (§2.2);
  - deep-unelevated warning + `engine-deep-unelevated` finding (§2.3);
  - console summary prints the partial marker when applicable.
- `profiles.psd1`: quick/standard/deep area lists + timeouts as in §2.5.
- `probes/10-WindowsUpdate.ps1`, `20-Apps.ps1`, `22-Appx.ps1`,
  `30-Drivers.ps1`, `40-OrphanServices.ps1`: add `-Category 'summary'` to
  the roll-up findings (no behaviour change otherwise).

#### 3.6 Renderer and GUI

- `render/Report-Html.ps1`: area tooltips for Integrity, EventLog, Space,
  Security (+ fallback tooltip for engine-generated areas like `System`);
  dataset titles/icons/colLabels for the new datasets; pill + hero " (partial)"
  and `coverage: X/Y areas` with skipped-list tooltip.
- `PcConsole.ps1`: verdict banner appends " (partial)" when
  `health.coverage.partial`; nothing else changes (deep already elevates).

#### 3.7 Docs

- GUIDE: areas table (4 new rows), quick contents update, coverage/partial
  explanation, v0.6.0 note.
- DECISIONS: D18 — coverage disclosure + summary-exclusion scoring (amends
  D15); note in D15 pointing to D18.
- ROADMAP: P1 Batch 1 status section; Batch 2 unchanged.
- DECISIONS: D1–D9 heading dash normalization (extra verified correction).

### 4. Acceptance tests (executed in the final step)

1. `PcScan.ps1 -Profile quick` → **wall < 10 s** and engine < 8 s on this
   host with the 7 areas (measure both; 3 runs, report min/median).
2. Quick findings must include (verified data available):
   - Integrity: archive history "401 payload corruption markers, last
     2026-10-17" (INFO) + current sessions `RepairNeeded: no` (OK);
   - EventLog: ungraceful shutdowns 27 in 90 d (13×41, 14×6008, last
     2026-10-17) (WARN);
   - Space: free space per drive + pagefile 2 048 MB + shadow storage
     "requires elevation" (INFO, documented deviation);
   - Security: Defender RTP on + signature age (INFO/WARN) + Malwarebytes
     WSC residue (WARN);
   - top recurring System errors dataset (SCM 7000/7009).
3. Scoring: no double counting — quick score = `100 − 8×scoredWarn`;
   on this host 84 = 2 distinct issues (orphan + MB residue); assert the
   orphan summary is not counted (remove one WARN → score moves to 92).
4. `PcScan.ps1 -Profile deep` (unelevated): explicit console warning +
   `engine-deep-unelevated` finding + `coverage.deepWithoutElevation=true`
   + pill "(partial)".
5. No regressions: `PcPlan` still yields 3 actions for the 1-row winget
   dataset; `PcApply` dry-run unchanged; schema v5 (no new reader
   breakage); standard profile still completes (adds ~2.5 s for Integrity
   archive + Security full).
6. Every new probe read-only, quick part non-elevated, datasets rendered
   with titles/labels, docs updated (GUIDE/DECISIONS/ROADMAP).

### 5. Risks

- **Quick budget**: measured spawn 250 ms + work ≈ 5 s → ~7 s engine; the
  main variable is the CbsPersist read (0.7 s here, slower on cold/HDD
  hosts): size cap + median-of-3 acceptance; fallback if needed: batch the
  quick probes in one child (documented, not implemented).
- **Localized parsing** of DISM/SFC/vssadmin: EN/IT markers + raw-tail
  fallback; registry/CIM paths preferred everywhere else.
- **SecurityCenter2 residue heuristic** flags stale WSC entries; a product
  installed via WindowsApps path also matches "virtual" forms (handled:
  `windowsdefender://` and `http(s)://` are treated as virtual).
- Deep Integrity (DISM+SFC) is long (minutes): deep-only, elevated,
  timeout 900 s, declared; no impact on quick/standard.

### 6. Out of scope (Batch 2, after verification of Batch 1)

`31-Storage.ps1`, `80-Startup.ps1`, UpdateHealth folded into
`10-WindowsUpdate.ps1`, elevated/hardened deep runs, P2 actions, packaging,
tests/CI, repository move out of OneDrive.
