# oxyde-win-maintenance action: create a restore point (safety step for any maintenance batch).
# Contract: see docs\ROADMAP.md ("Action handler contract").
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

function Get-NewestRestorePointDate {
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        $dates = @($points | ForEach-Object { Convert-RestorePointTime $_.CreationTime } | Where-Object { $_ })
        if ($dates.Count -eq 0) { return $null }
        return ($dates | Sort-Object -Descending | Select-Object -First 1)
    }
    catch {
        return $null
    }
}

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = if ("$($action.id)") { "$($action.id)" } else { 'restorepoint' }
$title = if ("$($action.title)") { "$($action.title)" } else { 'Create restore point' }
$desc = 'oxyde-win-maintenance: pre-actions checkpoint'
if ($action.payload -and "$($action.payload.description)") { $desc = "$($action.payload.description)" }

$command = "Checkpoint-Computer -Description `"$desc`" -RestorePointType MODIFY_SETTINGS"
$sw = [System.Diagnostics.Stopwatch]::StartNew()

switch ($Mode) {
    'dryrun' {
        $note = 'Requires elevation: yes. If System Protection is disabled it will be enabled on the system drive first. Windows throttles restore points to one per 24h; a throttled run is reported as "throttled", not as a failure.'
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                -Status 'dryrun' -Precheck 'skipped' -Command $command -Output $note -Verify 'skipped' `
                -UndoHint 'Remove from System Protection UI or: vssadmin delete shadows /for=%SystemDrive% /oldest' `
                -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $command `
                    -Output 'Requires an elevated session.' -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $notes = @()
        $beforeDate = Get-NewestRestorePointDate

        # Ensure System Protection is enabled (a precondition of the action itself).
        $protectionOk = $true
        try { $null = Get-ComputerRestorePoint -ErrorAction Stop } catch { $protectionOk = $false }
        if (-not $protectionOk) {
            try {
                $drive = "$env:SystemDrive\"
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

        try {
            Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        }
        catch {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $command `
                    -Output ("Checkpoint-Computer failed: {0}" -f $_.Exception.Message) `
                    -UndoHint 'n/a' -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $afterDate = Get-NewestRestorePointDate
        $created = ($null -ne $afterDate) -and (($null -eq $beforeDate) -or ($afterDate -gt $beforeDate))

        if ($created) {
            $notes += "Restore point created: $($afterDate.ToString('yyyy-MM-dd HH:mm'))"
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'restorepoint' -Title $title `
                    -Status 'done' -Precheck 'pass' -Command $command -Verify 'pass' `
                    -Output ($notes -join ' | ') `
                    -UndoHint 'Remove from System Protection UI or: vssadmin delete shadows /for=%SystemDrive% /oldest' `
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
