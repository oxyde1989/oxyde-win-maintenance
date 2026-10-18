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

# Guards: each adds a distinct refusal reason. Evaluated in dry-run too (the
# dry-run prints them and changes nothing). Returns reasons + the values used.
function Invoke-Guards {
    $reasons = New-Object System.Collections.ArrayList
    $resolved = ''
    $type = 0
    $start = -1
    if (-not $name) {
        [void]$reasons.Add('Payload has no serviceName.')
        return [pscustomobject]@{ reasons = @($reasons); resolved = $resolved; type = $type; start = $start }
    }
    if ((Get-KeyState) -eq 'absent') {
        [void]$reasons.Add("The service key does not exist: $keyPath")
        return [pscustomobject]@{ reasons = @($reasons); resolved = $resolved; type = $type; start = $start }
    }

    $props = $null
    try { $props = Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop }
    catch {
        [void]$reasons.Add("The service key is not readable: $($_.Exception.Message)")
        return [pscustomobject]@{ reasons = @($reasons); resolved = $resolved; type = $type; start = $start }
    }

    # Never trust a scan from minutes ago: re-resolve ImagePath now.
    $resolved = Expand-ImagePath -ImagePath "$($props.ImagePath)"
    if (-not $resolved) {
        [void]$reasons.Add("ImagePath not resolvable: '$($props.ImagePath)'")
    }
    elseif (Test-Path -LiteralPath $resolved -ErrorAction SilentlyContinue) {
        [void]$reasons.Add("ImagePath now resolves to an existing file: $resolved (no longer an orphan)")
    }

    # Not a driver, not boot/system start.
    try { $type = [int]$props.Type } catch { }
    if (($type -band 0x3) -ne 0) { [void]$reasons.Add("Driver service (Type=$type): refusing to delete a driver") }
    try { $start = [int]$props.Start } catch { }
    if ($start -eq 0 -or $start -eq 1) { [void]$reasons.Add("Boot/System start (Start=$start): refusing to delete an early-boot component") }

    # A missing file under %SystemRoot% is a damaged OS component, not residue.
    if ($resolved -and $resolved.ToLowerInvariant().StartsWith($env:SystemRoot.ToLowerInvariant())) {
        [void]$reasons.Add('The missing file is inside %SystemRoot%: damaged OS component, not app residue (run DISM /RestoreHealth or sfc instead)')
    }

    # No other service may depend on it.
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
        if ($dependents.Count -gt 0) {
            [void]$reasons.Add(("Still referenced by DependOnService: {0}" -f ($dependents -join ', ')))
        }
    }
    catch { }
    return [pscustomobject]@{ reasons = @($reasons); resolved = $resolved; type = $type; start = $start }
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
