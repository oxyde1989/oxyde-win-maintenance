<#
.SYNOPSIS
    oxyde-win-maintenance - execute an action plan (dry-run by default).

.DESCRIPTION
    Loads out\plan_latest.json (or -Plan <file>), previews each action's exact
    command, asks for confirmation (unless -Yes), performs at most one UAC
    elevation for the whole batch, writes out\apply_<ts>.json + .log and, after
    applying, re-scans the affected areas to produce a before/after diff.

.PARAMETER Plan
    Plan file (default: out\plan_latest.json).

.PARAMETER Apply
    Actually execute. Without this switch it is a dry run (commands only).

.PARAMETER Yes
    Skip the per-action confirmation prompts (unattended).

.PARAMETER Only
    Restrict to actions by id or kind (comma-separated).

.PARAMETER SkipRestorePoint
    Exclude the restore point safety step.

.PARAMETER NoVerify
    Skip the post-apply re-scan and diff.

.PARAMETER NoElevate
    Never relaunch elevated; actions that need admin will end as 'denied'.

.EXAMPLE
    .\PcApply.ps1                       # dry run of the default plan
    .\PcApply.ps1 -Apply                # interactive apply
    .\PcApply.ps1 -Apply -Yes -Only restorepoint
#>
[CmdletBinding()]
param(
    [string]$Plan,
    [string]$OutDir,
    [switch]$Apply,
    [switch]$Yes,
    [string[]]$Only = @(),
    [switch]$SkipRestorePoint,
    [switch]$NoVerify,
    [switch]$NoElevate,
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not $Plan) { $Plan = Join-Path $OutDir 'plan_latest.json' }
if (-not (Test-Path -LiteralPath $Plan)) {
    Write-Warning "Plan file not found: $Plan (run PcPlan.ps1 first)."
    exit 1
}

$planObj = Get-Content -LiteralPath $Plan -Raw -Encoding UTF8 | ConvertFrom-Json
$planPath = (Resolve-Path -LiteralPath $Plan).Path

# Discover the action catalog (kind -> handler file).
$kindMap = @{}
$actionsDir = Join-Path $PSScriptRoot 'actions'
foreach ($f in @(Get-ChildItem -LiteralPath $actionsDir -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    if ($f.Name -match '^(\d+)-([a-z0-9\-]+)\.ps1$') { $kindMap[$Matches[2].ToLower()] = $f.FullName }
}

# --- selection ---
$selected = @()
foreach ($a in @($planObj.actions)) {
    if ($SkipRestorePoint -and "$($a.kind)" -eq 'restorepoint') { continue }
    if ($Only.Count -gt 0) {
        if (($Only -notcontains "$($a.id)") -and ($Only -notcontains "$($a.kind)")) { continue }
    }
    elseif (-not $a.defaultSelected) { continue }
    $selected += $a
}

# Bulk covers per-package: drop single winget upgrades when the bulk is selected.
$bulkSelected = @($selected | Where-Object { "$($_.kind)" -eq 'winget-upgrade' -and "$($_.payload.mode)" -eq 'all' })
if ($bulkSelected.Count -gt 0) {
    $before = $selected.Count
    $selected = @($selected | Where-Object { -not ("$($_.kind)" -eq 'winget-upgrade' -and "$($_.payload.mode)" -eq 'one') })
    if ($selected.Count -lt $before) {
        Write-Host ("Note: {0} per-package winget action(s) skipped (covered by the bulk upgrade)." -f ($before - $selected.Count))
    }
}

if ($selected.Count -eq 0) {
    Write-Warning 'No actions selected.'
    exit 0
}

# --- one elevation for the whole batch ---
$needAdmin = @($selected | Where-Object { $_.adminRequired }).Count -gt 0
if ($Apply -and $needAdmin -and -not (Test-IsAdmin) -and -not $NoElevate) {
    Write-Host 'Administrator rights required: relaunching elevated (one UAC prompt)...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Plan', $planPath, '-Apply',
        '-OutDir', (Resolve-Path -LiteralPath $OutDir).Path, '-TimeoutSeconds', "$TimeoutSeconds")
    if ($Only.Count -gt 0) { $argList += @('-Only', ($Only -join ',')) }
    if ($Yes) { $argList += '-Yes' }
    if ($SkipRestorePoint) { $argList += '-SkipRestorePoint' }
    if ($NoVerify) { $argList += '-NoVerify' }
    try {
        $elevated = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList $argList -PassThru -Wait -ErrorAction Stop
        exit $elevated.ExitCode
    }
    catch {
        Write-Warning "Elevation was cancelled or failed: $($_.Exception.Message)"
        Write-Warning 'Continuing unelevated: admin actions will be reported as denied.'
    }
}

# --- handler invocation (child process, live output, timeout, JSON result) ---
function Invoke-Handler {
    param(
        [Parameter(Mandatory)][string]$HandlerPath,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$ActionFile,
        [int]$TimeoutSeconds,
        [string]$HeartbeatLabel = 'handler'
    )
    $tmpOut = Join-Path $env:TEMP ("oxyde-win-maintenance_action_{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    # Live streaming (Invoke-StreamedProcess, lib\Common.psm1): phase markers
    # and heartbeats from long-running handlers must reach this console - and
    # therefore the transcript the GUI tails - as they are produced, not only
    # after the handler exits (_8 §4/§6). The 30 s heartbeat is emitted by the
    # RUNNER (_11 G1): a single-threaded handler blocked inside a cmdlet cannot
    # heartbeat itself - exactly the state Checkpoint-Computer was in on
    # 2026-10-18 18:56, when five silent minutes read as "the tool is dead".
    $run = Invoke-StreamedProcess -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HandlerPath, '-Mode', $Mode, '-ActionFile', $ActionFile, '-OutFile', $tmpOut) `
        -TimeoutSeconds $TimeoutSeconds -HeartbeatSeconds 30 -HeartbeatLabel $HeartbeatLabel -OnLine { param($line) Write-Host $line }

    $result = $null
    if (Test-Path -LiteralPath $tmpOut) {
        try { $result = Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        Remove-Item -LiteralPath $tmpOut -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Result   = $result
        StdErr   = $run.output.Trim()
        ExitCode = $run.exitCode
        TimedOut = $run.timedOut
    }
}

# --- transcript ---
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $OutDir ("apply_$stamp.log")
$transcript = $false
try { Start-Transcript -LiteralPath $logPath -Force | Out-Null; $transcript = $true } catch { }

$results = New-Object System.Collections.ArrayList
$failed = 0
$denied = 0
$appliedKinds = @()
$rpSeen = $false   # a restorepoint action ran earlier in this batch (_8 §4)
$skipAll = $false

try {
    Write-Host ''
    Write-Host ("oxyde-win-maintenance apply - plan: {0}" -f $planPath)
    Write-Host ("Mode: {0} | actions: {1} | elevated: {2}" -f $(if ($Apply) { 'APPLY' } else { 'dry run' }), $selected.Count, (Test-IsAdmin))
    Write-Host ('-' * 72)

    # Every result records the effective budget it ran under (_11 G1), and the
    # [n/m] header states it, so a kill reads as "killed at its N s budget",
    # not as a bare message.
    function Add-ApplyResult {
        param($Result, [int]$Budget)
        if (-not $Result) { return }
        $Result | Add-Member -NotePropertyName timeoutSeconds -NotePropertyValue $Budget -Force
        [void]$results.Add($Result)
    }

    $idx = 0
    foreach ($a in $selected) {
        $idx++
        # Effective budget: explicit on the action (PcPlan always writes one),
        # else the runner default with a loud note - never a silent fallback.
        $actionTimeout = $TimeoutSeconds
        $budgetNote = ''
        if ($a.PSObject.Properties['timeoutSeconds']) {
            if ([int]$a.timeoutSeconds -gt 0) { $actionTimeout = [int]$a.timeoutSeconds }
            else { $budgetNote = ("declared timeoutSeconds '{0}' is not positive" -f $a.timeoutSeconds) }
        }
        else { $budgetNote = 'no declared timeoutSeconds (older plan?)' }

        if ($skipAll) {
            Add-ApplyResult -Result (New-ActionResult -Id "$($a.id)" -Kind "$($a.kind)" -Title "$($a.title)" -Status 'skipped' -Output 'Skipped by user (s)') -Budget $actionTimeout
            continue
        }

        $handler = $null
        $kindKey = "$($a.kind)".ToLower()
        if ($kindMap.ContainsKey($kindKey)) { $handler = $kindMap[$kindKey] }

        Write-Host ''
        Write-Host ("[{0}/{1}] {2} (budget {3} s)" -f $idx, $selected.Count, "$($a.title)", $actionTimeout)
        if ($budgetNote) { Write-Warning ("        {0}: using the runner default {1} s" -f $budgetNote, $TimeoutSeconds) }
        Write-Host ("        kind: {0} | risk: {1} | admin: {2}" -f $a.kind, $a.risk, $(if ($a.adminRequired) { 'yes' } else { 'no' }))

        if (-not $handler) {
            Write-Warning ("        no handler for kind '{0}'" -f $a.kind)
            Add-ApplyResult -Result (New-ActionResult -Id "$($a.id)" -Kind "$($a.kind)" -Title "$($a.title)" -Status 'failed' -Output "No handler found in actions\ for kind '$($a.kind)'.") -Budget $actionTimeout
            $failed++
            continue
        }

        $tmpAction = Join-Path $env:TEMP ("oxyde-win-maintenance_action_{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        # Handlers may need the tool's output directory (e.g. out\undo for
        # service-delete): add it to the temp action copy (additive contract;
        # handlers that ignore it are unaffected).
        if (-not $a.PSObject.Properties['outDir']) {
            $a | Add-Member -NotePropertyName outDir -NotePropertyValue $OutDir -Force
        }
        # integrity-repair requires a restore point created in the same batch
        # (_8 §4): inject what this batch has done so far. In dry-run the flag
        # mirrors the plan order, so the preview reflects the real outcome.
        if ($kindKey -eq 'integrity-repair') {
            if (-not $a.PSObject.Properties['payload'] -or $null -eq $a.payload) {
                $a | Add-Member -NotePropertyName payload -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $a.payload | Add-Member -NotePropertyName restorePointCreated -NotePropertyValue ([bool]$rpSeen) -Force
        }
        Write-JsonFile -InputObject $a -Path $tmpAction

        try {
            # dry run first: always show the exact command
            $dry = Invoke-Handler -HandlerPath $handler -Mode dryrun -ActionFile $tmpAction -TimeoutSeconds $actionTimeout -HeartbeatLabel $kindKey
            $dryResult = $dry.Result
            if ($dryResult -and "$($dryResult.command)") { Write-Host ("        command: {0}" -f $dryResult.command) }
            if ($dryResult -and "$($dryResult.output)") { Write-Host ("        note: {0}" -f $dryResult.output) }

            if (-not $Apply) {
                Add-ApplyResult -Result $dryResult -Budget $actionTimeout
                # In a dry run the batch executes nothing: the flag mirrors the
                # plan order so the integrity-repair preview shows the outcome
                # the real apply would have.
                if ($kindKey -eq 'restorepoint') { $rpSeen = $true }
                continue
            }

            $proceed = $true
            if (-not $Yes) {
                $ans = Read-Host '        Apply? [y = yes, n = skip, s = skip all remaining]'
                switch ("$ans".Trim().ToLower()) {
                    'y' { $proceed = $true }
                    's' { $proceed = $false; $skipAll = $true }
                    default { $proceed = $false }
                }
            }

            if (-not $proceed) {
                Add-ApplyResult -Result (New-ActionResult -Id "$($a.id)" -Kind "$($a.kind)" -Title "$($a.title)" -Status 'skipped' -Output 'Skipped by user') -Budget $actionTimeout
                continue
            }

            $applyRun = Invoke-Handler -HandlerPath $handler -Mode apply -ActionFile $tmpAction -TimeoutSeconds $actionTimeout -HeartbeatLabel $kindKey
            $res = $applyRun.Result
            if (-not $res) {
                $outTxt = if ($applyRun.TimedOut) { "Handler killed at its ${actionTimeout} s budget" } else { "Handler produced no result (exit $($applyRun.ExitCode)): $($applyRun.StdErr)" }
                $res = New-ActionResult -Id "$($a.id)" -Kind "$($a.kind)" -Title "$($a.title)" -Status 'failed' -Output $outTxt -ExitCode $([int]$applyRun.ExitCode)
            }
            Write-Host ("        result: {0} (verify: {1})" -f $res.status, $res.verify)
            if ("$($res.output)") { Write-Host ("        {0}" -f $res.output) }
            if ("$($res.undoHint)") { Write-Host ("        undo: {0}" -f $res.undoHint) }
            Add-ApplyResult -Result $res -Budget $actionTimeout

            if ("$($res.status)" -in @('done', 'throttled')) { $appliedKinds += $kindKey }
            # A done/throttled restore point satisfies the same-batch safety
            # requirement for integrity-repair (throttled = an existing point
            # within the 24h window satisfies the protection intent).
            if ($kindKey -eq 'restorepoint' -and "$($res.status)" -in @('done', 'throttled')) { $rpSeen = $true }
            if ("$($res.status)" -eq 'failed') { $failed++ }
            if ("$($res.status)" -eq 'denied') { $denied++ }
        }
        finally {
            Remove-Item -LiteralPath $tmpAction -ErrorAction SilentlyContinue
        }
    }

    # --- verification: re-scan affected areas and diff ---
    $verifyInfo = $null
    if ($Apply -and -not $NoVerify -and $appliedKinds.Count -gt 0) {
        $areaMap = @{
            'restorepoint'     = @('SystemProtection')
            'winget-upgrade'   = @('Winget')
            'service-delete'   = @('OrphanServices')
            'app-uninstall'    = @('Apps', 'Appx')
            'shadow-resize'    = @('Space', 'SystemProtection')
            'integrity-repair' = @('Integrity')
        }
        $areas = @()
        foreach ($k in ($appliedKinds | Select-Object -Unique)) {
            if ($areaMap.ContainsKey($k)) { $areas += $areaMap[$k] }
        }
        $areas = @($areas | Select-Object -Unique)

        if ($areas.Count -gt 0) {
            Write-Host ''
            Write-Host ("Verification: re-scanning {0} ..." -f ($areas -join ', '))
            $verifyDir = Join-Path $OutDir ("verify_$stamp")
            New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
            $scanScript = Join-Path $PSScriptRoot 'PcScan.ps1'
            $scanArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scanScript`" -Areas $($areas -join ',') -OutDir `"$verifyDir`" -NoHtml"
            $scanPsi = New-Object System.Diagnostics.ProcessStartInfo
            $scanPsi.FileName = Join-Path $PSHOME 'powershell.exe'
            $scanPsi.Arguments = $scanArgs
            $scanPsi.UseShellExecute = $false
            $scanPsi.CreateNoWindow = $true
            $scanProc = [System.Diagnostics.Process]::Start($scanPsi)
            $scanProc.WaitForExit()
            $scanProc.Dispose()

            $verifyReport = Join-Path $verifyDir 'scan_latest.json'
            if (Test-Path -LiteralPath $verifyReport) {
                $newScan = Get-Content -LiteralPath $verifyReport -Raw -Encoding UTF8 | ConvertFrom-Json
                $baseScan = Get-Content -LiteralPath $planObj.sourceReport -Raw -Encoding UTF8 | ConvertFrom-Json

                $baseById = @{}
                foreach ($f in @($baseScan.findings)) { $baseById["$($f.id)"] = $f }
                $newById = @{}
                foreach ($f in @($newScan.findings)) { $newById["$($f.id)"] = $f }

                $fixed = @(); $newIssues = @(); $unchanged = 0
                foreach ($k in $baseById.Keys) {
                    $b = $baseById[$k]
                    if ("$($b.status)" -notin @('WARN', 'CRIT')) { continue }
                    $n = $newById[$k]
                    if (-not $n -or "$($n.status)" -in @('OK', 'INFO')) { $fixed += "$($b.title)" }
                    else { $unchanged++ }
                }
                foreach ($k in $newById.Keys) {
                    $n = $newById[$k]
                    if ("$($n.status)" -notin @('WARN', 'CRIT')) { continue }
                    if (-not $baseById[$k] -or "$($baseById[$k].status)" -notin @('WARN', 'CRIT')) { $newIssues += "$($n.title)" }
                }

                $verifyInfo = [pscustomobject]@{
                    report    = $verifyReport
                    areas     = $areas
                    fixed     = @($fixed)
                    newIssues = @($newIssues)
                    unchanged = $unchanged
                }
                Write-Host ("  fixed: {0} | new issues: {1} | unchanged issues: {2}" -f @($fixed).Count, @($newIssues).Count, $unchanged)
            }
            else {
                Write-Warning 'Verification scan produced no report.'
            }
        }
    }
}
finally {
    if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }
}

# --- write apply result ---
$applyResult = [pscustomobject]@{
    applyVersion = 1
    appliedAt    = (Get-Date).ToString('s')
    plan         = $planPath
    mode         = $(if ($Apply) { 'apply' } else { 'dryrun' })
    elevated     = (Test-IsAdmin)
    log          = $logPath
    results      = @($results)
    verify       = $verifyInfo
}
$applyPath = Join-Path $OutDir ("apply_$stamp.json")
Write-JsonFile -InputObject $applyResult -Path $applyPath
Copy-Item -LiteralPath $applyPath -Destination (Join-Path $OutDir 'apply_latest.json') -Force

# --- summary ---
Write-Host ''
Write-Host 'Summary'
Write-Host ('-' * 40)
foreach ($grp in @($results | Group-Object status)) {
    Write-Host ("  {0,-10} {1}" -f $grp.Name, $grp.Count)
}
if (-not $Apply) { Write-Host '  (dry run: nothing was executed; add -Apply to execute)' }
Write-Host ''
Write-Host ("Result: {0}" -f $applyPath)
Write-Host ("Log:    {0}" -f $logPath)

if ($failed -gt 0 -or $denied -gt 0) { exit 1 }
exit 0
