# oxyde-win-maintenance probe: component-store integrity (CBS).
# Quick/standard: current CBS log tail + newest servicing archive (fast scan).
# Deep (elevated): DISM /ScanHealth + sfc /verifyonly.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Integrity'
$findings = New-Object System.Collections.ArrayList
$sessionRows = @()
$archiveRows = @()
$deep = ($env:OXYDE_PROFILE -eq 'deep')

# --- current CBS log tail (verified readable unelevated) ---
$cbsOk = $false
try {
    $cbs = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    $fs = [System.IO.File]::Open($cbs, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        $take = [int][Math]::Min(2MB, $len)
        $buf = New-Object byte[] $take
        $fs.Seek($len - $take, [System.IO.SeekOrigin]::Begin) | Out-Null
        $read = $fs.Read($buf, 0, $take)
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    }
    finally { $fs.Dispose() }
    $cbsOk = $true

    $sessions = [regex]::Matches($text, 'Reboot required: (yes|no),\s*RepairNeeded: (yes|no)', 'IgnoreCase')
    $recent = @($sessions | Select-Object -Last 100)
    $repairYes = @($recent | Where-Object { $_.Groups[2].Value -ieq 'yes' }).Count
    $rebootYes = @($recent | Where-Object { $_.Groups[1].Value -ieq 'yes' }).Count
    $lastRepair = 'no'
    if ($recent.Count -gt 0) { $lastRepair = $recent[$recent.Count - 1].Groups[2].Value.ToLowerInvariant() }
    $lastReboot = 'no'
    if ($recent.Count -gt 0) { $lastReboot = $recent[$recent.Count - 1].Groups[1].Value.ToLowerInvariant() }

    $sessionRows += [pscustomobject]@{
        source         = 'CBS.log (current)'
        sessions       = $recent.Count
        repairNeeded   = $lastRepair
        rebootRequired = $lastReboot
        last           = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    }

    if ($repairYes -gt 0 -or $lastRepair -eq 'yes') {
        [void]$findings.Add((New-Finding -Id 'integrity-current-repair' -Area $Area -Title ("Component store: {0} of the last {1} sessions need repair" -f $repairYes, $recent.Count) -Status 'WARN' `
                    -Evidence @(
                        "Last session: RepairNeeded: $lastRepair, Reboot required: $lastReboot",
                        'Run an elevated repair: DISM /Online /Cleanup-Image /RestoreHealth, then sfc /scannow.'
                    ) `
                    -SuggestedAction 'Repair the component store from an elevated prompt' -AdminRequired $true `
                    -Source 'CBS.log (tail 2 MB)'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'integrity-current-ok' -Area $Area -Title ("Component store: no servicing repair pending (last {0} sessions)" -f $recent.Count) -Status 'OK' `
                    -Evidence @(
                        "Last session: RepairNeeded: no, Reboot required: $lastReboot",
                        'RepairNeeded=no means no repair is pending, not that the store is healthy: DISM ScanHealth (deep scan, elevated) can still find repairable corruption.'
                    ) `
                    -Source 'CBS.log (tail 2 MB)'))
    }
}
catch {
    [void]$findings.Add((New-Finding -Id 'integrity-current-unknown' -Area $Area -Title 'Current CBS log not readable' -Status 'INFO' `
                -Evidence @("$($_.Exception.Message)", 'Run the deep scan elevated to read the servicing logs.') `
                -Source 'CBS.log (tail 2 MB)'))
}

# --- newest servicing archive (CbsPersist): corruption history ---
# Fast literal scan (ReadAllBytes + IndexOf): 133 MB in ~0.7 s; the naive
# regex-per-chunk approach took 131 s and was rejected. Capped at 256 MB.
try {
    $persists = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Logs\CBS') -Filter 'CbsPersist_*.log' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($persists.Count -gt 0) {
        $p = $persists[0]
        $sizeMB = [math]::Round($p.Length / 1MB)
        if ($p.Length -le 256MB) {
            $bytes = [System.IO.File]::ReadAllBytes($p.FullName)
            $txt = [System.Text.Encoding]::ASCII.GetString($bytes)
            $count = 0
            $idx = 0
            $lastHit = -1
            while (($idx = $txt.IndexOf('Payload Corrupt', $idx)) -ge 0) { $count++; $lastHit = $idx; $idx += 15 }
            $summaryN = ''
            $ms = [regex]::Matches($txt, 'CSI Payload Corruption:\s*(\d+)')
            if ($ms.Count -gt 0) { $summaryN = $ms[$ms.Count - 1].Groups[1].Value }
            $lastAt = ''
            if ($lastHit -ge 0) {
                $lineStart = $txt.LastIndexOf("`n", $lastHit)
                $line = $txt.Substring($lineStart + 1, [Math]::Min(80, $txt.Length - $lineStart - 1))
                $tm = [regex]::Match($line, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
                if ($tm.Success) { $lastAt = $tm.Value }
            }
            $archiveRows += [pscustomobject]@{
                source           = $p.Name
                sizeMB           = $sizeMB
                payloadCorruption = $(if ($summaryN) { $summaryN } else { "$count" })
                markers          = $count
                lastMarkerAt     = $lastAt
            }
            if ($count -gt 0) {
                [void]$findings.Add((New-Finding -Id 'integrity-archive' -Area $Area -Title ("Component store archive: {0} corruption marker(s) repaired in the previous servicing session" -f $(if ($summaryN) { $summaryN } else { $count })) -Status 'INFO' `
                            -Evidence @(
                                "Archive: $($p.Name) ($sizeMB MB)",
                                $(if ($lastAt) { "Last marker: $lastAt" } else { '' }),
                                'Historical record (already repaired). Payload health requires the deep scan (elevated); the CBS.log finding above is only the pending-repair state.'
                            ) `
                            -Source 'CbsPersist (literal scan)'))
            }
        }
        else {
            [void]$findings.Add((New-Finding -Id 'integrity-archive-skip' -Area $Area -Title ("Servicing archive too large for the quick scan ({0} MB)" -f $sizeMB) -Status 'INFO' `
                        -Source 'CbsPersist (size cap 256 MB)'))
        }
    }
}
catch {
    [void]$findings.Add((New-Finding -Id 'integrity-archive-unknown' -Area $Area -Title 'Servicing archive not readable' -Status 'INFO' `
                -Evidence @("$($_.Exception.Message)") -Source 'CbsPersist (literal scan)'))
}

# --- deep (elevated): DISM /ScanHealth + sfc /verifyonly ---
if ($deep) {
    if (-not (Test-IsAdmin)) {
        [void]$findings.Add((New-Finding -Id 'integrity-deep-skip' -Area $Area -Title 'Deep integrity checks skipped: requires elevation' -Status 'INFO' `
                    -Evidence @('Relaunch the deep scan from an elevated prompt (or the GUI "Deep scan (admin)").') `
                    -Source 'oxyde-win-maintenance deep profile'))
    }
    else {
        # CBS.log carries the deep-scan results in English even on localized
        # systems: DISM writes "Total Detected Corruption: N" at the end of its
        # detection session, SFC writes an [SR] verify transaction. These are
        # the primary, language-independent signals. Measured on this host: the
        # DISM exit code is 0 even when the store is repairable, so exit codes
        # are recorded but never decisive. Localized console text is the
        # last-resort fallback, and the classification never yields a false OK.
        function Read-CbsTail {
            param([int]$Lines = 8000)
            try { return @(Get-Content (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log') -Tail $Lines -ErrorAction Stop) }
            catch { return @() }
        }

        # DISM scan
        try {
            $scanStart = Get-Date
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $dismOut = (& dism.exe /Online /Cleanup-Image /ScanHealth 2>&1 | Out-String)
            $dismExit = $LASTEXITCODE
            $sw.Stop()
            $dur = "Duration: {0} s" -f (Format-Num ([math]::Round($sw.ElapsedMilliseconds / 1000)))
            $tail = (($dismOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | ')
            $exitNote = "Signal: dism exit code 0x{0:X8} (recorded only: 0 is returned even for repairable stores)" -f $dismExit

            # Primary: the newest CBS summary line, if it belongs to this run.
            $cbsN = $null
            $cbsLines = Read-CbsTail
            for ($i = $cbsLines.Count - 1; $i -ge 0; $i--) {
                $m = [regex]::Match("$($cbsLines[$i])", '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*Total Detected Corruption:\s*(\d+)')
                if ($m.Success) {
                    $t = $null
                    try { $t = [datetime]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch { }
                    if ($t -and $t -ge $scanStart.AddSeconds(-60)) { $cbsN = [int]$m.Groups[2].Value }
                    break
                }
            }

            $clean = ($dismOut -match '(?i)(No component store corruption detected|Nessun danneggiamento[^\r\n]*rilevato|nessuna corruzione|non sono state rilevate corruzioni)')
            $repairable = ($dismOut -match '(?i)(repairable|riparabil|ripristinabil)')
            $st = 'WARN'
            if ($null -ne $cbsN) {
                $st = if ($cbsN -eq 0) { 'OK' } else { 'WARN' }
                $signal = ("Signal: CBS.log Total Detected Corruption={0} (English, language-independent)" -f $cbsN)
                $title = if ($cbsN -eq 0) { 'DISM ScanHealth: component store healthy' } else { ("DISM ScanHealth: component store repairable ({0} payload corruption(s))" -f $cbsN) }
            }
            elseif ($clean) {
                # C3: a clean match wins over a repairable match.
                $st = 'OK'; $signal = 'Signal: console text (locale-dependent)'; $title = 'DISM ScanHealth: component store healthy'
            }
            elseif ($repairable) {
                $signal = 'Signal: console text (locale-dependent)'; $title = 'DISM ScanHealth: component store is repairable'
            }
            else {
                $signal = 'Signal: none (classification unclear)'; $title = 'DISM ScanHealth: result unclear (see output)'
            }
            $forRepair = ''
            if ($st -ne 'OK') { $forRepair = 'Repair with: DISM /Online /Cleanup-Image /RestoreHealth' }
            [void]$findings.Add((New-Finding -Id 'integrity-deep-dism' -Area $Area -Title $title -Status $st `
                        -Evidence @($tail, $forRepair, $signal, $exitNote, $dur) `
                        -SuggestedAction $(if ($st -eq 'OK') { '' } else { 'Repair the component store (RestoreHealth)' }) -AdminRequired $true `
                        -Source 'dism /Online /Cleanup-Image /ScanHealth + CBS.log'))
        }
        catch {
            [void]$findings.Add((New-Finding -Id 'integrity-deep-dism-err' -Area $Area -Title 'DISM ScanHealth failed to run' -Status 'WARN' `
                        -Evidence @("$($_.Exception.Message)") -Source 'dism.exe'))
        }
        # SFC verify (sfc writes UTF-16LE console output: strip NULs for the fallback)
        try {
            $scanStart = Get-Date
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $sfcOut = (& sfc.exe /verifyonly 2>&1 | Out-String)
            $sfcExit = $LASTEXITCODE
            $sw.Stop()
            $sfcOut = $sfcOut -replace "`0", ''
            $tail = (($sfcOut -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 4) -join ' | ')
            $dur = "Duration: {0} s" -f (Format-Num ([math]::Round($sw.ElapsedMilliseconds / 1000)))
            $exitNote = "Signal: sfc exit code $sfcExit (recorded only: not discriminative)"

            # Primary: [SR] lines from this run's verify transaction (English).
            $srCannot = 0
            $srComplete = 0
            foreach ($line in (Read-CbsTail)) {
                $m = [regex]::Match("$line", '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*\[SR\]')
                if (-not $m.Success) { continue }
                $t = $null
                try { $t = [datetime]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch { continue }
                if ($t -lt $scanStart.AddSeconds(-60)) { continue }
                if ("$line" -match '\[SR\] Cannot repair member file') { $srCannot++ }
                elseif ("$line" -match '\[SR\] Verify complete') { $srComplete++ }
            }

            $clean = ($sfcOut -match '(?i)(did not find any integrity violations|nessuna violazione|non ha trovato violazioni)')
            $violations = ($sfcOut -match '(?i)(found integrity violations|found corrupt files|ha trovato file danneggiati)')
            $st = 'WARN'
            if ($srCannot -gt 0) {
                $signal = ("Signal: CBS.log [SR] Cannot repair member file x{0} (English)" -f $srCannot)
                $title = ("SFC verify: integrity violations found ({0} member(s))" -f $srCannot)
            }
            elseif ($srComplete -gt 0) {
                # C3: a completed verify with nothing to repair wins.
                $st = 'OK'; $signal = ("Signal: CBS.log [SR] Verify complete x{0} (English)" -f $srComplete)
                $title = 'SFC verify: no integrity violations'
            }
            elseif ($clean) {
                $st = 'OK'; $signal = 'Signal: console text (locale-dependent)'; $title = 'SFC verify: no integrity violations'
            }
            elseif ($violations) {
                $signal = 'Signal: console text (locale-dependent)'; $title = 'SFC verify: integrity violations found'
            }
            else {
                $signal = 'Signal: none (classification unclear)'; $title = 'SFC verify: result unclear (see output)'
            }
            [void]$findings.Add((New-Finding -Id 'integrity-deep-sfc' -Area $Area -Title $title -Status $st `
                        -Evidence @($tail, $signal, $exitNote, $dur) `
                        -SuggestedAction $(if ($st -eq 'OK') { '' } else { 'Run sfc /scannow elevated' }) -AdminRequired $true `
                        -Source 'sfc /verifyonly + CBS.log'))
        }
        catch {
            [void]$findings.Add((New-Finding -Id 'integrity-deep-sfc-err' -Area $Area -Title 'SFC verify failed to run' -Status 'WARN' `
                        -Evidence @("$($_.Exception.Message)") -Source 'sfc.exe'))
        }
    }
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ integritySessions = $sessionRows; integrityArchive = $archiveRows } -OutFile $OutFile
