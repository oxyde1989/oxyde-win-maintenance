# oxyde-win-maintenance action: repair the component store - DISM RestoreHealth
# then sfc /scannow (_8 §4). The operation is NOT reversible: it refuses
# without a restore point created in the same batch (explicit override switch
# exists), warns when snapshots are being evicted, emits phase markers and a
# heartbeat while running (never a silent twenty-minute log), and verifies by
# measuring Total Detected Corruption before and after.
# Contract: see docs\ROADMAP.md ("Action handler contract").
# Payload: { restorePointCreated; overrideNoRestorePoint?; requireShadowHeadroom?;
#            targetMaxGB? } - the temp action copy also carries outDir.
# TEST HOOK: -StubSteps replaces the two long commands with short stubs and
# skips ONLY the elevation gate, so the smoke suite can assert steps[],
# markers and heartbeats without a real DISM run. All other preconditions
# still apply.
param(
    [Parameter(Mandatory)][ValidateSet('dryrun', 'apply', 'verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ActionFile,
    [Parameter(Mandatory)][string]$OutFile,
    [switch]$StubSteps,
    [switch]$OverrideNoRestorePoint,
    [switch]$RequireShadowHeadroom,
    [int]$HeartbeatSeconds = 30,
    [int]$StepTimeoutSeconds = 3600
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = if ("$($action.id)") { "$($action.id)" } else { 'integrity-repair' }
$title = if ("$($action.title)") { "$($action.title)" } else { 'Repair the component store (DISM + SFC)' }
$targetGB = 10
try { if ("$($action.payload.targetMaxGB)") { $targetGB = [int]$action.payload.targetMaxGB } } catch { }
if ($targetGB -le 0) { $targetGB = 10 }
$targetMB = $targetGB * 1024
$restorePointCreated = ("$($action.payload.restorePointCreated)" -match '^(?i)true$')
$override = $OverrideNoRestorePoint -or ("$($action.payload.overrideNoRestorePoint)" -match '^(?i)true$')
$requireHeadroom = $RequireShadowHeadroom -or ("$($action.payload.requireShadowHeadroom)" -match '^(?i)true$')
$commandText = 'dism.exe /Online /Cleanup-Image /RestoreHealth  &&  sfc.exe /scannow'
$undoText = 'No undo: a component-store repair is not reversible. The restore point created in the same batch is the only rollback.'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Read-CbsTailLines {
    param([int]$Lines = 8000)
    try { return @(Get-Content (Join-Path $env:SystemRoot 'Logs\CBS\CBS.log') -Tail $Lines -ErrorAction Stop) }
    catch { return @() }
}

function Get-Evictions7d {
    try { return @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'volsnap'; Id = 33; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue).Count }
    catch { return 0 }
}

function Get-ShadowMaxMB {
    try {
        $outText = (& cmd /c "vssadmin list shadowstorage 2>&1" | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $outText) { return $null }
        $info = Get-ShadowStorageInfo -Text $outText -Volume $env:SystemDrive
        if ($info.parsed -and $null -ne $info.maxMB) { return $info.maxMB }
        return $null
    }
    catch { return $null }
}

function Get-Preconditions {
    $evictions = Get-Evictions7d
    $maxMB = Get-ShadowMaxMB
    $pre = Get-IntegrityRepairPreconditions -RestorePointCreated $restorePointCreated -OverrideNoRestorePoint $override `
        -Evictions7d $evictions -CurrentMaxMB $maxMB -TargetMaxMB $targetMB -RequireShadowHeadroom $requireHeadroom
    return $pre
}

switch ($Mode) {
    'dryrun' {
        $pre = Get-Preconditions
        $parts = New-Object System.Collections.ArrayList
        if ($pre.proceed) { [void]$parts.Add('Preconditions pass.') }
        else { [void]$parts.Add('Would be skipped: ' + (@($pre.skips) -join ' | ')) }
        foreach ($n in @($pre.notes)) { [void]$parts.Add($n) }
        if ($StubSteps) { [void]$parts.Add('(test hook -StubSteps active: the two commands are replaced by stubs, elevation gate skipped)') }
        [void]$parts.Add('Nothing was executed.')
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'integrity-repair' -Title $title `
                -Status 'dryrun' -Precheck $(if ($pre.proceed) { 'pass' } else { 'fail' }) -Command $commandText `
                -Output (@($parts) -join ' ') -Verify 'skipped' -UndoHint $undoText -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not $StubSteps -and -not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'integrity-repair' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $commandText `
                    -Output 'Requires an elevated session.' -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $pre = Get-Preconditions
        if (-not $pre.proceed) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'integrity-repair' -Title $title `
                    -Status 'skipped' -Precheck 'fail' -Command $commandText `
                    -Output ('Refused: ' + (@($pre.skips) -join ' | ')) -UndoHint $undoText -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $runStart = Get-Date
        $beforeN = Get-CbsDetectedCorruption -Lines (Read-CbsTailLines) -Since $runStart.AddDays(-90)

        if ($StubSteps) {
            $psExe = Join-Path $PSHOME 'powershell.exe'
            $stepSpecs = @(
                @{ name = 'dism-restorehealth'; label = 'DISM /RestoreHealth'; exe = $psExe; display = 'STUB dism-restorehealth (test hook)'; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "Start-Sleep -Milliseconds 1500; Write-Output 'stub dism-restorehealth output'; exit 0") }
                @{ name = 'sfc-scannow'; label = 'sfc /scannow'; exe = $psExe; display = 'STUB sfc-scannow (test hook)'; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "Start-Sleep -Milliseconds 900; Write-Output 'stub sfc-scannow output'; exit 0") }
            )
        }
        else {
            $stepSpecs = @(
                @{ name = 'dism-restorehealth'; label = 'DISM /RestoreHealth'; exe = 'dism.exe'; display = 'dism.exe /Online /Cleanup-Image /RestoreHealth'; args = @('/Online', '/Cleanup-Image', '/RestoreHealth') }
                @{ name = 'sfc-scannow'; label = 'sfc /scannow'; exe = 'sfc.exe'; display = 'sfc.exe /scannow'; args = @('/scannow') }
            )
        }

        $steps = New-Object System.Collections.ArrayList
        $failedStep = ''
        $timedOutStep = ''
        $i = 0
        foreach ($spec in $stepSpecs) {
            $i++
            Write-Host ("[{0}/2] {1} started" -f $i, $spec.label)
            $stepStartedAt = (Get-Date).ToString('s')
            $r = Invoke-StreamedProcess -FilePath $spec.exe -Arguments $spec.args -TimeoutSeconds $StepTimeoutSeconds -HeartbeatSeconds $HeartbeatSeconds -HeartbeatLabel $spec.label
            $tail = (@($r.lines | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
            if ($tail.Length -gt 300) { $tail = $tail.Substring($tail.Length - 300) }
            [void]$steps.Add([pscustomobject]@{
                    name       = $spec.name
                    command    = $spec.display
                    startedAt  = $stepStartedAt
                    durationMs = $r.durationMs
                    exitCode   = $r.exitCode
                    tail       = $tail
                })
            if ($r.timedOut) {
                $timedOutStep = $spec.name
                Write-Host ("[{0}/2] {1} TIMED OUT after {2} s" -f $i, $spec.label, $StepTimeoutSeconds)
                break
            }
            Write-Host ("[{0}/2] {1} finished in {2} s: {3}" -f $i, $spec.label, [int]($r.durationMs / 1000), $tail)
            if ($null -ne $r.exitCode -and [int]$r.exitCode -ne 0 -and -not $failedStep) { $failedStep = $spec.name }
        }

        # Verify by measurement, not by assumption (_8 §4): the corruption
        # count from CBS before -> after, plus the SFC verdict.
        $afterN = Get-CbsDetectedCorruption -Lines (Read-CbsTailLines) -Since $runStart
        $sr = Get-CbsSrVerify -Lines (Read-CbsTailLines) -Since $runStart
        $beforeTxt = if ($beforeN -ge 0) { "$beforeN" } else { 'unknown' }
        $afterTxt = if ($afterN -ge 0) { "$afterN" } else { 'no fresh summary' }
        $pair = "CBS Total Detected Corruption: $beforeTxt -> $afterTxt"
        $sfcTxt = if ($sr.cannot -gt 0) { "SFC: Cannot repair markers x$($sr.cannot)" } elseif ($sr.complete -gt 0) { "SFC: verify complete x$($sr.complete)" } else { 'SFC: no fresh [SR] markers' }
        $verify = 'unknown'
        if ($afterN -eq 0) { $verify = 'pass' }
        elseif ($afterN -gt 0) { $verify = 'fail' }
        elseif ($sr.cannot -gt 0) { $verify = 'fail' }

        $outLines = New-Object System.Collections.ArrayList
        foreach ($n in @($pre.notes)) { [void]$outLines.Add("Note: $n") }
        foreach ($s in $steps) { [void]$outLines.Add(("[{0}] exit {1} in {2} s" -f $s.name, $s.exitCode, [int]($s.durationMs / 1000))) }
        [void]$outLines.Add($pair)
        [void]$outLines.Add($sfcTxt)
        if ($timedOutStep) { [void]$outLines.Add("Step timed out: $timedOutStep. The remaining step was NOT attempted.") }

        $status = 'done'
        if ($timedOutStep -or $failedStep) { $status = 'failed' }
        $lastExit = 0
        if (@($steps).Count -gt 0 -and $null -ne $steps[$steps.Count - 1].exitCode) { $lastExit = [int]$steps[$steps.Count - 1].exitCode }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'integrity-repair' -Title $title `
                -Status $status -Precheck 'pass' -Command $commandText -ExitCode $lastExit `
                -Output (@($outLines) -join "`n") -Verify $verify -UndoHint $undoText `
                -Steps @($steps) -DurationMs $sw.ElapsedMilliseconds)
    }

    'verify' {
        $n = Get-CbsDetectedCorruption -Lines (Read-CbsTailLines) -Since (Get-Date).AddDays(-90)
        $out = if ($n -ge 0) { "Latest CBS Total Detected Corruption: $n" } else { 'No corruption summary found in the CBS log.' }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'integrity-repair' -Title $title `
                -Status 'done' -Command '' -Output $out `
                -Verify $(if ($n -eq 0) { 'pass' } elseif ($n -gt 0) { 'fail' } else { 'unknown' }) `
                -DurationMs $sw.ElapsedMilliseconds)
    }
}
