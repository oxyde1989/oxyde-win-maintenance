<#
.SYNOPSIS
    oxyde-win-maintenance - regression smoke tests (zero dependencies).

.DESCRIPTION
    Runs a battery of assertions against the real engine. Unelevated, no
    network, no winget requirement. Every run writes into fresh directories
    (never the real out\) which are removed afterwards.

    Exit code 0 = all assertions passed; 1 = at least one failed. Probe
    timeouts are reported as warnings, not failures. Failed assertions are
    listed at the end with expected vs actual.

    MAINTENANCE RULE (_7 §1): every defect found by a verification note gets a
    new assertion here in the same cycle, with a comment naming the note.

.EXAMPLE
    .\tools\Test-Smoke.ps1
    .\tools\Test-Smoke.ps1 -KeepTemp
#>
[CmdletBinding()]
param(
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$psExe = Join-Path $PSHOME 'powershell.exe'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$script:passed = 0
$script:failed = New-Object System.Collections.ArrayList
$script:warnings = New-Object System.Collections.ArrayList

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Expected = '', [string]$Actual = '')
    if ($Condition) {
        $script:passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
    }
    else {
        [void]$script:failed.Add([pscustomobject]@{ name = $Name; expected = $Expected; actual = $Actual })
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
    }
}

function Invoke-Engine {
    param([string[]]$Arguments)
    $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'PcScan.ps1') @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Invoke-Plan {
    param([string[]]$Arguments)
    $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'PcPlan.ps1') @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
}

function Get-ScoredCounts {
    param($Findings)
    $scored = @($Findings | Where-Object { "$($_.category)" -ne 'summary' })
    return [pscustomobject]@{
        crit = @($scored | Where-Object { "$($_.status)" -eq 'CRIT' }).Count
        warn = @($scored | Where-Object { "$($_.status)" -eq 'WARN' }).Count
    }
}

function Get-InventoryHash {
    param([string]$Dir)
    return @(Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" })
}

$tmp = Join-Path $env:TEMP ("oxyde_smoke_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$tmp = (Resolve-Path -LiteralPath $tmp).Path

# The HTML renderer computes a RELATIVE asset path, which is impossible across
# volumes: to positively test the vendored-asset reference (A9b) the render
# must happen on the same drive as the repository. Same drive -> inside $tmp;
# different drive -> a fresh, self-removed directory at the repo root.
$repoDrive = [System.IO.Path]::GetPathRoot($root)
$tmpDrive = [System.IO.Path]::GetPathRoot($tmp)
$vendorDir = if ($repoDrive -eq $tmpDrive) { Join-Path $tmp 'vendor_render' } else { Join-Path $root ('.smoke_' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
New-Item -ItemType Directory -Path $vendorDir -Force | Out-Null
$vendorDir = (Resolve-Path -LiteralPath $vendorDir).Path

Write-Host ("oxyde-win-maintenance smoke tests")
Write-Host ("  repo: {0}" -f $root)
Write-Host ("  temp: {0}" -f $tmp)

try {
    # ---- A1: version / schema (drift would be invisible otherwise) ----
    Write-Host ''
    Write-Host 'A1 - version'
    $v = Invoke-Engine -Arguments @('-Version')
    Test-Assert 'A1.1 -Version exits 0' ($v.ExitCode -eq 0) 'exit 0' "exit $($v.ExitCode)"
    Test-Assert 'A1.2 version prints name + semver + schema v5' ($v.Output -match 'oxyde-win-maintenance \d+\.\d+\.\d+ \(schema v5\)') 'oxyde-win-maintenance <semver> (schema v5)' ($v.Output.Trim())

    # ---- R2: nominal quick scan with HTML (A2-A7, A9a, A10, A12) ----
    Write-Host ''
    Write-Host 'R2 - quick scan with HTML'
    $scan1Dir = Join-Path $tmp 'scan1'
    $r2 = Invoke-Engine -Arguments @('-Profile', 'quick', '-OutDir', $scan1Dir)
    $j1 = Get-Content -LiteralPath (Join-Path $scan1Dir 'scan_latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    # A2 (_7 §1): exit code is the automation contract
    $expectedExit = switch ("$($j1.health.verdict)") { 'OK' { 0 } 'WARNING' { 1 } 'CRITICAL' { 2 } default { -1 } }
    Test-Assert 'A2 exit code matches verdict' ($r2.ExitCode -eq $expectedExit) "exit $expectedExit ($($j1.health.verdict))" "exit $($r2.ExitCode)"

    # A3 (_7 §1): additive health fields must not silently disappear
    Test-Assert 'A3.1 schemaVersion = 5' ("$($j1.schemaVersion)" -eq '5') '5' "$($j1.schemaVersion)"
    $healthProps = @('score', 'verdict', 'issues', 'counts', 'topIssues', 'profile', 'adminUsed', 'coverage')
    $missingProps = @($healthProps | Where-Object { -not $j1.health.PSObject.Properties[$_] })
    Test-Assert 'A3.2 health fields complete' ($missingProps.Count -eq 0) ($healthProps -join ',') ((@($j1.health.PSObject.Properties.Name)) -join ',')
    $countProps = @('crit', 'warn', 'info', 'ok')
    $missingCounts = @($countProps | Where-Object { -not $j1.health.counts.PSObject.Properties[$_] })
    Test-Assert 'A3.3 health.counts complete' ($missingCounts.Count -eq 0) ($countProps -join ',') ((@($j1.health.counts.PSObject.Properties.Name)) -join ',')

    # A4 (_2 R2): no double counting - summaries excluded from the score
    $sc = Get-ScoredCounts $j1.findings
    $expectedScore = [math]::Max(0, 100 - (25 * $sc.crit) - (8 * $sc.warn))
    Test-Assert 'A4 score = clamp(100-25c-8w) over non-summary findings' ($j1.health.score -eq $expectedScore) "$expectedScore" "$($j1.health.score)"

    # A5 (_5 C5): absolute issue count
    Test-Assert 'A5 issues = scored crit + warn' ($j1.health.issues -eq ($sc.crit + $sc.warn)) "$($sc.crit + $sc.warn)" "$($j1.health.issues)"

    # A6 (_2 R2): summaries never leak into topIssues
    $summaryIds = @($j1.findings | Where-Object { "$($_.category)" -eq 'summary' } | ForEach-Object { "$($_.id)" })
    $topIds = @($j1.health.topIssues | ForEach-Object { "$($_.id)" })
    $leak = @($topIds | Where-Object { $summaryIds -contains $_ })
    Test-Assert 'A6 no summary finding in topIssues' ($leak.Count -eq 0) 'no summary ids' ($leak -join ',')

    # A7 (_3 N1 / D19): a nominal quick run is not labelled partial
    Test-Assert 'A7 nominal quick has partial = false' ("$($j1.health.coverage.partial)" -eq 'False') 'False' "$($j1.health.coverage.partial)"

    # A9a (D16): the report never references external CDNs
    $html1 = Get-Content -LiteralPath (Join-Path $scan1Dir 'scan_latest.html') -Raw -Encoding UTF8
    $cdnHits = ([regex]::Matches($html1, 'https://cdn')).Count + ([regex]::Matches($html1, 'code\.jquery')).Count + ([regex]::Matches($html1, 'fonts\.googleapis')).Count
    Test-Assert 'A9a report contains 0 external CDN references' ($cdnHits -eq 0) '0' "$cdnHits"

    # A9b (D16): a render on the repo drive references the vendored assets
    . (Join-Path $root 'render\Report-Html.ps1')
    $vendorReport = Join-Path $vendorDir 'report.html'
    $null = New-HtmlReport -Report $j1 -OutFile $vendorReport -JsonFileName 'fixture.json'
    $htmlV = Get-Content -LiteralPath $vendorReport -Raw -Encoding UTF8
    $vendorRefs = ([regex]::Matches($htmlV, 'assets/vendor')).Count
    Test-Assert 'A9b repo-drive render references assets/vendor (>= 1)' ($vendorRefs -ge 1) '>= 1' "$vendorRefs"

    # A10 (_7 §1): every discovered probe is accounted for; crashes fail, slowness warns
    $discovered = @(Get-ChildItem -LiteralPath (Join-Path $root 'probes') -Filter '*.ps1' | ForEach-Object { if ($_.Name -match '^\d+-([A-Za-z0-9]+)\.ps1$') { $Matches[1] } })
    $accounted = @($j1.health.coverage.areasRun) + @($j1.health.coverage.areasSkipped)
    $notAccounted = @($discovered | Where-Object { $accounted -notcontains $_ })
    Test-Assert 'A10.1 every discovered probe accounted for' ($notAccounted.Count -eq 0) 'none missing' ($notAccounted -join ',')
    $errorRuns = @($j1.probes | Where-Object { "$($_.status)" -eq 'error' })
    Test-Assert 'A10.2 no probe ended in error' ($errorRuns.Count -eq 0) '0 errors' (($errorRuns | ForEach-Object { "$($_.area): $($_.error)" }) -join ' | ')
    foreach ($t in @($j1.probes | Where-Object { "$($_.status)" -eq 'timeout' })) {
        [void]$script:warnings.Add(("probe timeout: {0} after {1}s" -f $t.area, $t.timeoutSeconds))
    }

    # ---- R3: explicit -Areas narrowing (A8, the other direction of D19) ----
    Write-Host ''
    Write-Host 'R3 - explicit -Areas narrowing'
    $scan2Dir = Join-Path $tmp 'scan2'
    $r3 = Invoke-Engine -Arguments @('-Profile', 'quick', '-Areas', 'Integrity,EventLog', '-NoHtml', '-OutDir', $scan2Dir)
    $scan2File = Get-ChildItem -LiteralPath $scan2Dir -Filter 'scan_*.json' | Where-Object { $_.Name -ne 'scan_latest.json' } | Sort-Object Name | Select-Object -Last 1
    $j2 = Get-Content -LiteralPath $scan2File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Test-Assert 'A8.1 narrowed run has partial = true' ("$($j2.health.coverage.partial)" -eq 'True') 'True' "$($j2.health.coverage.partial)"
    Test-Assert 'A8.2 narrowed run records explicitAreas' ((@($j2.health.coverage.explicitAreas).Count) -eq 2) '2' (@($j2.health.coverage.explicitAreas).Count)
    Test-Assert 'A8.3 partial scan does not update scan_latest.json' (-not (Test-Path -LiteralPath (Join-Path $scan2Dir 'scan_latest.json'))) 'no scan_latest.json' 'scan_latest.json present'

    # ---- R4: finding ids stable between two consecutive quick runs (A14) ----
    Write-Host ''
    Write-Host 'R4 - id stability'
    $scan3Dir = Join-Path $tmp 'scan3'
    $null = Invoke-Engine -Arguments @('-Profile', 'quick', '-NoHtml', '-OutDir', $scan3Dir)
    $j3 = Get-Content -LiteralPath (Join-Path $scan3Dir 'scan_latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids1 = @($j1.findings | ForEach-Object { "$($_.id)" } | Sort-Object)
    $ids3 = @($j3.findings | ForEach-Object { "$($_.id)" } | Sort-Object)
    Test-Assert 'A14 finding ids stable across consecutive quick runs' (($ids1 -join ',') -eq ($ids3 -join ',')) ($ids1 -join ',') ($ids3 -join ',')

    # ---- C1: cleanup preview is non-destructive (A11, D20) ----
    Write-Host ''
    Write-Host 'C1 - cleanup preview'
    $cln = Join-Path $tmp 'cln'
    New-Item -ItemType Directory -Path $cln -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cln 'scan_20260101_000000.json') -Value 'x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cln 'plan_20260101_000000.json') -Value 'x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cln 'scan_latest.json') -Value 'x' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $cln 'apply_20260101_000000.log') -Value 'x' -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $cln 'undo') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $cln 'undo\svc_x.reg') -Value 'x' -Encoding UTF8
    $before = Get-InventoryHash -Dir $cln
    Import-Module (Join-Path $root 'lib\Common.psm1') -Force
    $prev = Clear-OxydeOutput -OutDir $cln
    $after = Get-InventoryHash -Dir $cln
    Test-Assert 'A11.1 preview detects only the allowlist files' ((@($prev.items).Count) -eq 2) '2' (@($prev.items).Count)
    Test-Assert 'A11.2 preview leaves the SHA-256 inventory unchanged' (($before -join "`n") -eq ($after -join "`n")) 'identical inventory' "$(@($after).Count) files, hash mismatch"

    # ---- P: plan assertions (A12 real scan; A13 fixture, no network needed) ----
    Write-Host ''
    Write-Host 'P - plan'
    $plan1Dir = Join-Path $tmp 'plan1'
    $p1 = Invoke-Plan -Arguments @('-Report', (Join-Path $scan1Dir 'scan_latest.json'), '-OutDir', $plan1Dir)
    Test-Assert 'A12.1 PcPlan exits 0' ($p1.ExitCode -eq 0) 'exit 0' "exit $($p1.ExitCode)"
    $plan1 = Get-Content -LiteralPath (Join-Path $plan1Dir 'plan_latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $safety = @($plan1.actions | Where-Object { "$($_.kind)" -eq 'restorepoint' })
    Test-Assert 'A12.2 plan always contains the restorepoint safety action' ($safety.Count -eq 1) '1 restorepoint action' "$($safety.Count)"

    # A13 (_2: PS 5.1 scalar-Count bug): 1-row dataset must still yield the per-package action
    $fixture = [pscustomobject]@{
        schemaVersion = 5
        generatedAt   = (Get-Date).ToString('s')
        profile       = 'standard'
        health        = [pscustomobject]@{ score = 92; verdict = 'WARNING'; issues = 1; counts = [pscustomobject]@{ crit = 0; warn = 1; info = 0; ok = 0 }; topIssues = @(); profile = 'standard'; adminUsed = $false; coverage = [pscustomobject]@{ areasRun = @(); areasSkipped = @(); profileScope = @(); explicitAreas = @(); failedProbes = @(); networkDependent = @(); elevated = $false; deepWithoutElevation = $false; partial = $false } }
        host          = [pscustomobject]@{ name = 'fixture' }
        probes        = @()
        findings      = @(
            [pscustomobject]@{ id = 'winget-summary'; area = 'Winget'; title = 'Updates available via winget: 1'; status = 'WARN'; evidence = @('Total: 1'); suggestedAction = 'Apply updates: winget upgrade --all'; adminRequired = $false; source = 'winget upgrade'; category = ''; actionKind = 'winget-upgrade'; actionPayload = [pscustomobject]@{ source = 'dataset'; dataset = 'wingetUpgrades' } }
        )
        datasets      = [pscustomobject]@{ wingetUpgrades = @([pscustomobject]@{ name = 'Test Pkg'; id = 'Test.Pkg'; current = '1.0.0'; available = '2.0.0' }) }
    }
    $fixturePath = Join-Path $tmp 'fixture_winget_1row.json'
    [System.IO.File]::WriteAllText($fixturePath, ($fixture | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    $plan2Dir = Join-Path $tmp 'plan2'
    $p2 = Invoke-Plan -Arguments @('-Report', $fixturePath, '-OutDir', $plan2Dir)
    $plan2 = Get-Content -LiteralPath (Join-Path $plan2Dir 'plan_latest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $oneMode = @($plan2.actions | Where-Object { "$($_.kind)" -eq 'winget-upgrade' -and "$($_.payload.mode)" -eq 'one' })
    Test-Assert 'A13 1-row winget dataset still yields the per-package action' ($oneMode.Count -eq 1) '1 one-mode action' "$($oneMode.Count)"
}
finally {
    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $vendorDir -Recurse -Force -ErrorAction SilentlyContinue
        # the repo-root vendor dir must never outlive the run, even on failure
        if ($vendorDir.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $vendorDir)) {
            Remove-Item -LiteralPath $vendorDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Write-Host ("temp kept: {0}" -f $tmp)
        Write-Host ("vendor render kept: {0}" -f $vendorDir)
    }
    $sw.Stop()
    Write-Host ''
    Write-Host ("Smoke: {0} passed, {1} failed, {2} warning(s)  ({3} s)" -f $script:passed, $script:failed.Count, $script:warnings.Count, [int]$sw.Elapsed.TotalSeconds)
    foreach ($w in $script:warnings) { Write-Host ("  WARN  {0}" -f $w) -ForegroundColor Yellow }
    if ($script:failed.Count -gt 0) {
        Write-Host 'Failed assertions:'
        foreach ($f in $script:failed) {
            Write-Host ("  {0}" -f $f.name) -ForegroundColor Red
            Write-Host ("    expected: {0}" -f $f.expected)
            Write-Host ("    actual:   {0}" -f $f.actual)
        }
        exit 1
    }
    exit 0
}
