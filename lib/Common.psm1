# oxyde-win-maintenance - functions shared by the engine, the probes and the action handlers.

$script:OxydeVersion = '0.10.0'

function Get-OxydeVersion {
    return $script:OxydeVersion
}

# Invariant-culture number formatting for evidence strings: machine-readable
# text must be stable regardless of the host locale ("88.6", never "88,6").
function Format-Num {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    try { return ([double]$Value).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return "$Value" }
}

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('OK', 'INFO', 'WARN', 'CRIT')][string]$Status,
        [object[]]$Evidence = @(),
        [string]$SuggestedAction = '',
        [bool]$AdminRequired = $false,
        [string]$Source = '',
        [string]$Category = '',
        [string]$ActionKind = '',
        [object]$ActionPayload = $null
    )
    [pscustomobject]@{
        id              = $Id
        area            = $Area
        title           = $Title
        status          = $Status
        evidence        = @($Evidence | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { "$_" })
        suggestedAction = $SuggestedAction
        adminRequired   = $AdminRequired
        source          = $Source
        category        = $Category
        actionKind      = $ActionKind
        actionPayload   = $ActionPayload
    }
}

function Write-JsonFile {
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $InputObject | ConvertTo-Json -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Write-ProbeResult {
    param(
        [object[]]$Findings = @(),
        $Datasets = @{},
        [Parameter(Mandatory)][string]$OutFile
    )
    $payload = [pscustomobject]@{
        findings = @($Findings)
        datasets = $Datasets
    }
    Write-JsonFile -InputObject $payload -Path $OutFile
}

# Contract object returned by every action handler (see docs\ROADMAP.md).
function New-ActionResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Title = '',
        [Parameter(Mandatory)][ValidateSet('dryrun', 'done', 'failed', 'skipped', 'denied', 'throttled')][string]$Status,
        [ValidateSet('pass', 'fail', 'skipped')][string]$Precheck = 'skipped',
        [string]$Command = '',
        [int]$ExitCode = 0,
        [string]$Output = '',
        [ValidateSet('pass', 'fail', 'unknown', 'skipped')][string]$Verify = 'skipped',
        [string]$UndoHint = '',
        [string]$UndoFile = '',
        [int]$DurationMs = 0,
        [object[]]$Steps = @()
    )
    [pscustomobject]@{
        id         = $Id
        kind       = $Kind
        title      = $Title
        status     = $Status
        precheck   = $Precheck
        command    = $Command
        exitCode   = $ExitCode
        output     = $Output
        verify     = $Verify
        undoHint   = $UndoHint
        undoFile   = $UndoFile
        durationMs = $DurationMs
        # _8 §6: structured per-step records { name, command, startedAt,
        # durationMs, exitCode, tail } so long operations render as a table
        # instead of a wall of text. Empty for single-shot actions.
        steps      = @($Steps)
    }
}

function Write-ActionResult {
    param(
        $Result,
        [Parameter(Mandatory)][string]$OutFile
    )
    Write-JsonFile -InputObject $Result -Path $OutFile
}

# Capped directory walk: skips unreadable folders, stops at the file/time cap
# (naive Get-ChildItem -Recurse is ~2.5x slower and unreadable dirs abort
# EnumerateFiles, so walk per-directory with a stack). Shared by the Space and
# WindowsUpdate probes.
function Get-DirSizeCapped {
    param([string]$Root, [int]$FileCap = 20000, [int]$MsBudget = 1200)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $sum = [long]0
    $files = 0
    $capped = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        if ($files -ge $FileCap -or $sw.ElapsedMilliseconds -gt $MsBudget) { $capped = $true; break }
        $dir = $stack.Pop()
        try { foreach ($f in [System.IO.Directory]::GetFiles($dir)) { try { $sum += (New-Object System.IO.FileInfo($f)).Length; $files++ } catch { } } } catch { }
        try { foreach ($d in [System.IO.Directory]::GetDirectories($dir)) { $stack.Push($d) } } catch { }
    }
    $sw.Stop()
    [pscustomobject]@{ bytes = $sum; files = $files; capped = $capped; ms = $sw.ElapsedMilliseconds }
}

# Deletes only tool-generated artifacts from out\ (timestamped scan/plan/apply
# .json/.html). Allowlist-based and preview-by-default: *_latest.*, *.log files,
# subdirectories (undo\, verify_\...), every other file and anything outside
# out\ survive by design. See docs\DECISIONS.md D20.
function Clear-OxydeOutput {
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$Execute
    )
    $result = [pscustomobject]@{
        exists       = $false
        outDir       = $OutDir
        items        = @()      # candidate files to delete (full paths)
        keep         = @()      # top-level file names that do not match (display)
        removed      = @()
        skipped      = @()
        totalBytes   = [long]0
        manifestPath = ''
        error        = ''
    }
    try {
        if (-not (Test-Path -LiteralPath $OutDir)) { return $result }
        $result.exists = $true
        $rootFull = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\') + '\'
        $pattern = '^(scan|plan|apply)_\d{8}_\d{6}\.(json|html)$'

        $items = New-Object System.Collections.ArrayList
        $keep = New-Object System.Collections.ArrayList
        foreach ($f in @(Get-ChildItem -LiteralPath $OutDir -File -ErrorAction Stop)) {
            $full = [System.IO.Path]::GetFullPath($f.FullName)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($f.Name -match $pattern) { [void]$items.Add($full) } else { [void]$keep.Add($f.Name) }
        }
        $result.items = @($items)
        $result.keep = @($keep)
        foreach ($p in $items) { try { $result.totalBytes += (New-Object System.IO.FileInfo($p)).Length } catch { } }

        if (-not $Execute) { return $result }

        foreach ($p in $items) {
            try {
                $attrs = [System.IO.File]::GetAttributes($p)
                if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) {
                    $result.skipped += [pscustomobject]@{ path = (Split-Path -Leaf $p); reason = 'reparse point (not followed)' }
                    continue
                }
                Remove-Item -LiteralPath $p -ErrorAction Stop
                $result.removed += (Split-Path -Leaf $p)
            }
            catch {
                $result.skipped += [pscustomobject]@{ path = (Split-Path -Leaf $p); reason = "$($_.Exception.Message)" }
            }
        }

        # Audit manifest: its name does not match the deletable pattern, so it
        # survives the next cleanup by construction.
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $manifest = [pscustomobject]@{
            cleanedAt = (Get-Date).ToString('s')
            outDir    = $OutDir
            removed   = @($result.removed)
            skipped   = @($result.skipped)
            keptCount = @($result.keep).Count
        }
        $result.manifestPath = Join-Path $OutDir ("cleanup_$stamp.json")
        Write-JsonFile -InputObject $manifest -Path $result.manifestPath
    }
    catch { $result.error = "$($_.Exception.Message)" }
    return $result
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Extracts the executable path from a service ImagePath and resolves the
# common forms: quotes, arguments, \SystemRoot\, %VAR%, \??\.
function Expand-ImagePath {    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $s = $ImagePath.Trim()

    $path = $null
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 0) { $path = $s.Substring(1, $end - 1) } else { $path = $s.Substring(1) }
    } else {
        $m = [regex]::Match($s, '^(?<p>\S+?\.(exe|sys|dll|com|ocx))(\s|$)', 'IgnoreCase')
        if ($m.Success) { $path = $m.Groups['p'].Value } else { $path = ($s -split '\s+')[0] }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }

    $path = $path -replace '^\\\?\?\\', ''
    $path = $path -replace '^\\SystemRoot\\', ($env:SystemRoot + '\')
    $path = [Environment]::ExpandEnvironmentVariables($path)
    $path = $path -replace '^System32\\', ($env:SystemRoot + '\System32\')
    if ($path -notmatch '[\\/]') { return $null }
    return $path
}

# --- integrity classification helpers (extracted for testability, G2; D23) ---
# The deep Integrity branch needs the CBS.log markers, which are English even
# on localized systems. These pure functions are the tested core; the probe
# feeds them real lines and console flags.

# Newest fresh "Total Detected Corruption: N" in the last detection session.
# Returns -1 when no fresh summary exists. CBS lines are chronological, so the
# LAST matching line is the newest; if it is stale, older ones are staler.
function Get-CbsDetectedCorruption {
    param([string[]]$Lines, [datetime]$Since)
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match("$($Lines[$i])", '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Total Detected Corruption:\s*(\d+)')
        if ($m.Success) {
            $t = $null
            try { $t = [datetime]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch { }
            if ($t -and $t -ge $Since.AddSeconds(-60)) { return [int]$m.Groups[2].Value }
            break
        }
    }
    return -1
}

# Fresh [SR] markers of the verify transaction started by our sfc run.
function Get-CbsSrVerify {
    param([string[]]$Lines, [datetime]$Since)
    $cannot = 0
    $complete = 0
    foreach ($line in $Lines) {
        $m = [regex]::Match("$line", '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[SR\]')
        if (-not $m.Success) { continue }
        $t = $null
        try { $t = [datetime]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch { continue }
        if ($t -lt $Since.AddSeconds(-60)) { continue }
        if ("$line" -match '\[SR\] Cannot repair member file') { $cannot++ }
        elseif ("$line" -match '\[SR\] Verify complete') { $complete++ }
    }
    return [pscustomobject]@{ cannot = $cannot; complete = $complete }
}

# DISM verdict from the parsed signals; clean wins over repairable (C3).
function Get-IntegrityDismDecision {
    param([int]$CbsCount = -1, [bool]$ConsoleClean = $false, [bool]$ConsoleRepairable = $false)
    if ($CbsCount -ge 0) {
        $status = if ($CbsCount -eq 0) { 'OK' } else { 'WARN' }
        $title = if ($CbsCount -eq 0) { 'DISM ScanHealth: component store healthy' } else { ("DISM ScanHealth: component store repairable ({0} payload corruption(s))" -f $CbsCount) }
        return [pscustomobject]@{ status = $status; title = $title; signal = ("Signal: CBS.log Total Detected Corruption={0} (English, language-independent)" -f $CbsCount) }
    }
    if ($ConsoleClean) {
        return [pscustomobject]@{ status = 'OK'; title = 'DISM ScanHealth: component store healthy'; signal = 'Signal: console text (locale-dependent)' }
    }
    if ($ConsoleRepairable) {
        return [pscustomobject]@{ status = 'WARN'; title = 'DISM ScanHealth: component store is repairable'; signal = 'Signal: console text (locale-dependent)' }
    }
    return [pscustomobject]@{ status = 'WARN'; title = 'DISM ScanHealth: result unclear (see output)'; signal = 'Signal: none (classification unclear)' }
}

# SFC verdict from the parsed signals; a completed verify wins over violations
# text from the console (C3).
function Get-IntegritySfcDecision {
    param([int]$SrCannot = 0, [int]$SrComplete = 0, [bool]$ConsoleClean = $false, [bool]$ConsoleViolations = $false)
    if ($SrCannot -gt 0) {
        return [pscustomobject]@{ status = 'WARN'; title = ("SFC verify: integrity violations found ({0} member(s))" -f $SrCannot); signal = ("Signal: CBS.log [SR] Cannot repair member file x{0} (English)" -f $SrCannot) }
    }
    if ($SrComplete -gt 0) {
        return [pscustomobject]@{ status = 'OK'; title = 'SFC verify: no integrity violations'; signal = ("Signal: CBS.log [SR] Verify complete x{0} (English)" -f $SrComplete) }
    }
    if ($ConsoleClean) {
        return [pscustomobject]@{ status = 'OK'; title = 'SFC verify: no integrity violations'; signal = 'Signal: console text (locale-dependent)' }
    }
    if ($ConsoleViolations) {
        return [pscustomobject]@{ status = 'WARN'; title = 'SFC verify: integrity violations found'; signal = 'Signal: console text (locale-dependent)' }
    }
    return [pscustomobject]@{ status = 'WARN'; title = 'SFC verify: result unclear (see output)'; signal = 'Signal: none (classification unclear)' }
}

# --- service-delete guard evaluation (extracted for testability, G3; D24) ---
# Pure decision over a pre-built record, so the six guards can be replayed
# with synthetic records without elevation. The handler performs the live
# reads and builds the record; reason strings are the contract.
function Get-ServiceDeleteGuardReasons {
    param($Record)
    $reasons = New-Object System.Collections.ArrayList
    $name = "$($Record.serviceName)"
    if (-not $name) { [void]$reasons.Add('Payload has no serviceName.'); return @($reasons) }
    if (-not $Record.keyExists) {
        [void]$reasons.Add("The service key does not exist: HKLM:\SYSTEM\CurrentControlSet\Services\$name")
        return @($reasons)
    }
    if ($Record.PSObject.Properties['keyReadable'] -and -not $Record.keyReadable) {
        [void]$reasons.Add("The service key is not readable: $($Record.keyReadError)")
        return @($reasons)
    }
    $resolved = "$($Record.resolvedPath)"
    if (-not $resolved) {
        [void]$reasons.Add("ImagePath not resolvable: '$($Record.imagePath)'")
    }
    elseif ($Record.resolvedExists) {
        [void]$reasons.Add("ImagePath now resolves to an existing file: $resolved (no longer an orphan)")
    }
    $type = [int]$Record.type
    if (($type -band 0x3) -ne 0) { [void]$reasons.Add("Driver service (Type=$type): refusing to delete a driver") }
    $start = [int]$Record.start
    if ($start -eq 0 -or $start -eq 1) { [void]$reasons.Add("Boot/System start (Start=$start): refusing to delete an early-boot component") }
    $sysRoot = "$($Record.systemRoot)"
    if (-not $sysRoot) { $sysRoot = $env:SystemRoot }
    if ($resolved -and $resolved.ToLowerInvariant().StartsWith($sysRoot.ToLowerInvariant())) {
        [void]$reasons.Add('The missing file is inside %SystemRoot%: damaged OS component, not app residue (run DISM /RestoreHealth or sfc instead)')
    }
    $dependents = @($Record.dependents | Where-Object { "$_" })
    if ($dependents.Count -gt 0) {
        [void]$reasons.Add(("Still referenced by DependOnService: {0}" -f ($dependents -join ', ')))
    }
    return @($reasons)
}

# --- winget upgrade verdict (extracted pure, _8 §11) ---
# Decides by STRUCTURE (separator + row shapes), never by localized text:
# "zero upgrades" is the steady state of a healthy machine, so a false WARN
# there is a defect. Localized phrases (EN/IT) only enrich the evidence.
# Invariant: an 'unparseable' WARN never carries an "Exit code: 0" line.
function Get-WingetUpgradeVerdict {
    param([int]$ExitCode, [string]$Text)
    $lines = @("$Text" -split "`r?`n")
    $sepIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*-{3,}\s*$') { $sepIdx = $i; break }
    }
    # Column regex tolerates the wide layout and the redirected single-space
    # one; the ID column (dotted token) anchors the row.
    $rowRegex = '^(?<name>.+?)\s+(?<id>[^\s]*\.[^\s]+)\s+(?<ver>[0-9][^\s]*)\s+(?<avail>[0-9][^\s]*)(?:\s+(?<src>winget|msstore))?\s*$'
    $rows = @()
    $unparsed = @()
    if ($sepIdx -ge 0) {
        for ($i = $sepIdx + 1; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ([string]::IsNullOrWhiteSpace($line)) {
                if ($rows.Count -gt 0) { break } else { continue }
            }
            if ($line -match '^\s*-{3,}') { continue }
            # Footer, localized: "N aggiornamenti disponibili." / "N upgrades available."
            if ($line -match '(?i)^\s*\d+\s+(aggiornament|updates?)' -or $line -match '(?i)(updates? available|aggiornamenti disponibili)') { break }
            $m = [regex]::Match($line, $rowRegex)
            if ($m.Success) {
                $rows += [pscustomobject]@{
                    name = $m.Groups['name'].Value.Trim(); id = $m.Groups['id'].Value
                    current = $m.Groups['ver'].Value; available = $m.Groups['avail'].Value; source = $m.Groups['src'].Value
                }
            }
            else { $unparsed += $line }
        }
    }
    $network = 'Requires network'
    $firstLines = @($lines | Where-Object { $_.Trim() } | Select-Object -First 3)

    if ($rows.Count -gt 0) {
        $ev = @("Total: $($rows.Count)", $network)
        if ($unparsed.Count -gt 0) { $ev += "Unparsed lines: $($unparsed.Count)" }
        return [pscustomobject]@{ state = 'updates'; status = 'WARN'; title = ("Updates available via winget: {0}" -f $rows.Count); evidence = $ev; rows = @($rows) }
    }
    if ($ExitCode -ne 0) {
        $ev = @("Exit code: $ExitCode", $network)
        if ($unparsed.Count -gt 0) { $ev += "First lines: " + (($unparsed | Select-Object -First 3) -join ' | ') }
        elseif ($firstLines.Count -gt 0) { $ev += "First lines: " + ($firstLines -join ' | ') }
        return [pscustomobject]@{ state = 'failed'; status = 'WARN'; title = ("winget upgrade failed (exit {0})" -f $ExitCode); evidence = $ev; rows = @() }
    }
    # Exit 0: a separator (or a row-shaped line without one) means a table was
    # expected and could not be parsed - genuinely unparseable, keep the WARN.
    $rowShaped = ($sepIdx -lt 0) -and (@($lines | Where-Object { $_ -match '^\s*\S.*\s[^\s]*\.[^\s]+\s+[0-9]' }).Count -gt 0)
    if ($sepIdx -ge 0 -or $rowShaped) {
        # _8 §11.4: never a WARN whose own evidence records "Exit code: 0" with
        # zero parsed rows - the exit-code line is omitted here by construction.
        $ev = @($network)
        if ($unparsed.Count -gt 0) { $ev += "Unparsed lines: $($unparsed.Count)" }
        if ($firstLines.Count -gt 0) { $ev += "First lines: " + ($firstLines -join ' | ') }
        return [pscustomobject]@{ state = 'unparseable'; status = 'WARN'; title = 'Unparseable winget output'; evidence = $ev; rows = @() }
    }
    # No separator, no row-shaped line, exit 0: nothing to upgrade (the
    # steady state of a healthy machine). Localized phrasing is evidence only.
    $ev = @($network)
    $localized = @($lines | Where-Object { $_ -match '(?i)(No installed|No applicable|No available|Nessun|non trovato|non\s+\S+\s+stato\s+trovato|nessun pacchetto|non sono stati trovati)' })
    if ($localized.Count -gt 0) { $ev += ("winget: " + $localized[0].Trim()) }
    return [pscustomobject]@{ state = 'none'; status = 'OK'; title = 'No winget updates available'; evidence = $ev; rows = @() }
}

# --- shadow-storage parsing and resize decision (extracted pure, _8 §3) ---
# `vssadmin list shadowstorage` speaks the console language (EN/IT): labels are
# classified by keyword, decimal commas are tolerated, and the action decision
# is pure over numbers - never over localized text (same policy as D23).
function Get-ShadowStorageInfo {
    param([string]$Text, [string]$Volume = '')
    $rows = New-Object System.Collections.ArrayList
    $blocks = New-Object System.Collections.ArrayList
    $current = $null
    foreach ($line in @("$Text" -split "`r?`n")) {
        $volMatch = [regex]::Match($line, '(?i)^\s*(for volume|per volume)\s*:\s*\(([A-Za-z]:)')
        if ($volMatch.Success) {
            $current = [pscustomobject]@{ volume = $volMatch.Groups[2].Value.ToUpperInvariant(); usedMB = $null; allocatedMB = $null; maxMB = $null }
            [void]$blocks.Add($current)
            continue
        }
        $m = [regex]::Match($line, '(?i)^\s*(?<label>[^\r\n:]+?)\s*:\s*(?<num>[\d.,]+)\s*(?<unit>bytes|B|KB|MB|GB|TB)(?:\s*\([^)]*\))?\s*$')
        if (-not $m.Success) { continue }
        $num = 0.0
        $null = [double]::TryParse(($m.Groups['num'].Value -replace ',', '.'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)
        $unit = $m.Groups['unit'].Value.ToUpperInvariant()
        $sizeMB = switch ($unit) { 'TB' { $num * 1048576 } 'GB' { $num * 1024 } 'MB' { $num } 'KB' { $num / 1024 } default { $num / 1MB } }
        $label = $m.Groups['label'].Value.Trim()
        [void]$rows.Add([pscustomobject]@{ item = ("Shadow storage - {0}" -f $label); sizeMB = [math]::Round($sizeMB, 1) })
        if ($current) {
            if ($label -match '(?i)(maxim|massim)') { $current.maxMB = $sizeMB }
            elseif ($label -match '(?i)allocat') { $current.allocatedMB = $sizeMB }
            elseif ($label -match '(?i)(used|utilizzat)') { $current.usedMB = $sizeMB }
        }
    }
    $result = [pscustomobject]@{
        parsed = $false; volume = $Volume; usedMB = $null; allocatedMB = $null; maxMB = $null
        rows = @($rows); blocks = @($blocks)
    }
    $sel = $null
    if ($blocks.Count -gt 0) {
        if ($Volume) {
            $match = @($blocks | Where-Object { $_.volume -ieq $Volume })
            if ($match.Count -gt 0) { $sel = $match[$match.Count - 1] }
        }
        if (-not $sel) { $sel = $blocks[$blocks.Count - 1] }
    }
    if ($sel) {
        $result.volume = $sel.volume
        $result.usedMB = $sel.usedMB
        $result.allocatedMB = $sel.allocatedMB
        $result.maxMB = $sel.maxMB
        $result.parsed = ($null -ne $sel.usedMB -or $null -ne $sel.allocatedMB -or $null -ne $sel.maxMB)
    }
    return $result
}

# Idempotence-aware: never shrinks anything (_8 §3). Returns action
# 'resize' | 'skip' | 'unreadable' with a machine-checkable reason.
function Get-ShadowResizeDecision {
    param([object]$CurrentMaxMB, [object]$CurrentUsedMB, [double]$TargetMB)
    if ($null -eq $CurrentMaxMB -or "$CurrentMaxMB" -eq '') {
        return [pscustomobject]@{ action = 'unreadable'; reason = 'current shadow-storage maximum not readable (needs elevation)' }
    }
    if ([double]$CurrentMaxMB -ge $TargetMB) {
        return [pscustomobject]@{ action = 'skip'; reason = 'already at or above the target' }
    }
    if ($null -ne $CurrentUsedMB -and "$CurrentUsedMB" -ne '' -and $TargetMB -lt [double]$CurrentUsedMB) {
        return [pscustomobject]@{ action = 'skip'; reason = 'target below current usage' }
    }
    return [pscustomobject]@{ action = 'resize'; reason = '' }
}

# --- integrity-repair preconditions (extracted pure, _8 §4) ---
# The repair is not reversible: it requires a restore point created in the
# same batch (explicit override switch) and warns when the shadow-storage
# limit is likely to evict snapshots. Pure over the record; the smoke suite
# replays it (missing restore point, evictions + low limit, clean case,
# override, hard flag).
function Get-IntegrityRepairPreconditions {
    param(
        [bool]$RestorePointCreated = $false,
        [bool]$OverrideNoRestorePoint = $false,
        [int]$Evictions7d = 0,
        [object]$CurrentMaxMB = $null,
        [double]$TargetMaxMB = 10240,
        [bool]$RequireShadowHeadroom = $false
    )
    $skips = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    if (-not $RestorePointCreated) {
        if (-not $OverrideNoRestorePoint) {
            [void]$skips.Add('a component-store repair is not reversible and requires a restore point in the same batch')
            return [pscustomobject]@{ proceed = $false; skips = @($skips); notes = @($notes) }
        }
        [void]$notes.Add('restore point precondition overridden explicitly (overrideNoRestorePoint)')
    }
    $lowLimit = $false
    if ($null -ne $CurrentMaxMB -and "$CurrentMaxMB" -ne '') { $lowLimit = ([double]$CurrentMaxMB -lt $TargetMaxMB) }
    if ($Evictions7d -gt 0 -and $lowLimit) {
        $msg = ("the shadow-storage limit evicted snapshots {0} time(s) in 7 days and the current maximum is below the {1} GB target: a restore point may be evicted before it is needed - run shadow-resize first" -f $Evictions7d, (Format-Num ([math]::Round($TargetMaxMB / 1024, 0))))
        if ($RequireShadowHeadroom) {
            [void]$skips.Add($msg)
            return [pscustomobject]@{ proceed = $false; skips = @($skips); notes = @($notes) }
        }
        [void]$notes.Add($msg)
    }
    return [pscustomobject]@{ proceed = $true; skips = @($skips); notes = @($notes) }
}

# --- streamed external process (shared by PcApply and the long steps) ---
# Live, non-blocking capture: .NET events with script-block handlers are
# unreliable in PS 5.1 while the main thread waits (measured: the host process
# dies), so this polls ReadAsync tasks instead. OnLine is invoked per decoded
# line on the calling thread; HeartbeatSeconds emits "still running" lines
# with the last output line (used by the twenty-minute DISM/SFC steps, _8 §4).
function Invoke-StreamedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 0,
        [int]$HeartbeatSeconds = 0,
        [string]$HeartbeatLabel = '',
        [int]$PollMilliseconds = 250,
        [scriptblock]$OnLine = $null
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($Arguments | ForEach-Object {
                $a = "$_"
                if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
            }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $enc = [System.Text.Encoding]::Default

    $proc = $null
    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch {
        $sw.Stop()
        return [pscustomobject]@{ exitCode = $null; timedOut = $false; output = ("Failed to start {0}: {1}" -f $FilePath, $_.Exception.Message); lines = @(); durationMs = $sw.ElapsedMilliseconds }
    }

    $bufOut = New-Object byte[] 8192
    $bufErr = New-Object byte[] 8192
    $taskOut = $proc.StandardOutput.BaseStream.ReadAsync($bufOut, 0, $bufOut.Length)
    $taskErr = $proc.StandardError.BaseStream.ReadAsync($bufErr, 0, $bufErr.Length)
    $outDone = $false; $errDone = $false
    $partialOut = ''; $partialErr = ''
    $output = New-Object System.Text.StringBuilder
    $lines = New-Object System.Collections.ArrayList
    $timedOut = $false
    $lastBeat = Get-Date
    $lastLine = ''
    $label = if ($HeartbeatLabel) { $HeartbeatLabel } else { Split-Path -Leaf $FilePath }

    while ($true) {
        if (-not $outDone -and $taskOut.IsCompleted) {
            $n = 0
            try { $n = $taskOut.Result } catch { $n = 0 }
            if ($n -gt 0) {
                $partialOut += $enc.GetString($bufOut, 0, $n)
                $taskOut = $proc.StandardOutput.BaseStream.ReadAsync($bufOut, 0, $bufOut.Length)
                while ($true) {
                    $idx = $partialOut.IndexOf("`n")
                    if ($idx -lt 0) { break }
                    $line = $partialOut.Substring(0, $idx).TrimEnd("`r")
                    $partialOut = $partialOut.Substring($idx + 1)
                    [void]$lines.Add($line); [void]$output.AppendLine($line)
                    $lastLine = $line
                    if ($OnLine) { try { & $OnLine $line } catch { } }
                }
            }
            else { $outDone = $true }
        }
        if (-not $errDone -and $taskErr.IsCompleted) {
            $n = 0
            try { $n = $taskErr.Result } catch { $n = 0 }
            if ($n -gt 0) {
                $partialErr += $enc.GetString($bufErr, 0, $n)
                $taskErr = $proc.StandardError.BaseStream.ReadAsync($bufErr, 0, $bufErr.Length)
                while ($true) {
                    $idx = $partialErr.IndexOf("`n")
                    if ($idx -lt 0) { break }
                    $line = $partialErr.Substring(0, $idx).TrimEnd("`r")
                    $partialErr = $partialErr.Substring($idx + 1)
                    [void]$lines.Add($line); [void]$output.AppendLine($line)
                    $lastLine = $line
                    if ($OnLine) { try { & $OnLine $line } catch { } }
                }
            }
            else { $errDone = $true }
        }
        if ($proc.HasExited -and $outDone -and $errDone) { break }
        if (-not $proc.HasExited -and $TimeoutSeconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            $proc.WaitForExit(5000) | Out-Null
            break
        }
        if (-not $proc.HasExited -and $HeartbeatSeconds -gt 0 -and ((Get-Date) - $lastBeat).TotalSeconds -ge $HeartbeatSeconds) {
            $lastBeat = Get-Date
            $show = $lastLine
            if (-not $show) { $show = 'no output yet' }
            if ($show.Length -gt 120) { $show = $show.Substring(0, 117) + '...' }
            Write-Host ("    ... {0} still running ({1} s): {2}" -f $label, [int]$sw.Elapsed.TotalSeconds, $show)
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    foreach ($rest in @($partialOut, $partialErr)) {
        if ($rest -and $rest.Trim()) {
            $line = $rest.TrimEnd("`r")
            [void]$lines.Add($line); [void]$output.AppendLine($line)
            if ($OnLine) { try { & $OnLine $line } catch { } }
        }
    }
    $proc.WaitForExit()
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { }
    $proc.Dispose()
    $sw.Stop()
    return [pscustomobject]@{
        exitCode   = $exitCode
        timedOut   = $timedOut
        output     = $output.ToString()
        lines      = @($lines)
        durationMs = $sw.ElapsedMilliseconds
    }
}

Export-ModuleMember -Function New-Finding, Write-JsonFile, Write-ProbeResult, New-ActionResult, Write-ActionResult, Test-IsAdmin, Expand-ImagePath, Get-OxydeVersion, Clear-OxydeOutput, Format-Num, Get-DirSizeCapped, Get-CbsDetectedCorruption, Get-CbsSrVerify, Get-IntegrityDismDecision, Get-IntegritySfcDecision, Get-ServiceDeleteGuardReasons, Get-WingetUpgradeVerdict, Get-ShadowStorageInfo, Get-ShadowResizeDecision, Get-IntegrityRepairPreconditions, Invoke-StreamedProcess
