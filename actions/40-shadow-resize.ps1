# oxyde-win-maintenance action: raise the shadow-storage maximum so restore
# points survive (volsnap silently evicts the oldest snapshot at the cap, _8 §3).
# Never shrinks: a target at or above the current maximum is a no-op, and a
# target below current usage is refused before trying. Honest undo: the
# previous maximum is read first and stated in undoHint.
# Contract: see docs\ROADMAP.md ("Action handler contract").
# Payload: { volume; targetMaxGB } - the temp action copy also carries outDir.
param(
    [Parameter(Mandatory)][ValidateSet('dryrun', 'apply', 'verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ActionFile,
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = if ("$($action.id)") { "$($action.id)" } else { 'shadow-resize' }
$title = if ("$($action.title)") { "$($action.title)" } else { 'Raise the shadow-storage limit' }
$volume = "$($action.payload.volume)"
if (-not $volume) { $volume = $env:SystemDrive }
$volume = $volume.TrimEnd('\').ToUpperInvariant()
if ($volume -notmatch '^[A-Z]:$') { $volume = ($volume.TrimEnd(':')) + ':' }
$targetGB = 10
try { if ("$($action.payload.targetMaxGB)") { $targetGB = [int]$action.payload.targetMaxGB } } catch { }
if ($targetGB -le 0) { $targetGB = 10 }
$targetMB = $targetGB * 1024
$command = "vssadmin resize shadowstorage /for=$volume /on=$volume /maxsize=${targetGB}GB"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-LiveShadow {
    param([string]$Vol)
    try {
        $outText = (& cmd /c "vssadmin list shadowstorage 2>&1" | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $outText) { return $null }
        return (Get-ShadowStorageInfo -Text $outText -Volume $Vol)
    }
    catch { return $null }
}

function Format-GB([object]$MB) {
    if ($null -eq $MB -or "$MB" -eq '') { return 'unknown' }
    return ("{0} GB" -f (Format-Num ([math]::Round([double]$MB / 1024, 2))))
}

switch ($Mode) {
    'dryrun' {
        $info = Get-LiveShadow -Vol $volume
        $precheck = 'skipped'
        $note = ''
        $undoHint = 'The previous maximum is read before resizing and stated in the result; changing it back is possible with: vssadmin resize shadowstorage /maxsize=<previous>GB'
        if ($info -and $info.parsed) {
            $dec = Get-ShadowResizeDecision -CurrentMaxMB $info.maxMB -CurrentUsedMB $info.usedMB -TargetMB $targetMB
            if ($dec.action -eq 'resize') {
                $precheck = 'pass'
                $note = ("Would raise the maximum for {0} from {1} (used {2}) to {3} GB. Nothing was executed." -f $info.volume, (Format-GB $info.maxMB), (Format-GB $info.usedMB), $targetGB)
            }
            else {
                $precheck = 'fail'
                $note = ("Would be skipped: {0} (current maximum {1}). Nothing was executed." -f $dec.reason, (Format-GB $info.maxMB))
            }
            if ($null -ne $info.maxMB) {
                $undoHint = ("previous maximum was {0} GB; revert with: vssadmin resize shadowstorage /for={1} /on={1} /maxsize={0}GB" -f (Format-Num ([math]::Round([double]$info.maxMB / 1024, 2))), $volume)
            }
        }
        else {
            $note = ("Current values not readable in this session (vssadmin needs elevation): the apply step re-reads before changing anything and would raise {0} to {1} GB. Nothing was executed." -f $volume, $targetGB)
        }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                -Status 'dryrun' -Precheck $precheck -Command $command -Output $note -Verify 'skipped' `
                -UndoHint $undoHint -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $command `
                    -Output 'Requires an elevated session.' -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        if (-not (Test-Path -LiteralPath ($volume + '\'))) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'failed' -Precheck 'fail' -Command $command `
                    -Output ("Volume {0} not found." -f $volume) -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        # Re-read live: never act on values from an older scan.
        $before = Get-LiveShadow -Vol $volume
        if (-not $before -or -not $before.parsed -or $null -eq $before.maxMB) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $command `
                    -Output 'Cannot read the current shadow-storage values (vssadmin returned no parsable output). Nothing was changed.' `
                    -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        $dec = Get-ShadowResizeDecision -CurrentMaxMB $before.maxMB -CurrentUsedMB $before.usedMB -TargetMB $targetMB
        if ($dec.action -ne 'resize') {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'skipped' -Precheck 'fail' -Command $command `
                    -Output ("Refused: {0} (current maximum {1}). Nothing was changed." -f $dec.reason, (Format-GB $before.maxMB)) `
                    -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $beforeGB = Format-Num ([math]::Round([double]$before.maxMB / 1024, 2))
        $startedAt = (Get-Date).ToString('s')
        $raw = ''
        $exit = -1
        try {
            $raw = (& cmd /c "$command 2>&1" | Out-String).Trim()
            $exit = $LASTEXITCODE
        }
        catch { $raw = "$($_.Exception.Message)" }

        # Verify by measurement: re-read and report before -> after (_8 §3).
        $after = Get-LiveShadow -Vol $volume
        $afterMax = $null
        if ($after -and $after.parsed) { $afterMax = $after.maxMB }
        $transition = ("Maximum {0}: {1} -> {2} (target {3} GB)" -f $volume, (Format-GB $before.maxMB), (Format-GB $afterMax), $targetGB)
        $step = [pscustomobject]@{
            name       = 'resize'
            command    = $command
            startedAt  = $startedAt
            durationMs = $sw.ElapsedMilliseconds
            exitCode   = $exit
            tail       = $transition
        }
        $undoHint = ("previous maximum was {0} GB; revert with: vssadmin resize shadowstorage /for={1} /on={1} /maxsize={0}GB" -f $beforeGB, $volume)
        $outText = @($transition, $raw) -join "`n"

        if ($exit -ne 0) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $command -ExitCode $exit -Output $outText `
                    -Verify 'fail' -UndoHint $undoHint -Steps @($step) -DurationMs $sw.ElapsedMilliseconds)
        }
        elseif ($null -ne $afterMax -and [double]$afterMax -ge $targetMB) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'done' -Precheck 'pass' -Command $command -ExitCode $exit -Output $outText `
                    -Verify 'pass' -UndoHint $undoHint -Steps @($step) -DurationMs $sw.ElapsedMilliseconds)
        }
        elseif ($null -eq $afterMax) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'done' -Precheck 'pass' -Command $command -ExitCode $exit `
                    -Output (@($outText, 'Re-read unavailable: the resize command reported success but the new maximum could not be verified.') -join "`n") `
                    -Verify 'unknown' -UndoHint $undoHint -Steps @($step) -DurationMs $sw.ElapsedMilliseconds)
        }
        else {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $command -ExitCode $exit `
                    -Output (@($outText, 'The resize did not take effect.') -join "`n") `
                    -Verify 'fail' -UndoHint $undoHint -Steps @($step) -DurationMs $sw.ElapsedMilliseconds)
        }
    }

    'verify' {
        $info = Get-LiveShadow -Vol $volume
        if ($info -and $info.parsed -and $null -ne $info.maxMB) {
            $ok = ([double]$info.maxMB -ge $targetMB)
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                    -Status 'done' -Command '' -Output ("Current maximum for {0}: {1} (target {2} GB)." -f $volume, (Format-GB $info.maxMB), $targetGB) `
                    -Verify $(if ($ok) { 'pass' } else { 'fail' }) -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'shadow-resize' -Title $title `
                -Status 'done' -Command '' -Output 'Shadow-storage values not readable in this session.' `
                -Verify 'unknown' -DurationMs $sw.ElapsedMilliseconds)
    }
}
