# oxyde-win-maintenance probe: disk space consumers (read-only, quick-safe).
# Shadow storage needs elevation: unelevated it degrades to an INFO note.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Space'
$findings = New-Object System.Collections.ArrayList
$consumerRows = @()
$shadowRows = @()

# Capped directory walk: skips unreadable folders, stops at the file/time cap
# (verified: naive Get-ChildItem -Recurse is ~2.5x slower and unreadable dirs
# abort EnumerateFiles, so walk per-directory with a stack).
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

# --- fixed drives: free space ---
$drives = @()
try {
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | Sort-Object DeviceID)
}
catch { }

$minFreePct = 100
foreach ($d in $drives) {
    if (-not $d.Size -or $d.Size -le 0) { continue }
    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
    $pctFree = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
    if ($pctFree -lt $minFreePct) { $minFreePct = $pctFree }
    if ($pctFree -lt 10 -or $freeGB -lt 15) {
        [void]$findings.Add((New-Finding -Id ("space-low-" + ($d.DeviceID -replace '[^A-Za-z0-9]', '')) -Area $Area -Title ("Low disk space on {0}: {1} GB free ({2}%)" -f $d.DeviceID, $freeGB, $pctFree) -Status 'WARN' `
                    -Evidence @("Volume: $($d.VolumeName)", ("Size: {0} GB, free: {1} GB" -f [math]::Round($d.Size / 1GB, 1), $freeGB)) `
                    -SuggestedAction 'Free up space (Temp, Recycle Bin, Windows.old, shadow copies) or move data to another drive' `
                    -Source 'Win32_LogicalDisk'))
    }
}

# --- space consumers (best-effort, capped) ---
$targets = @(
    @{ item = 'User temp'; path = "$env:TEMP"; reclaimable = $true }
    @{ item = 'Windows temp'; path = (Join-Path $env:SystemRoot 'Temp'); reclaimable = $true }
    @{ item = 'Windows Error Reporting'; path = 'C:\ProgramData\Microsoft\Windows\WER'; reclaimable = $true }
    @{ item = 'Recycle Bin'; path = "$env:SystemDrive\`$Recycle.Bin"; reclaimable = $true }
    @{ item = 'Windows.old'; path = "$env:SystemDrive\Windows.old"; reclaimable = $true }
)
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t.path)) { continue }
    $r = Get-DirSizeCapped -Root $t.path
    if (-not $r) { continue }
    $sizeMB = [math]::Round($r.bytes / 1MB, 1)
    $note = ''
    if ($r.capped) { $note = "capped at $($r.files) files / $($r.ms) ms (actual size is larger)" }
    $consumerRows += [pscustomobject]@{ item = $t.item; path = $t.path; sizeMB = $sizeMB; note = $note }
    if ($t.reclaimable -and $sizeMB -ge 10240) {
        [void]$findings.Add((New-Finding -Id ("space-big-" + ($t.item -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Large reclaimable data: {0} ({1} GB)" -f $t.item, [math]::Round($sizeMB / 1024, 1)) -Status 'WARN' `
                    -Evidence @("Path: $($t.path)", ("Size: {0} MB" -f $sizeMB), $(if ($note) { $note } else { '' })) `
                    -SuggestedAction 'Clean up this location when convenient' -Source 'Directory walk (capped)'))
    }
}

# --- pagefile (CIM, readable unelevated) ---
try {
    foreach ($pf in @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop)) {
        $consumerRows += [pscustomobject]@{ item = 'Pagefile'; path = "$($pf.Name)"; sizeMB = $pf.AllocatedBaseSize; note = ("current usage: {0} MB" -f $pf.CurrentUsage) }
    }
}
catch { }

# --- hibernation file (best-effort) ---
try {
    $hib = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction Stop
    $consumerRows += [pscustomobject]@{ item = 'Hibernation file'; path = "$env:SystemDrive\hiberfil.sys"; sizeMB = [math]::Round($hib.Length / 1MB, 1); note = '' }
}
catch { }

# --- shadow storage (requires elevation) ---
$shadowElevated = $false
try {
    $outText = (& cmd /c "vssadmin list shadowstorage 2>&1" | Out-String)
    if ($LASTEXITCODE -eq 0 -and $outText) {
        $shadowElevated = $true
        # Parse "Label: <n> <unit>" pairs (EN/IT labels); numbers may use , or . decimals.
        $sized = [regex]::Matches($outText, '(?im)^\s*[^\r\n:]*?(used|used shadow|maximum|allocated|utilizzat[^\r\n:]*|massim[^\r\n:]*|allocat[^\r\n:]*)\s*:\s*([\d.,]+)\s*(bytes|B|KB|MB|GB|TB)\s*$')
        if ($sized.Count -gt 0) {
            foreach ($m in $sized) {
                $num = 0.0; $null = [double]::TryParse(($m.Groups[2].Value -replace ',', '.'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)
                $unit = $m.Groups[3].Value.ToUpperInvariant()
                $sizeMB = switch ($unit) { 'TB' { $num * 1048576 } 'GB' { $num * 1024 } 'MB' { $num } 'KB' { $num / 1024 } default { $num / 1MB } }
                $shadowRows += [pscustomobject]@{ item = ("Shadow storage - {0}" -f $m.Groups[1].Value.Trim()); path = ''; sizeMB = [math]::Round($sizeMB, 1); note = 'source: vssadmin' }
            }
        }
        else {
            $tail = (($outText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 6) -join ' | ')
            $shadowRows += [pscustomobject]@{ item = 'Shadow storage (raw output)'; path = ''; sizeMB = $null; note = $tail }
        }
    }
}
catch { }
if (-not $shadowElevated) {
    $shadowRows += [pscustomobject]@{ item = 'Shadow storage'; path = ''; sizeMB = $null; note = 'requires elevation (deep scan)' }
}

# --- summary ---
$ev = @()
foreach ($d in $drives) {
    if ($d.Size -gt 0) { $ev += ("{0} free: {1} GB of {2} GB ({3}%)" -f $d.DeviceID, [math]::Round($d.FreeSpace / 1GB, 1), [math]::Round($d.Size / 1GB, 1), [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)) }
}
if ($consumerRows.Count -gt 0) {
    $top = @($consumerRows | Where-Object { $null -ne $_.sizeMB } | Sort-Object sizeMB -Descending | Select-Object -First 3)
    $ev += ("Top measured consumers: {0}" -f (($top | ForEach-Object { "{0} {1} MB" -f $_.item, $_.sizeMB }) -join ', '))
}
if (-not $shadowElevated) { $ev += 'Shadow storage usage/limit requires elevation (deep scan).' }
[void]$findings.Add((New-Finding -Id 'space-summary' -Area $Area -Title ("Space scan: {0} consumer(s) measured" -f $consumerRows.Count) -Status 'INFO' `
            -Evidence $ev -Source 'Win32_LogicalDisk + directory walk (capped) + vssadmin'))

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ spaceConsumers = ($consumerRows | Sort-Object sizeMB -Descending); shadowStorage = $shadowRows } -OutFile $OutFile
