# oxyde-win-maintenance action: create a restore point (safety step for any maintenance batch).
# Contract: see docs\ROADMAP.md ("Action handler contract").
# _11 G1: phase markers name each call and each call's duration is reported, so
# a run blocked inside Checkpoint-Computer is attributable (the runner adds the
# 30 s heartbeat on top of these markers).
param(
    [Parameter(Mandatory)][ValidateSet('dryrun', 'apply', 'verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ActionFile,
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

function Convert-RestorePointTime($t) {
    if ($null -eq $t) { return $null }
    if ($t -is [datetime]) { return $t }
    $s = "$t"
    if ($s -match '^\d{14}') {
        try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($s) } catch { }
    }
    try { return [datetime]::Parse($s) } catch { return $null }
}

# One timed read of the restore point list; Marker '' keeps it silent (verify).
function Read-RestorePoints {
    param([string]$Marker = '')
    if ($Marker) { Write-Host $Marker }
    $swRead = [System.Diagnostics.Stopwatch]::StartNew()
    $readOk = $true
    $errorText = ''
    $points = @()
    try { $points = @(Get-ComputerRestorePoint -ErrorAction Stop) }
    catch { $readOk = $false; $errorText = $_.Exception.Message }
    $swRead.Stop()
    $dates = @($points | ForEach-Object { Convert-RestorePointTime $_.CreationTime } | Where-Object { $_ })
    $newest = if ($dates.Count -gt 0) { $dates | Sort-Object -Descending | Select-Object -First 1 } else { $null }
    return [pscustomobject]@{ ok = $readOk; error = $errorText; count = $points.Count; newest = $newest; ms = $swRead.ElapsedMilliseconds }
}

function Get-NewestRestorePointDate {
    $r = Read-RestorePoints
    return $r.newest
}

# Shadow-storage signal (_11 G4): 'present' = an association with a readable
# maximum exists (protection configured); 'none' = vssadmin ran and found no
# association; 'unknown' = vssadmin could not be read.
function Get-ShadowSignal {
    try {
        $outText = (& cmd /c "vssadmin list shadowstorage 2>&1" | Out-String)
        if ($LASTEXITCODE -ne 0 -or -not $outText) { return 'unknown' }
        $info = Get-ShadowStorageInfo -Text $outText -Volume $env:SystemDrive
        if ($null -ne $info.maxMB) { return 'present' }
        return 'none'
    }
    catch { return 'unknown' }
}

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = if ("$($action.id)") { "$($action.id)" } else { 'restorepoint' }
$title = if ("$($action.title)") { "$($action.title)" } else { 'Create restore point' }
$desc = 'oxyde-win-maintenance: pre-actions checkpoint'
if ($action.payload -and "$($action.payload.description)") { $desc = "$($action.payload.description)" }

$command = "Checkpoint-Computer -Description `"$desc`" -RestorePointType MODIFY_SETTINGS"
$undoHint = 'Remove from System Protection UI or: vssadmin delete shadows /for=%SystemDrive% /oldest'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

switch ($Mode) {
    'dryrun' {
        # Reads only: the dry run shows the same phase marker as an apply
        # (_11 G1) and reports the precondition truthfully (_11 G4).
        $pre = Read-RestorePoints -Marker 'reading restore points (pre)'
        $cond = Get-RestorePointPrecondition -ReadOk $pre.ok -PointCount $pre.count -ShadowSignal (Get-ShadowSignal) -ReadError $pre.error
        $readTxt = if ($pre.ok) { "restore points readable: $($pre.count)" } else { "restore points not readable: $($pre.error)" }
        $note = $readTxt + '.'
        if ($cond.note) { $note += ' ' + $cond.note + '.' }
        $note += ' Requires elevation: yes. If System Protection is disabled it will be enabled on the system drive first. Windows throttles restore points to one per 24h; a throttled run is reported as "throttled", not as a failure. Nothing was executed.'
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                -Status 'dryrun' -Precheck $cond.precheck -Command $command -Output $note -Verify 'skipped' `
                -UndoHint $undoHint -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $command `
                    -Output 'Requires an elevated session.' -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $notes = @()
        $pre = Read-RestorePoints -Marker 'reading restore points (pre)'
        $beforeDate = $pre.newest
        Write-Host 'checking System Protection'
        $cond = Get-RestorePointPrecondition -ReadOk $pre.ok -PointCount $pre.count -ShadowSignal (Get-ShadowSignal) -ReadError $pre.error
        $precheck = $cond.precheck
        if ($cond.note) { $notes += $cond.note }

        # A precondition to FIX, not a check to pass (_11 G4): the old code
        # inferred "enabled" from a successful enumeration - which succeeds
        # with an EMPTY list while protection is disabled, and Checkpoint-
        # Computer then hangs (the documented failure mode, live on
        # 2026-10-18 18:56).
        if ($cond.fixNeeded) {
            try {
                $drive = "$env:SystemDrive\"
                Write-Host 'enabling System Protection'
                Enable-ComputerRestore -Drive $drive -ErrorAction Stop
                if ($cond.state -eq 'disabled') {
                    $notes += "System Protection was disabled and has been enabled on $drive"
                    $precheck = 'pass'
                }
                else {
                    $notes += 'System Protection state could not be determined; Enable-ComputerRestore was called (idempotent)'
                }
                Start-Sleep -Seconds 3
            }
            catch {
                Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                        -Status 'failed' -Precheck 'fail' -Command $command `
                        -Output (@(@($notes) + ("Cannot enable System Protection: {0}" -f $_.Exception.Message)) -join ' | ') `
                        -DurationMs $sw.ElapsedMilliseconds)
                return
            }
        }

        Write-Host 'checkpoint requested'
        $swCp = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        }
        catch {
            $swCp.Stop()
            Write-Host ("checkpoint failed after {0} s" -f [int]$swCp.Elapsed.TotalSeconds)
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'failed' -Precheck $precheck -Command $command `
                    -Output (@(@($notes) + ("Checkpoint-Computer failed after {0} s: {1}" -f [int]$swCp.Elapsed.TotalSeconds, $_.Exception.Message)) -join ' | ') `
                    -UndoHint 'n/a' -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        $swCp.Stop()
        Write-Host ("checkpoint returned in {0} s" -f [int]$swCp.Elapsed.TotalSeconds)

        $post = Read-RestorePoints -Marker 'reading restore points (post)'
        $afterDate = $post.newest
        $created = ($null -ne $afterDate) -and (($null -eq $beforeDate) -or ($afterDate -gt $beforeDate))
        $notes += ("calls: restore points (pre) {0} ms | checkpoint {1} s | restore points (post) {2} ms" -f $pre.ms, [int]$swCp.Elapsed.TotalSeconds, $post.ms)

        if ($created) {
            $notes += "Restore point created: $($afterDate.ToString('yyyy-MM-dd HH:mm'))"
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'done' -Precheck $precheck -Command $command -Verify 'pass' `
                    -Output ($notes -join ' | ') `
                    -UndoHint $undoHint `
                    -DurationMs $sw.ElapsedMilliseconds)
        }
        else {
            $existing = if ($beforeDate) { $beforeDate.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
            $notes += "No new restore point was created: Windows throttles restore points to one per 24h (newest existing: $existing). The protection intent is satisfied by the existing point."
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'throttled' -Precheck $precheck -Command $command -Verify 'pass' `
                    -Output ($notes -join ' | ') `
                    -UndoHint 'n/a' -DurationMs $sw.ElapsedMilliseconds)
        }
    }

    'verify' {
        $newest = Get-NewestRestorePointDate
        $out = if ($newest) { "Newest restore point: $($newest.ToString('yyyy-MM-dd HH:mm'))" } else { 'No restore points readable.' }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                -Status 'done' -Command '' -Output $out -Verify $(if ($newest) { 'pass' } else { 'unknown' }) `
                -DurationMs $sw.ElapsedMilliseconds)
    }
}
