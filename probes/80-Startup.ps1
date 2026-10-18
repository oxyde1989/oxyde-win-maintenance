# oxyde-win-maintenance probe: startup entries (standard profile).
# Run/RunOnce keys, Startup folders (.lnk resolved), scheduled tasks with
# missing targets, third-party autostart services (inventory). Read-only.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Startup'
$findings = New-Object System.Collections.ArrayList
$rows = @()
$problems = 0

# Run values can be quoted or unquoted; unquoted paths with spaces (a classic
# installer bug) break naive token splitting. Collect all plausible executable
# candidates and prefer the first one that exists; fall back to the first
# candidate for the report.
function Get-RunTarget {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
    $cands = @()
    if ($Command.StartsWith('"')) {
        $end = $Command.IndexOf('"', 1)
        if ($end -gt 1) { $cands += $Command.Substring(1, $end - 1) }
    }
    foreach ($m in [regex]::Matches($Command, '(?i)([A-Za-z]:\\[^"]*?\.(exe|cmd|bat|com|ps1|ahk|vbs|lnk))(?=\s|$)')) { $cands += $m.Groups[1].Value }
    if ($cands.Count -eq 0) { return $null }
    foreach ($c in $cands) {
        $e = [Environment]::ExpandEnvironmentVariables($c.Trim())
        if (Test-Path -LiteralPath $e -ErrorAction SilentlyContinue) { return $e }
    }
    return [Environment]::ExpandEnvironmentVariables($cands[0].Trim())
}

# --- Run / RunOnce keys ---
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($key in $runKeys) {
    try {
        $props = @((Get-ItemProperty -Path $key -ErrorAction Stop).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' })
    }
    catch { continue }
    foreach ($p in $props) {
        if ($p.Name -eq '(default)') { continue }
        $command = "$($p.Value)"
        $target = Get-RunTarget $command
        $exists = $null
        if ($target) { $exists = [bool](Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) }
        $rows += [pscustomobject]@{
            kind    = 'run'
            name    = "$($p.Name)"
            command = $command
            target  = $(if ($target) { $target } else { '' })
            exists  = $exists
            state   = $key
        }
        if ($target -and -not $exists) {
            $problems++
            [void]$findings.Add((New-Finding -Id ("startup-run-" + ("$key|$($p.Name)" -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Autostart points to a missing file: {0}" -f "$($p.Name)") -Status 'WARN' `
                        -Evidence @("Registry: $key", "Command: $command", "Target not found: $target") `
                        -SuggestedAction 'Remove the stale Run entry (after confirming the app is really uninstalled)' `
                        -Source 'Registry Run/RunOnce keys'))
        }
    }
}

# --- Startup folders (.lnk targets resolved via WScript.Shell) ---
$startupDirs = @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup')
)
$wsh = $null
foreach ($dir in $startupDirs) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        $target = ''
        $exists = $true
        if ($f.Extension -ieq '.lnk') {
            try {
                if (-not $wsh) { $wsh = New-Object -ComObject WScript.Shell }
                $target = "$($wsh.CreateShortcut($f.FullName).TargetPath)"
                if ($target) { $exists = [bool](Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) }
            }
            catch { }
        }
        else {
            # Not a shortcut: the file itself is the autostart item and exists.
            $target = $f.FullName
        }
        $rows += [pscustomobject]@{
            kind    = 'folder'
            name    = $f.Name
            command = $f.FullName
            target  = $target
            exists  = $(if ($target) { $exists } else { $null })
            state   = $dir
        }
        if ($target -and -not $exists) {
            $problems++
            [void]$findings.Add((New-Finding -Id ("startup-folder-" + ($f.Name -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Startup shortcut points to a missing file: {0}" -f $f.Name) -Status 'WARN' `
                        -Evidence @("Shortcut: $($f.FullName)", "Target not found: $target") `
                        -SuggestedAction 'Delete the stale startup shortcut (after confirming the app is really uninstalled)' `
                        -Source 'Startup folders'))
        }
    }
}
if ($wsh) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) } catch { } }

# --- Scheduled tasks with missing targets (Ready/Running only; Disabled are inert) ---
try {
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
        $state = "$($t.State)"
        if ($state -eq 'Disabled') { continue }
        $taskPath = "$($t.TaskPath)$($t.TaskName)"
        foreach ($a in @($t.Actions)) {
            $exe = "$($a.Execute)"
            if (-not $exe) { continue }
            $exe = [Environment]::ExpandEnvironmentVariables($exe.Trim('"'))
            if ($exe -notmatch '^[A-Za-z]:\\' -and -not $exe.StartsWith('\')) { continue }
            if (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue) { continue }
            $isMicrosoft = $taskPath -match '^\\?Microsoft\\Windows\\'
            $st = $(if ($isMicrosoft) { 'INFO' } else { 'WARN' })
            if (-not $isMicrosoft) { $problems++ }
            $rows += [pscustomobject]@{
                kind    = 'task'
                name    = $taskPath
                command = $exe
                target  = $exe
                exists  = $false
                state   = $state
            }
            [void]$findings.Add((New-Finding -Id ("startup-task-" + ($taskPath -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Scheduled task points to a missing file: {0}" -f $taskPath) -Status $st `
                        -Evidence @("State: $state", "Target not found: $exe", $(if ($isMicrosoft) { 'Microsoft Windows component: usually harmless if the task is legacy.' } else { 'Third-party task: typical residue of an uninstalled application.' })) `
                        -SuggestedAction $(if ($isMicrosoft) { '' } else { 'Disable or delete the stale task (after confirming the app is really uninstalled)' }) `
                        -Source 'Get-ScheduledTask'))
        }
    }
}
catch {
    [void]$findings.Add((New-Finding -Id 'startup-tasks-error' -Area $Area -Title 'Scheduled tasks query failed' -Status 'INFO' `
                -Evidence @("$($_.Exception.Message)") -Source 'Get-ScheduledTask'))
}

# --- Third-party autostart services (inventory; missing paths are OrphanServices' job) ---
try {
    $sysRoot = $env:SystemRoot.ToLowerInvariant()
    $auto = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" -ErrorAction Stop)
    foreach ($s in $auto) {
        $path = "$($s.PathName)"
        $exe = Expand-ImagePath $path
        if ($exe -and $exe.ToLowerInvariant().StartsWith($sysRoot)) { continue }
        $rows += [pscustomobject]@{
            kind    = 'service'
            name    = "$($s.Name)"
            command = $path
            target  = $(if ($exe) { $exe } else { '' })
            exists  = $null
            state   = "$($s.State)"
        }
    }
}
catch { }

# --- summary ---
$runCount = @($rows | Where-Object { $_.kind -eq 'run' }).Count
$folderCount = @($rows | Where-Object { $_.kind -eq 'folder' }).Count
$serviceCount = @($rows | Where-Object { $_.kind -eq 'service' }).Count
$taskIssueCount = @($rows | Where-Object { $_.kind -eq 'task' }).Count

if ($problems -eq 0) {
    [void]$findings.Add((New-Finding -Id 'startup-summary' -Area $Area -Title ("Startup: {0} entries, no missing targets" -f $rows.Count) -Status 'OK' `
                -Evidence @(("Run/RunOnce: {0}" -f $runCount), ("Startup folder: {0}" -f $folderCount), ("Third-party auto services: {0}" -f $serviceCount), ("Scheduled tasks with missing targets: {0}" -f $taskIssueCount)) `
                -Category 'summary' -Source 'Run keys + Startup folders + Get-ScheduledTask + Win32_Service'))
}
else {
    [void]$findings.Add((New-Finding -Id 'startup-summary' -Area $Area -Title ("Startup: {0} entries, {1} problem(s)" -f $rows.Count, $problems) -Status 'WARN' `
                -Evidence @(("Run/RunOnce: {0}" -f $runCount), ("Startup folder: {0}" -f $folderCount), ("Third-party auto services: {0}" -f $serviceCount), ("Scheduled tasks with missing targets: {0}" -f $taskIssueCount)) `
                -Category 'summary' -Source 'Run keys + Startup folders + Get-ScheduledTask + Win32_Service'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ startupEntries = $rows } -OutFile $OutFile
