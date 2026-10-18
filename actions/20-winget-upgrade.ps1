# oxyde-win-maintenance action: upgrade packages via winget (bulk or single).
# Contract: see docs\ROADMAP.md ("Action handler contract").
# Payload: { mode: 'all' } or { mode: 'one'; packageId; name; from; to }
param(
    [Parameter(Mandatory)][ValidateSet('dryrun', 'apply', 'verify')][string]$Mode,
    [Parameter(Mandatory)][string]$ActionFile,
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

function Invoke-WingetCli {
    param([string[]]$WingetArgs, [int]$TimeoutSeconds = 900)
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) { return [pscustomobject]@{ Available = $false; ExitCode = -1; Output = 'winget not found in PATH'; TimedOut = $false } }

    $argLine = ($WingetArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) { try { $proc.Kill() } catch { } }
    $proc.WaitForExit()
    $out = ''
    try { $out = $outTask.Result } catch { }
    try { $out += $errTask.Result } catch { }
    $code = -1
    try { $code = $proc.ExitCode } catch { }
    $proc.Dispose()

    $out = ($out -replace "\x1B\[[0-9;]*[A-Za-z]", '').Trim()
    return [pscustomobject]@{ Available = $true; ExitCode = [int]$code; Output = $out; TimedOut = (-not $exited) }
}

function Get-InstalledVersion {
    param([string]$PackageId)
    $r = Invoke-WingetCli -WingetArgs @('list', '--id', $PackageId, '--disable-interactivity', '--accept-source-agreements') -TimeoutSeconds 120
    if (-not $r.Available -or -not $r.Output) { return $null }
    foreach ($line in @($r.Output -split "`r?`n")) {
        if ($line -match '^\s*-{3,}') { continue }
        $m = [regex]::Match($line, '^(?<name>.+?)\s{2,}(?<id>\S+)\s{2,}(?<ver>\S+)')
        if ($m.Success -and $m.Groups['id'].Value -ieq $PackageId) { return $m.Groups['ver'].Value }
    }
    return $null
}

function Get-UpgradeRowCount {
    $r = Invoke-WingetCli -WingetArgs @('upgrade', '--source', 'winget', '--disable-interactivity', '--accept-source-agreements') -TimeoutSeconds 300
    if (-not $r.Available -or -not $r.Output) { return $null }
    $lines = @($r.Output -split "`r?`n")
    $sepIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^-{3,}') { $sepIdx = $i; break } }
    if ($sepIdx -lt 0) { return 0 }
    $count = 0
    for ($i = $sepIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { if ($count -gt 0) { break } else { continue } }
        if ($line -match '^\s*-{3,}') { continue }
        if ($line -match '^(?<name>.+?)\s{2,}(?<id>\S+)\s{2,}(?<ver>\S+)\s{2,}(?<avail>\S+)') { $count++ }
    }
    return $count
}

$action = Get-Content -LiteralPath $ActionFile -Raw -Encoding UTF8 | ConvertFrom-Json
$id = "$($action.id)"
$title = if ("$($action.title)") { "$($action.title)" } else { 'Upgrade winget packages' }
$pkgMode = "$($action.payload.mode)"
if ($pkgMode -ne 'all' -and $pkgMode -ne 'one') { $pkgMode = 'all' }
$pkgId = "$($action.payload.packageId)"

$baseArgs = @('--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
if ($pkgMode -eq 'all') {
    $wgArgs = @('upgrade', '--all') + $baseArgs
    $scopeTxt = 'all packages'
}
else {
    $wgArgs = @('upgrade', '--id', $pkgId) + $baseArgs
    $scopeTxt = "package $pkgId"
}
$commandText = 'winget ' + ($wgArgs -join ' ')

$sw = [System.Diagnostics.Stopwatch]::StartNew()

switch ($Mode) {
    'dryrun' {
        $note = "Upgrades $scopeTxt. Requires elevation: yes (plan marks winget upgrades as admin so the whole batch gets one UAC prompt). Packages that need a reboot are flagged in the result."
        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                -Status 'dryrun' -Precheck 'skipped' -Command $commandText -Output $note -Verify 'skipped' `
                -UndoHint 'Package upgrades are not automatically reversible; reinstall the previous version manually if needed.' `
                -DurationMs $sw.ElapsedMilliseconds)
    }

    'apply' {
        if (-not (Test-IsAdmin)) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                    -Status 'denied' -Precheck 'fail' -Command $commandText `
                    -Output 'Requires an elevated session (machine-scope packages need admin; the plan batches all winget upgrades under one UAC prompt).' `
                    -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $run = Invoke-WingetCli -WingetArgs $wgArgs

        if (-not $run.Available) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                    -Status 'failed' -Precheck 'fail' -Command $commandText -Output 'winget not available.' -ExitCode -1 `
                    -DurationMs $sw.ElapsedMilliseconds)
            return
        }
        if ($run.TimedOut) {
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                    -Status 'failed' -Precheck 'pass' -Command $commandText -Output 'winget timed out.' -ExitCode -1 `
                    -DurationMs $sw.ElapsedMilliseconds)
            return
        }

        $tail = $run.Output
        if ($tail.Length -gt 4000) { $tail = '...' + $tail.Substring($tail.Length - 4000) }

        $denied = ($run.Output -match '(?i)accesso negato|access is denied|access denied')
        $needsElevation = ($run.Output -match '(?i)elevat|amministratore|administrator')
        $rebootHint = ($run.Output -match '(?i)riavvio|restart|reboot')

        $notes = @()
        if ($rebootHint) { $notes += 'A reboot may be required to complete the upgrade.' }

        if ($run.ExitCode -eq 0) {
            $status = 'done'
            $precheck = 'pass'
            if ($notes.Count -eq 0) { $notes += "winget finished successfully ($scopeTxt)." }
        }
        elseif ($denied -or $needsElevation) {
            $status = 'denied'
            $precheck = 'pass'
            $notes += 'Access was denied: re-run the batch from an elevated session.'
        }
        else {
            $status = 'failed'
            $precheck = 'pass'
            $notes += "winget exit code: $($run.ExitCode)"
        }

        # --- targeted verification ---
        $verify = 'skipped'
        if ($status -eq 'done') {
            if ($pkgMode -eq 'one') {
                $installed = Get-InstalledVersion -PackageId $pkgId
                $expected = "$($action.payload.to)"
                if ($installed -and $expected -and $installed -eq $expected) { $verify = 'pass'; $notes += "Verified: installed version is now $installed." }
                elseif ($installed) { $verify = 'unknown'; $notes += "Installed version reads: $installed (expected $expected)." }
                else { $verify = 'unknown'; $notes += 'Could not read the installed version after the upgrade.' }
            }
            else {
                $before = 0
                if ($action.payload.count) { $before = [int]$action.payload.count }
                $after = Get-UpgradeRowCount
                if ($null -eq $after) { $verify = 'unknown' }
                elseif ($after -eq 0 -or ($before -gt 0 -and $after -lt $before)) { $verify = 'pass'; $notes += "Upgrades still listed: $after (was $before)." }
                else { $verify = 'unknown'; $notes += "Upgrades still listed: $after (was $before): some packages may need attention." }
            }
        }

        Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                -Status $status -Precheck $precheck -Command $commandText -ExitCode $run.ExitCode `
                -Output (($notes + $tail) -join "`n") -Verify $verify `
                -UndoHint 'Package upgrades are not automatically reversible; reinstall the previous version manually if needed.' `
                -DurationMs $sw.ElapsedMilliseconds)
    }

    'verify' {
        if ($pkgMode -eq 'one') {
            $installed = Get-InstalledVersion -PackageId $pkgId
            $out = if ($installed) { "Installed version of $pkgId : $installed" } else { "Could not read the installed version of $pkgId." }
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                    -Status 'done' -Output $out -Verify $(if ($installed) { 'pass' } else { 'unknown' }) -DurationMs $sw.ElapsedMilliseconds)
        }
        else {
            $count = Get-UpgradeRowCount
            $out = if ($null -eq $count) { 'Could not query winget upgrades.' } else { "Upgrades still listed: $count" }
            Write-ActionResult -OutFile $OutFile -Result (New-ActionResult -Id $id -Kind 'winget-upgrade' -Title $title `
                    -Status 'done' -Output $out -Verify $(if ($count -eq 0) { 'pass' } else { 'unknown' }) -DurationMs $sw.ElapsedMilliseconds)
        }
    }
}
