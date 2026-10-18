# oxyde-win-maintenance — Implementation note _1

> **Owner:** implementation & development role. Turns accepted planning notes
> into executable, file-by-file implementation plans and then executes them.
> This role writes product code.
>
> **Naming convention:** `_<n>_<yyyyMMdd_HHmm>_implementation.md` — companion
> of the same-numbered planning note (`_<n>_<yyyyMMdd_HHmm>.md`); one
> implementation note per planning note.
>
> **Companion of:** `_1_20261018_0931.md` (Repository analysis and direction).
> **Language:** English, per DECISIONS D1.

---

## _1-impl — 2026-10-18 — Claim verification and P0 implementation plan

**Status:** verification complete; plan ready to execute.

### 1. Verification of the planning note's claims

Method: repository inspection (`PcScan.ps1`, `lib\Common.psm1`,
`probes\21-Winget.ps1`, `render\Report-Html.ps1`), latest scan artifacts
(`out\scan_20261018_091729.json`, `out\scan_20261018_092809.json`), `git status`,
live machine probes.

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | "Unparseable winget output" classified `INFO` in latest scans | **CONFIRMED** | Both scans: finding `winget-parse`, `[INFO]`, exit 0, with valid data visibly present ("Microsoft.Edge 155.0.4283.45 -> 155.0.4283.62"). |
| 2 | Root cause not stated in the plan | **RESOLVED HERE** | With redirected stdout (no console) winget lays columns out with **single-space separators**; the parser (line 44) requires `\s{2,}`. Raw sample: `Sottosistema·Windows·per·Linux·Microsoft.WSL·2.7.3.0··2.7.13`. |
| 3 | 27.6 s scan dominated by WU 10.5 s, winget 5 s, drivers 3.5 s | **CONFIRMED** | 09:17 run: WU 10457 ms, Winget 5052 ms, Drivers 3558 ms, total 27632 ms. Note large variance: 09:28 run 23.2 s (WU 8607, winget 2065, drivers 6308). |
| 4 | `PcScan` synopsis/`-Areas` comment misses the `Drivers` area | **CONFIRMED** | `PcScan.ps1` line 15 lists 5 areas; probes dir has 7 (missing Drivers; GUIDE already fixed). |
| 5 | Probes run sequentially; single global 300 s timeout; no per-probe timeout | **CONFIRMED** | `PcScan.ps1` foreach + `$TimeoutSeconds = 300`; no per-probe map. |
| 6 | `New-Finding` has no `category`/`weight` (no scoring possible) | **CONFIRMED** | Params: Id, Area, Title, Status, Evidence, SuggestedAction, AdminRequired, Source, ActionKind, ActionPayload. |
| 7 | Uncommitted work list | **CONFIRMED, incomplete** | Plan omits `probes\20-Apps.ps1` (D13 UserAssist) and `probes\21-Winget.ps1`; `roadmap\` itself is untracked. D13 now exists (plan says D1–D12). |
| 8 | Report is CDN-only (5 vendors) | **CONFIRMED** | jsdelivr bootstrap 5.3.3 / icons 1.11.3 / chart 4.4.1, jquery 3.7.1, datatables 1.13.8, google fonts Inter 5 weights. |
| 9 | No tests/CI | **CONFIRMED** | No `tests\`, no CI files. |
| 10 | Real-session issues (Defender off, LibreOffice service, pending reboot, CrossDevice 18.7 GB) | **HISTORICAL, mixed now** | Defender **now active** (RTP on, signatures 18/10 02:31) and pending-reboot keys **clean** and CrossDevice **0 GB** — remediated during the manual session. LibreOffice Maintenance Service **still present** (stopped) — current example of residue the tool does not flag. The coverage-gap table stands. |

Conclusion: the planning note is accurate. NICs: claim list #7 incomplete,
D13 append. The headline failure (claim 1) is real, present on this host, and
fully diagnosed.

### 2. Implementation stance and adjustments

Direction (verdict + safe guided fixes, offline report, quick default,
declared deep scan) is accepted as-is. Adjustments proposed by this role:

1. **Execution order** (each step independently shippable):
   A. Hygiene commit of the pending work (also unblocks clean diffs for P0).
   B. Winget fix (smallest, real bug, root cause already diagnosed — warm-up).
   C. Profiles + WU light mode + `41-PendingReboot` (see 3 below).
   D. Health verdict (schema v5, exit codes).
   E. Offline assets.
   F. GUI health-check UX.
   G. Docs + acceptance run.
2. **Quick-profile dependency:** the quick content listed in the plan
   (space, Defender, events) needs P1 probes that do not exist yet. Interim
   quick = existing fast probes + WU light mode (see §3.1). Recommend pulling
   `41-PendingReboot.ps1` forward into P0: trivial, and it detects a
   high-signal issue from the real session.
3. **Probe contract extension without breaking probe CLIs:** the active
   profile is passed to probes via environment variable `OXYDE_PROFILE`
   (children inherit it; probes opt in by reading it). No probe parameter
   changes; `-File` invocations stay valid. Logged as D17.
4. **Default-profile change is breaking** (`PcScan.ps1` no-arg was "all
   areas" and feeds `PcPlan` via `scan_latest.json`). Mitigations: GUI gets
   explicit "Health check" (quick) and "Full scan" (standard) buttons;
   `PcPlan` warns when the latest report profile is `quick` (plan would be
   incomplete); docs updated.
5. **winget fix spec** (replaces "parser hardening" hand-waving): see §3.5.
6. **Health scheme made concrete** (score formula, verdict thresholds, exit
   codes): see §3.4. No `weight` field in findings for now — scoring derives
   from `status` only; `category` is added as optional metadata for future
   area-level scoring.
7. **Assets:** pinned versions/dirs and a fetch script instead of manual
   vendoring; renderer resolves assets at render time (local-first, minimal
   inline fallback when missing). ~1.1 MB one-time.
8. **`out\` retention:** prune scan pairs beyond the newest 30 on non-`-Areas`
   runs; never delete `scan_latest.*`.

### 3. P0 implementation plan (executable, file by file)

Version target: `0.5.0` (schema v5). All new UI strings English (D1).

#### 3.1 `profiles.psd1` (new, repo root)

Declarative data file (no code), one entry per profile:

- `areas`: candidate probe areas.
- `timeouts`: per-area nanos **seconds** override for the global
  `-TimeoutSeconds` fallback.
- `network`: areas requiring network (labelled in report; never a silent
  failure).
- `deep`: `$true` for the deep profile (elevation required; declared).

Content:

| Profile | Areas | Notable timeouts | Network | Admin |
|---|---|---|---|---|
| `quick` | WindowsUpdate (light), Apps, Appx, PendingReboot, OrphanServices, SystemProtection | WU 60, others 60 | WindowsUpdate | no |
| `standard` | all current 7 + PendingReboot | WU 120, Winget 180, Drivers 90 | WindowsUpdate, Winget | no |
| `deep` | all (future: Integrity, EventLog, Storage, Security, Space) | WU 300, integrity 900 | WindowsUpdate, Winget | yes |

Interim (P0) `deep` = `standard` areas, elevated, declared adminUsed in
report; P1 probes join as they land.

#### 3.2 `PcScan.ps1` (modify)

- New param `[ValidateSet('quick','standard','deep')][string]$Profile = 'quick'`.
- Load `profiles.psd1` (Import-PowerShellDataFile); select probes by
  `profile.areas`; `-Areas` still filters further (explicit CLI wins).
- Per-probe timeout = `profile.timeouts[area]` else `$TimeoutSeconds`.
- Set `$env:OXYDE_PROFILE` before the probe loop; restore after.
- `probeRuns` gains `network` (bool) and `timeoutSeconds` (int, effective).
- Health block + exit codes (§3.4); schemaVersion = 5; `health.profile`,
  `health.adminUsed`.
- Retention: on non-`-Areas` runs, keep newest 30 `scan_*.json`/`scan_*.html`
  pairs.
- `-Version` switch: prints `oxyde-win-maintenance <version> (schema v5)` and
  exits 0. Version constant lives in `lib\Common.psm1`.
- Synopsis/`-Areas` comment: list all areas incl. Drivers + document profiles.

#### 3.3 `lib\Common.psm1` (modify)

- `New-Finding`: add optional `[string]$Category = ''` (metadata only).
- Add `$script:OxydeVersion = '0.5.0'` + `Get-OxydeVersion`.
- No signature breaks: all new params optional/trailing.

#### 3.4 Health verdict (inside `PcScan.ps1`)

- Score: `100 - 25*crit - 8*warn`, clamped to 0..100 (INFO/OK never
  penalize; unknown/INFO never count as healthy by construction).
- Verdict: any CRIT → `CRITICAL`; else any WARN → `WARNING`; else `OK`.
- `health = { score, verdict, counts{crit,warn,info,ok}, topIssues[<=5]
  {id,area,title,status}, profile, adminUsed }`.
- Exit codes: `0` OK, `1` WARNING, `2` CRITICAL (probe failure = CRIT path).
- Renderer and GUI read `health`; absent block (v4 report) → no banner.

#### 3.5 `probes\21-Winget.ps1` (modify — fix + hardening)

- Before invoking winget: `[Console]::OutputEncoding = UTF8` (restore after).
- Row regex tolerant of narrow single-space layout, anchored by ID:
  `^(?<name>.+?)\s+(?<id>[^\s]*\.[^\s]+)\s+(?<ver>[0-9][^\s]*)\s+(?<avail>[0-9][^\s]*)(?:\s+(?<src>winget|msstore))?\s*$`
  (backtracking resolves names containing dotted tokens, e.g. `Python 3.12.9`
  → id `Python.Python.3.12`; verified by dry-run against the raw sample).
- Footer/blank handling: stop the data region at blank line after rows or at
  `^\d+\s+(aggiornamenti|updates)|updates? available|aggiornamenti disponibili`.
- Classification: rows parsed → WARN summary (as today). Exit ≠ 0 →
  **WARN** `winget upgrade failed (exit N)` (not INFO). Rows 0 + non-empty
  unparsed → **WARN** `Unparseable winget output` with raw first lines
  (never silent INFO). All winget findings get evidence line
  `Requires network`.
- Limitation accepted: msstore IDs (dot-less) are out of scope — probe uses
  `--source winget` only.

#### 3.6 `probes\10-WindowsUpdate.ps1` (modify — light mode)

- If `$env:OXYDE_PROFILE -eq 'quick'`: skip the COM search (current dominant
  cost 8.6-10.5 s); keep last installed hotfix + service state (target
  < 2 s); finding `INFO` "Pending updates: not checked in quick profile" and
  set dataset `updates = @()` with a `profile-limited` marker.
- Standard/deep unchanged.

#### 3.7 `probes\41-PendingReboot.ps1` (new — recommended pull-forward)

- Checks: CBS `RebootPending`; WU `RebootRequired`; HKLM Session Manager
  `PendingFileRenameOperations` (count + first 5 entries); pending computer
  rename (ActiveComputerName vs ComputerName).
- Any pending → `WARN` with typed evidence; none → `OK`. < 200 ms. No admin.
- Quick + standard + deep profiles.

#### 3.8 `render\Report-Html.ps1` (modify)

- Hero verdict banner when `health` present: score, verdict color, profile +
  adminUsed badges, top issues list.
- Asset resolution at render time: if `assets\vendor\bootstrap\bootstrap.min.css`
  exists → relative links from the HTML output dir to `assets\vendor\...`
  (small relative-path helper; PS5.1 has no `GetRelativePath`); if the report
  is rendered to a custom OutDir without a resolvable path → minimal inline
  fallback (plain but readable: system font stack, inline table CSS; skip
  DataTables/Chart init via feature guards `if (window.jQuery)` etc.).
- No CDN links remain in the emitted HTML (D5 superseded by D16).

#### 3.9 `assets\vendor\` + `tools\Fetch-Assets.ps1` (new)

Fetch script (TLS 1.2, idempotent, prints sizes) downloads pinned files:

| Dir | Files | Version |
|---|---|---|
| `bootstrap\` | bootstrap.min.css, bootstrap.bundle.min.js | 5.3.3 |
| `bootstrap-icons\` (+ `fonts\`) | bootstrap-icons.min.css, fonts\bootstrap-icons.woff2 | 1.11.3 |
| `jquery\` | jquery-3.7.1.min.js | 3.7.1 |
| `datatables\` | dataTables.bootstrap5.min.css, jquery.dataTables.min.js, dataTables.bootstrap5.min.js | 1.13.8 |
| `chartjs\` | chart.umd.min.js | 4.4.1 |
| `inter\` | inter.css (@font-face, latin) + Inter-{400,500,600,700,800}.woff2 | gstatic latin |

Total ~1.1 MB. `assets\` is committed (small, version-pinned) so any copy of
the repo works offline; `tools\` is dev-only.

#### 3.10 `PcConsole.ps1` (modify)

- Toolbar: primary **"Run health check"** (quick profile, no admin; on
  completion shows the verdict banner: colored score card + top issues) +
  secondary **"Full scan"** (standard) + **"Deep scan (admin)"** (single UAC,
  declared).
- Verdict banner reads the `health` block of the newest report.
- "Issues only" checkbox filtering the findings grid (hides INFO/OK),
  auto-enabled after a health check.
- Existing Actions/Apply flow untouched (still uses plan built from the
  chosen report; warn if the source report was quick).

#### 3.11 `PcPlan.ps1` (modify — guard)

- If `scan_latest.json` profile is `quick`: print prominently
  `Warning: latest scan used the quick profile; plan may miss winget/driver
  actions. Run: .\PcScan.ps1 -Profile standard`.

#### 3.12 Docs

- `docs\GUIDE.md`: profiles table, quick-start with verdict + exit codes,
  offline note, PendingReboot area row, Drivers synopsis alignment.
- `docs\DECISIONS.md`: D14 (scan profiles), D15 (health score/verdict/exit
  codes), D16 (vendored assets — supersedes D5 CDN clause), D17
  (`OXYDE_PROFILE` env contract).
- `docs\ROADMAP.md`: P0 items status; P1 probe table acknowledged.

### 4. Acceptance tests (executed in step G)

1. `.\PcScan.ps1 -Profile quick -Open` → verdict banner + score; **< 10 s**;
   `$LASTEXITCODE` ∈ {0,1,2} consistent with verdict.
2. `.\PcScan.ps1` (= quick default) → same as (1) (documented behavior
   change).
3. `.\PcScan.ps1 -Profile standard` → winget rows parsed (this host has 1-2
   upgrades); no `Unparseable` INFO; WARN evidence labelled "Requires
   network".
4. Offline render: temporarily rename `assets\` → re-render → readable
   minimal report, no CDN requests in emitted HTML (grep `https://cdn`/`code.jquery`/`fonts.googleapis` = 0 hits).
5. `.\PcScan.ps1 -Version` → single line, exit 0.
6. GUI: health check button → banner; issues-only filter; full scan works.
7. `.\PcPlan.ps1` with quick latest → warning printed; with standard → no
   warning.
8. `41-PendingReboot`: finding present on quick runs; OK path on this host
   (keys currently clean).

### 5. Risks / open points

- Narrow-layout winget parsing stays regex-based: unexpected future layouts
  must degrade to WARN with evidence (by design, never silent).
- Interim `deep` profile is `standard` + elevation until P1 probes exist —
  the report must say so (`adminUsed` + profile badges).
- Default-profile flip: any external script calling bare `PcScan.ps1`
  expecting full scan must move to `-Profile standard` (documented; PcPlan
  guard).
- Google Fonts vendoring depends on gstatic URLs stability at fetch time
  (pinned at execution, files committed thereafter).
- OneDrive location remains a sync/perf liability (move deferred per plan).

### 6. Out of scope (next implementation notes)

- P1 probes (05-Integrity, 06-EventLog, 31-Storage, 60-Security, 70-Space,
  80-Startup, 90-UpdateHealth) — companion note per probe batch.
- P2 actions (wu-install, app-uninstall, service-delete, integrity-repair,
  hibernation, clean-caches, defender), packaging, tests/CI, trend baseline.
