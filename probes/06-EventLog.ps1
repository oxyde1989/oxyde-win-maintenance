# oxyde-win-maintenance probe: critical events (unexpected shutdowns, bug checks,
# top recurring system errors). Read-only, quick-safe.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'EventLog'
$findings = New-Object System.Collections.ArrayList
$shutdownRows = @()
$errorRows = @()

function Get-LastEventTime($Events) {
    if (@($Events).Count -eq 0) { return '' }
    return (@($Events) | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('yyyy-MM-dd HH:mm')
}

function Get-FirstMessageLine($Event) {
    try {
        $line = ("$($Event.Message)" -split "`r?`n")[0]
        if ($line.Length -gt 160) { $line = $line.Substring(0, 157) + '...' }
        return $line
    }
    catch { return '' }
}

# --- unexpected shutdowns / bug checks (90 days) ---
$events = @()
try {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 6008, 1001; StartTime = (Get-Date).AddDays(-90) } -ErrorAction SilentlyContinue)
}
catch { }

$kp = @($events | Where-Object { $_.Id -eq 41 })
$e6008 = @($events | Where-Object { $_.Id -eq 6008 })
$bugcheck = @($events | Where-Object { $_.Id -eq 1001 })

if ($kp.Count -gt 0) { $shutdownRows += [pscustomobject]@{ type = 'Kernel-Power 41 (power loss / crash)'; count = $kp.Count; last = (Get-LastEventTime $kp) } }
if ($e6008.Count -gt 0) { $shutdownRows += [pscustomobject]@{ type = 'EventLog 6008 (previous shutdown unexpected)'; count = $e6008.Count; last = (Get-LastEventTime $e6008) } }
if ($bugcheck.Count -gt 0) { $shutdownRows += [pscustomobject]@{ type = 'BugCheck 1001 (BSOD)'; count = $bugcheck.Count; last = (Get-LastEventTime $bugcheck) } }

$unexpected = $kp.Count + $e6008.Count
if ($unexpected -gt 0) {
    [void]$findings.Add((New-Finding -Id 'event-shutdowns' -Area $Area -Title ("Ungraceful shutdowns: {0} in the last 90 days" -f $unexpected) -Status 'WARN' `
                -Evidence @(
                    ("Kernel-Power 41 (power loss/crash): {0} (last: {1})" -f $kp.Count, (Get-LastEventTime $kp)),
                    ("EventLog 6008 (unexpected shutdown): {0} (last: {1})" -f $e6008.Count, (Get-LastEventTime $e6008)),
                    'Repeated ungraceful shutdowns can corrupt files, the component store and pending updates.'
                ) -SuggestedAction 'Check power supply/cabling or why the PC was powered off abruptly' -Source 'Get-WinEvent (System 41/6008, 90 days)'))
}
else {
    [void]$findings.Add((New-Finding -Id 'event-shutdowns' -Area $Area -Title 'No ungraceful shutdowns in the last 90 days' -Status 'OK' `
                -Source 'Get-WinEvent (System 41/6008, 90 days)'))
}

if ($bugcheck.Count -gt 0) {
    $sample = Get-FirstMessageLine ($bugcheck | Sort-Object TimeCreated -Descending | Select-Object -First 1)
    $ev = @(("Last: {0}" -f (Get-LastEventTime $bugcheck)))
    if ($sample) { $ev += "Last event: $sample" }
    $ev += 'Frequent bug checks usually point to drivers or hardware (RAM/disk).'
    [void]$findings.Add((New-Finding -Id 'event-bugcheck' -Area $Area -Title ("Bug checks (BSOD): {0} in the last 90 days" -f $bugcheck.Count) -Status 'WARN' `
                -Evidence $ev -SuggestedAction 'Review the BugCheck codes and update or roll back the involved drivers' `
                -Source 'Get-WinEvent (System 1001, 90 days)'))
}
else {
    [void]$findings.Add((New-Finding -Id 'event-bugcheck' -Area $Area -Title 'No bug checks (BSOD) in the last 90 days' -Status 'OK' `
                -Source 'Get-WinEvent (System 1001, 90 days)'))
}

# --- top recurring system errors (30 days) ---
$errors = @()
try {
    $errors = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 3000 -ErrorAction SilentlyContinue)
}
catch { }

$groups = @($errors | Group-Object { '{0}|{1}' -f $_.ProviderName, $_.Id } | Sort-Object Count -Descending | Select-Object -First 5)
foreach ($g in $groups) {
    $parts = $g.Name -split '\|', 2
    $last = (@($g.Group) | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('yyyy-MM-dd HH:mm')
    $errorRows += [pscustomobject]@{
        provider = "$($parts[0])"
        id       = "$($parts[1])"
        count    = $g.Count
        last     = $last
        sample   = (Get-FirstMessageLine (@($g.Group) | Select-Object -First 1))
    }
}

if ($errorRows.Count -gt 0) {
    $ev = @()
    foreach ($r in $errorRows) { $ev += ("{0} {1}: x{2} (last: {3})" -f $r.provider, $r.id, $r.count, $r.last) }
    [void]$findings.Add((New-Finding -Id 'event-top-errors' -Area $Area -Title ("Top recurring system errors (30 days): {0} group(s), {1} event(s)" -f $errorRows.Count, $errors.Count) -Status 'INFO' `
                -Evidence $ev -Source 'Get-WinEvent (System Level 1-2, 30 days, top 5)'))
}
else {
    [void]$findings.Add((New-Finding -Id 'event-top-errors' -Area $Area -Title 'No system errors in the last 30 days' -Status 'OK' `
                -Source 'Get-WinEvent (System Level 1-2, 30 days)'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ shutdownEvents = $shutdownRows; topSystemErrors = $errorRows } -OutFile $OutFile
