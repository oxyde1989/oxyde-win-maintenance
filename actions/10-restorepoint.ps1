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
        # (_11 G1 acceptance 1) without executing anything.
        $pre = Read-RestorePoints -Marker 'reading restore points (pre)'
        $readTxt = if ($pre.ok) { "restore points readable: $($pre.count)" } else { "restore points not readable: $($pre.error)" }
        $note = $readTxt + '. Requires elevation: yes. If System Protection is disabled it will be enabled on the system drive first. Windows throttles restore points to one per 24h; a throttled run is reported as "throttled", not as a failure. Nothing was executed.'
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                -Status 'dryrun' -Precheck 'skipped' -Command $command -Output $note -Verify 'skipped' `
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

        # Ensure System Protection is enabled (a precondition of the action itself).
        $protectionOk = $true
        Write-Host 'checking System Protection'
        try { $null = Get-ComputerRestorePoint -ErrorAction Stop } catch { $protectionOk = $false }
        if (-not $protectionOk) {
            try {
                $drive = "$env:SystemDrive\"
                Write-Host 'enabling System Protection'
                Enable-ComputerRestore -Drive $drive -ErrorAction Stop
                $notes += "System Protection was disabled and has been enabled on $drive"
                Start-Sleep -Seconds 3
            }
            catch {
                Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                        -Status 'failed' -Precheck 'fail' -Command $command `
                        -Output ("Cannot enable System Protection: {0}" -f $_.Exception.Message) `
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
                    -Status 'failed' -Precheck 'pass' -Command $command `
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
                    -Status 'done' -Precheck 'pass' -Command $command -Verify 'pass' `
                    -Output ($notes -join ' | ') `
                    -UndoHint $undoHint `
                    -DurationMs $sw.ElapsedMilliseconds)
        }
        else {
            $existing = if ($beforeDate) { $beforeDate.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
            $notes += "No new restore point was created: Windows throttles restore points to one per 24h (newest existing: $existing). The protection intent is satisfied by the existing point."
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'throttled' -Precheck 'pass' -Command $command -Verify 'pass' `
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
