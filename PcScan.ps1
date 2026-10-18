<#
.SYNOPSIS
    oxyde-win-maintenance - Windows maintenance scanner. Runs probes from probes\ and produces
    a JSON + HTML report (read-only, no changes to the system).

.EXAMPLE
    .\PcScan.ps1 -Profile quick -Open
    Fast health check (default profile), opens the HTML report.

.EXAMPLE
    .\PcScan.ps1 -Profile standard
    Full scan: Windows Update search, winget, drivers, all areas.

.EXAMPLE
    .\PcScan.ps1 -Areas Apps,Winget -NoHtml
    Selected areas only (within the active profile), no HTML report.

.PARAMETER Profile
    Scan profile defined in profiles.psd1: quick (default), standard, deep.
    The profile selects the areas, per-probe timeouts and network labels;
    probes read it via the OXYDE_PROFILE environment variable.

.PARAMETER Areas
    Case-insensitive filter on areas: WindowsUpdate, Apps, Winget, Appx, Drivers,
    PendingReboot, OrphanServices, SystemProtection.
    Empty = profile areas.

.PARAMETER TimeoutSeconds
    Global per-probe timeout fallback in seconds (default 300); profiles may
    declare a lower per-area timeout.

.PARAMETER Version
    Prints the tool version and exits.

.OUTPUTS
    Exit code reflects the health verdict: 0 = OK, 1 = WARNING, 2 = CRITICAL.
#>
[CmdletBinding()]
param(
    [ValidateSet('quick', 'standard', 'deep')][string]$Profile = 'quick',
    [string[]]$Areas = @(),
    [string]$OutDir,
    [int]$TimeoutSeconds = 300,
    [switch]$NoHtml,
    [switch]$Open,
    [switch]$Version
)

$ErrorActionPreference = 'Continue'

if ($Version) {
    Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force
    Write-Host ("oxyde-win-maintenance {0} (schema v5)" -f (Get-OxydeVersion))
    exit 0
}

# Normalize -Areas even when it arrives as a single "A,B" string (invoked with -File).
$Areas = @($Areas | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# --- scan profile ---
$profiles = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'profiles.psd1')
$activeProfile = $profiles[$Profile]
if (-not $activeProfile) { throw "Unknown profile '$Profile' in profiles.psd1" }

$probeDir = Join-Path $PSScriptRoot 'probes'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

# --- host info ---
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$started = Get-Date
$exe = Join-Path $PSHOME 'powershell.exe'

# --- extended hardware info (best-effort, read-only) ---
$ramGB = $null
if ($cs.TotalPhysicalMemory) { $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }

$biosDate = ''
if ($bios -and $bios.ReleaseDate) {
    try { $biosDate = ([datetime]$bios.ReleaseDate).ToString('yyyy-MM-dd') } catch { }
}

$osInstallDate = ''
if ($os -and $os.InstallDate) {
    try { $osInstallDate = ([datetime]$os.InstallDate).ToString('yyyy-MM-dd') } catch { }
}

$uptimeText = ''
if ($os -and $os.LastBootUpTime) {
    try {
        $ts = (Get-Date) - [datetime]$os.LastBootUpTime
        $uptimeText = "{0} d {1} h" -f [int]$ts.TotalDays, $ts.Hours
    } catch { }
}

$disks = @()
foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Sort-Object DeviceID)) {
    $sizeGB = $null; $freeGB = $null; $pctFree = $null
    if ($d.Size -gt 0) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
        $pctFree = [math]::Round(($d.FreeSpace / $d.Size) * 100, 1)
    }
    $disks += [pscustomobject]@{
        drive   = "$($d.DeviceID)"
        label   = "$($d.VolumeName)"
        sizeGB  = $sizeGB
        freeGB  = $freeGB
        pctFree = $pctFree
    }
}

# --- probe discovery ---
# Explicit -Areas wins over the profile areas; the profile still governs
# timeouts, network labels and the OXYDE_PROFILE value seen by probes.
# $discoveredAreas keeps the full picture for health.coverage.
$effectiveAreas = if ($Areas.Count -gt 0) { $Areas } else { @($activeProfile.areas) }
$probes = @()
$discoveredAreas = @()
foreach ($f in @(Get-ChildItem -LiteralPath $probeDir -Filter '*.ps1' | Sort-Object Name)) {
    if ($f.Name -notmatch '^(\d+)-([A-Za-z0-9]+)\.ps1$') {
        Write-Warning "Probe skipped (name does not match 'NN-Area.ps1'): $($f.Name)"
        continue
    }
    $area = $Matches[2]
    $discoveredAreas += $area
    if ($effectiveAreas.Count -gt 0 -and ($effectiveAreas -notcontains $area)) { continue }
    $probes += [pscustomobject]@{ Area = $area; File = $f.FullName; Name = $f.Name }
}
$discoveredAreas = @($discoveredAreas | Select-Object -Unique)
if ($probes.Count -eq 0) {
    Write-Warning 'No probes to run.'
    return
}

# --- run probes in child processes (isolation + timeout) ---
$allFindings = New-Object System.Collections.ArrayList
$allDatasets = @{}
$probeRuns = @()

Write-Host ("oxyde-win-maintenance scan (profile: {0})" -f $Profile)
if ($Profile -eq 'deep' -and -not (Test-IsAdmin)) {
    Write-Warning 'Deep profile without elevation: elevated checks (DISM/SFC integrity, shadow storage) are skipped. Relaunch from an elevated prompt or use the GUI "Deep scan (admin)".'
}
$oldProfileEnv = $env:OXYDE_PROFILE
$env:OXYDE_PROFILE = $Profile

foreach ($p in $probes) {
    Write-Host ("[{0}] {1} ... " -f (Get-Date -Format 'HH:mm:ss'), $p.Area) -NoNewline
    $tmp = Join-Path $env:TEMP ("oxyde-win-maintenance_{0}_{1}.json" -f $p.Area, [guid]::NewGuid().ToString('N').Substring(0, 8))

    $probeTimeout = $TimeoutSeconds
    if ($activeProfile.timeouts -and $activeProfile.timeouts.ContainsKey($p.Area)) { $probeTimeout = [int]$activeProfile.timeouts[$p.Area] }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($p.File)`" -OutFile `"$tmp`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $exited = $proc.WaitForExit($probeTimeout * 1000)
    if (-not $exited) { try { $proc.Kill() } catch { } }
    $proc.WaitForExit()
    $sw.Stop()
    $stderr = ''
    $stdout = ''
    try { $stderr = $stderrTask.Result } catch { }
    try { $stdout = $stdoutTask.Result } catch { }
    $exitCode = $null
    try { $exitCode = $proc.ExitCode } catch { }
    $proc.Dispose()

    $run = [pscustomobject]@{
        area           = $p.Area
        file           = $p.Name
        status         = 'ok'
        durationMs     = $sw.ElapsedMilliseconds
        error          = ''
        network        = [bool]($activeProfile.network -contains $p.Area)
        timeoutSeconds = $probeTimeout
    }

    if (-not $exited) {
        $run.status = 'timeout'
        $run.error = "Timeout after ${probeTimeout}s"
    }
    elseif ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        $run.status = 'error'
        $run.error = ($stderr + "`n" + $stdout).Trim()
    }
    else {
        try {
            $data = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.findings) { foreach ($f in @($data.findings)) { [void]$allFindings.Add($f) } }
            if ($data.datasets) {
                foreach ($prop in @($data.datasets.PSObject.Properties)) { $allDatasets[$prop.Name] = $prop.Value }
            }
        } catch {
            $run.status = 'error'
            $run.error = "Invalid JSON: $($_.Exception.Message)"
        }
    }
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue

    if ($run.status -ne 'ok') {
        if ($run.error.Length -gt 2000) { $run.error = $run.error.Substring(0, 2000) + ' ...' }
        [void]$allFindings.Add((New-Finding -Id ("probe-" + $p.Area.ToLower()) -Area $p.Area `
                    -Title ("Probe failed: {0} ({1})" -f $p.Area, $run.status) -Status 'CRIT' `
                    -Evidence @($run.error) -SuggestedAction "Inspect area $($p.Area) manually."))
    }

    $probeRuns += $run
    Write-Host ("{0} ({1} ms)" -f $run.status, $run.durationMs)
}

if ($null -eq $oldProfileEnv) { Remove-Item Env:OXYDE_PROFILE -ErrorAction SilentlyContinue } else { $env:OXYDE_PROFILE = $oldProfileEnv }

# --- coverage: what ran vs what exists (never hide skipped checks) ---
# `partial` means a real loss of coverage: an explicit -Areas narrowing,
# a failed/timed-out probe, or a deep scan without elevation. Areas skipped
# only because the profile does not include them are declared scope, not a
# loss: they stay visible in areasSkipped/profileScope without the alarm (D19).
$isAdmin = Test-IsAdmin
$runAreas = @($probeRuns | ForEach-Object { $_.area })
$skippedAreas = @($discoveredAreas | Where-Object { $runAreas -notcontains $_ })
$failedAreas = @($probeRuns | Where-Object { $_.status -in @('error', 'timeout') } | ForEach-Object { $_.area })
$networkDependent = @($probeRuns | Where-Object { $_.network } | ForEach-Object { $_.area })
$deepWithoutElevation = [bool]($Profile -eq 'deep' -and -not $isAdmin)
$explicitAreas = @($Areas)
$profileAreas = @($activeProfile.areas)
$profileScope = if ($explicitAreas.Count -gt 0) { @() } else { @($skippedAreas | Where-Object { $profileAreas -notcontains $_ }) }
if ($deepWithoutElevation) {
    [void]$allFindings.Add((New-Finding -Id 'engine-deep-unelevated' -Area 'System' -Title 'Deep profile requested without elevation: elevated checks are skipped' -Status 'INFO' `
                -Evidence @('Run from an elevated prompt (or use the GUI "Deep scan (admin)") for the full deep scan.') `
                -Source 'oxyde-win-maintenance engine'))
}
$partial = [bool](($explicitAreas.Count -gt 0 -and $skippedAreas.Count -gt 0) -or $failedAreas.Count -gt 0 -or $deepWithoutElevation)
$coverage = [pscustomobject]@{
    areasRun             = $runAreas
    areasSkipped         = $skippedAreas
    profileScope         = $profileScope
    explicitAreas        = $explicitAreas
    failedProbes         = $failedAreas
    networkDependent     = $networkDependent
    elevated             = $isAdmin
    deepWithoutElevation = $deepWithoutElevation
    partial              = $partial
}

# --- assemble report ---
$statusRank = @{ 'CRIT' = 0; 'WARN' = 1; 'INFO' = 2; 'OK' = 3 }
$sortedFindings = @($allFindings | Sort-Object `
        @{ Expression = { $statusRank[[string]$_.status] } }, `
        @{ Expression = { [string]$_.area } }, `
        @{ Expression = { [string]$_.title } })

# --- health verdict ---
# Score: -25 per CRIT, -8 per WARN, clamped 0..100. INFO/OK never penalize;
# unknown/INFO never count as healthy (only WARN/CRIT demote the verdict).
# Roll-up ("summary") findings are excluded from score/topIssues/verdict: they
# duplicate the individual findings of their area (D18).
$counts = @{ CRIT = 0; WARN = 0; INFO = 0; OK = 0 }
foreach ($f in $sortedFindings) { if ($counts.ContainsKey([string]$f.status)) { $counts[[string]$f.status]++ } }

$scoredFindings = @($sortedFindings | Where-Object { "$($_.category)" -ne 'summary' })
$scoredCrit = @($scoredFindings | Where-Object { "$($_.status)" -eq 'CRIT' }).Count
$scoredWarn = @($scoredFindings | Where-Object { "$($_.status)" -eq 'WARN' }).Count

$score = 100 - (25 * $scoredCrit) - (8 * $scoredWarn)
if ($score -lt 0) { $score = 0 }
$verdict = if ($scoredCrit -gt 0) { 'CRITICAL' } elseif ($scoredWarn -gt 0) { 'WARNING' } else { 'OK' }
$topIssues = @($scoredFindings | Where-Object { "$($_.status)" -in @('CRIT', 'WARN') } | Select-Object -First 5 | ForEach-Object {
        [pscustomobject]@{ id = "$($_.id)"; area = "$($_.area)"; title = "$($_.title)"; status = "$($_.status)" }
    })
$health = [pscustomobject]@{
    score     = $score
    verdict   = $verdict
    counts    = [pscustomobject]@{ crit = $counts.CRIT; warn = $counts.WARN; info = $counts.INFO; ok = $counts.OK }
    topIssues = $topIssues
    profile   = $Profile
    adminUsed = $isAdmin
    coverage  = $coverage
}

$report = [pscustomobject]@{
    schemaVersion = 5
    generatedAt   = (Get-Date).ToString('s')
    durationMs    = [int]((Get-Date) - $started).TotalMilliseconds
    profile       = $Profile
    health        = $health
    host          = [pscustomobject]@{
        name         = $env:COMPUTERNAME
        user         = "$env:USERDOMAIN\$env:USERNAME"
        elevated     = (Test-IsAdmin)
        psVersion    = $PSVersionTable.PSVersion.ToString()
        osCaption    = "$($os.Caption)"
        osVersion    = "$($os.Version)"
        osBuild      = "$($os.BuildNumber)"
        osInstall    = $osInstallDate
        lastBoot     = $(if ($os -and $os.LastBootUpTime) { try { ([datetime]$os.LastBootUpTime).ToString('yyyy-MM-dd HH:mm') } catch { '' } } else { '' })
        uptime       = $uptimeText
        manufacturer = "$($cs.Manufacturer)"
        model        = "$($cs.Model)"
        cpuName      = $(if ($cpu) { "$($cpu.Name)".Trim() } else { '' })
        cpuCores     = $(if ($cpu) { "$($cpu.NumberOfCores)" } else { '' })
        cpuThreads   = $(if ($cpu) { "$($cpu.NumberOfLogicalProcessors)" } else { '' })
        ramGB        = $ramGB
        biosVersion  = $(if ($bios) { "$($bios.SMBIOSBIOSVersion)" } else { '' })
        biosDate     = $biosDate
        disks        = $disks
    }
    probes        = @($probeRuns)
    findings      = $sortedFindings
    datasets      = $allDatasets
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$jsonPath = Join-Path $OutDir ("scan_$stamp.json")
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 10), $enc)

# Only a full scan updates scan_latest.* (the reference report used by PcPlan and the GUI);
# a partial scan (-Areas) must not silently replace it with a subset.
$isFullScan = ($Areas.Count -eq 0)
if ($isFullScan) { Copy-Item -LiteralPath $jsonPath -Destination (Join-Path $OutDir 'scan_latest.json') -Force }

$htmlPath = ''
if (-not $NoHtml) {
    . (Join-Path $PSScriptRoot 'render\Report-Html.ps1')
    $htmlPath = New-HtmlReport -Report $report -OutFile (Join-Path $OutDir ("scan_$stamp.html")) -JsonFileName (Split-Path -Leaf $jsonPath)
    if ($isFullScan) { Copy-Item -LiteralPath $htmlPath -Destination (Join-Path $OutDir 'scan_latest.html') -Force }
}

# --- retention: keep the newest 30 scan pairs (scan_latest.* is separate) ---
if ($isFullScan) {
    $oldScans = @(Get-ChildItem -LiteralPath $OutDir -Filter 'scan_*.json' |
            Where-Object { $_.Name -ne 'scan_latest.json' } |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 30)
    foreach ($old in $oldScans) {
        Remove-Item -LiteralPath $old.FullName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ([System.IO.Path]::ChangeExtension($old.FullName, 'html')) -ErrorAction SilentlyContinue
    }
}

# --- console summary ---
Write-Host ''
Write-Host ("Verdict: {0} (score {1}){2}" -f $verdict, $score, $(if ($coverage.partial) { ' [partial coverage]' } else { '' }))
if ($coverage.partial) {
    if ($skippedAreas.Count -gt 0) { Write-Host ("Areas skipped: {0}" -f ($skippedAreas -join ', ')) }
    if ($failedAreas.Count -gt 0) { Write-Host ("Failed probes: {0}" -f ($failedAreas -join ', ')) }
}
Write-Host ("CRIT {0} | WARN {1} | INFO {2} | OK {3}  ({4} ms)" -f $counts.CRIT, $counts.WARN, $counts.INFO, $counts.OK, $report.durationMs)
if (-not $isFullScan) { Write-Host '(partial scan: scan_latest.* not updated)' }
Write-Host ("JSON: {0}" -f $jsonPath)
if ($htmlPath) {
    Write-Host ("HTML: {0}" -f $htmlPath)
    if ($Open) { Start-Process $htmlPath }
}

$exitCode = 0
if ($verdict -eq 'WARNING') { $exitCode = 1 }
if ($verdict -eq 'CRITICAL') { $exitCode = 2 }
exit $exitCode
