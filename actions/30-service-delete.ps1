# oxyde-win-maintenance action: delete an orphan service (ImagePath points to a
# missing file) with a mandatory registry undo export.
# Contract: see docs\ROADMAP.md ("Action handler contract").
# Payload: { serviceName; displayName }  - the temp action copy also carries the
# tool's outDir (added by PcApply) so the undo file lands in out\undo\.
param(
    [Parameter(Mandatory)][ValidateSet('dryrun', 'apply', 'verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ActionFile,
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = "$($action.id)"
$title = if ("$($action.title)") { "$($action.title)" } else { 'Delete orphan service' }
$name = "$($action.payload.serviceName)"
$display = "$($action.payload.displayName)"
if (-not $display) { $display = $name }
$svcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$keyPath = Join-Path $svcRoot $name
$outDir = "$($action.outDir)"
if (-not $outDir) { $outDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'out' }
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Get-KeyState {
    if (Test-Path -LiteralPath $keyPath) { return 'present' }
    return 'absent'
}

# Guards: live reads happen here, the DECISION is the pure function
# Get-ServiceDeleteGuardReasons (lib\Common.psm1, G3): the six guards can be
# replayed with synthetic records without elevation, in the smoke suite.
function Invoke-Guards {
    $record = [pscustomobject]@{
        serviceName    = $name
        keyExists      = $false
        keyReadable    = $true
        keyReadError   = ''
        imagePath      = ''
        resolvedPath   = ''
        resolvedExists = $false
        type           = 0
        start          = -1
        dependents     = @()
        systemRoot     = $env:SystemRoot
    }
    if ($name) {
        $record.keyExists = [bool](Test-Path -LiteralPath $keyPath)
        if ($record.keyExists) {
            try {
                $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop
                $record.imagePath = "$($props.ImagePath)"
                # Never trust a scan from minutes ago: re-resolve ImagePath now.
                $record.resolvedPath = Expand-ImagePath -ImagePath $record.imagePath
                if ($record.resolvedPath) {
                    $record.resolvedExists = [bool](Test-Path -LiteralPath $record.resolvedPath -ErrorAction SilentlyContinue)
                }
                try { $record.type = [int]$props.Type } catch { }
                try { $record.start = [int]$props.Start } catch { }
            }
            catch {
                $record.keyReadable = $false
                $record.keyReadError = $_.Exception.Message
            }
            if ($record.keyReadable) {
                # Reverse DependOnService scan (I/O stays here).
                try {
                    $dependents = @()
                    foreach ($k in @(Get-ChildItem -LiteralPath $svcRoot -ErrorAction SilentlyContinue)) {
                        if ($k.PSChildName -ieq $name) { continue }
                        try {
                            $dep = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'DependOnService' -ErrorAction SilentlyContinue).DependOnService
                            if ($dep -and @($dep | Where-Object { "$_" -ieq $name }).Count -gt 0) { $dependents += $k.PSChildName }
                        }
                        catch { }
                    }
                    $record.dependents = @($dependents)
                }
                catch { }
            }
        }
    }
    return [pscustomobject]@{
        reasons  = @(Get-ServiceDeleteGuardReasons -Record $record)
        resolved = $record.resolvedPath
        type     = $record.type
        start    = $record.start
    }
}

$qcText = ''
try { $qcText = (& sc.exe qc "$name" 2>&1 | Out-String).Trim() } catch { }
$cmdText = ("reg.exe export `"HKLM\SYSTEM\CurrentControlSet\Services\$name`" `"$outDir\undo\svc_${name}_<timestamp>.reg`" /y" + "`n" + "sc.exe delete `"$name`"")

switch ($Mode) {
    'dryrun' {
        $g = Invoke-Guards
        $reasons = @($g.reasons)
        $guardTxt = if ($reasons.Count -eq 0) {
            ("Guards: all passed (key exists; image still missing: {0}; Type={1}; Start={2}; path outside %SystemRoot%; no dependants). Nothing was executed." -f $g.resolved, $g.type, $g.start)
        }
        else { "Guards would refuse this action: " + ($reasons -join ' | ') }
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                -Status 'dryrun' -Precheck $(if ($reasons.Count -eq 0) { 'pass' } else { 'fail' }) `
                -Command $cmdText -Output $guardTxt `
                -UndoHint 'The registry key is exported to out\undo before deletion; restoring it is a manual elevated reg import + reboot.' `
                -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $cmdText `
                    -Output 'Requires an elevated session.' -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $g = Invoke-Guards
        $reasons = @($g.reasons)
        if ($reasons.Count -gt 0) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'skipped' -Precheck 'fail' -Command $cmdText `
                    -Output ("Refused: " + ($reasons -join ' | ')) -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        # Undo first: export the registry key, dossier the current config.
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $undoDir = Join-Path $outDir 'undo'
        if (-not (Test-Path -LiteralPath $undoDir)) { New-Item -ItemType Directory -Path $undoDir -Force | Out-Null }
        $undoFile = Join-Path $undoDir ("svc_{0}_{1}.reg" -f $name, $stamp)
        $exportOut = ''
        try {
            $exportOut = (& reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$name" "$undoFile" /y 2>&1 | Out-String).Trim()
            if (-not (Test-Path -LiteralPath $undoFile)) { throw "reg export produced no file ($exportOut)" }
        }
        catch {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $cmdText `
                    -Output ("Undo export failed, nothing was deleted: {0}" -f $_.Exception.Message) -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        # Delete (sc.exe only; no registry fallback by design).
        $delCmd = "sc.exe delete `"$name`""
        $delOut = ''
        $delExit = -1
        try { $delOut = (& sc.exe delete "$name" 2>&1 | Out-String).Trim(); $delExit = $LASTEXITCODE } catch { }

        $state = Get-KeyState
        $marked = ($delOut -match '(?i)(marked for deletion|contrassegnato per l.eliminazione)')
        if ($state -eq 'absent' -or $marked) {
            $note = if ($state -eq 'absent') { 'Service key removed.' } else { 'Marked for deletion: final after the next reboot.' }
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'done' -Precheck 'pass' -Command $delCmd -ExitCode $delExit `
                    -Output (@($note, "Display name: $display", "Undo export: $undoFile", $qcText, $delOut) -join "`n") `
                    -Verify 'pass' `
                    -UndoHint ("Manual restore: reg import `"$undoFile`" (elevated), then reboot. The deletion itself is final only after a reboot.") `
                    -UndoFile $undoFile -DurationMs $sw.ElapsedMilliseconds)
        }
        elseif ($delOut -match '(?i)(access is denied|accesso negato)' -or $delExit -eq 5) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'denied' -Precheck 'pass' -Command $delCmd -ExitCode $delExit `
                    -Output (@('Access denied. If a security product protects this service, disable or remove the parent product first.', $delOut) -join "`n") `
                    -UndoFile $undoFile -DurationMs $sw.ElapsedMilliseconds)
        }
        else {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $delCmd -ExitCode $delExit `
                    -Output $delOut -UndoFile $undoFile -DurationMs $sw.ElapsedMilliseconds)
        }
    }

    'verify' {
        if ((Get-KeyState) -eq 'absent') {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                    -Status 'done' -Output 'The service key is gone.' -Verify 'pass' -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        $q = ''
        try { $q = (& sc.exe query "$name" 2>&1 | Out-String).Trim() } catch { }
        $marked = ($q -match '(?i)(marked for deletion|contrassegnato per l.eliminazione|1060)')
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'service-delete' -Title $title `
                -Status 'done' -Output $(if ($marked) { 'Marked for deletion: final after reboot.' } else { 'The service still exists and is usable.' }) `
                -Verify $(if ($marked) { 'pass' } else { 'fail' }) -DurationMs $sw.ElapsedMilliseconds)
    }
}
