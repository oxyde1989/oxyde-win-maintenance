<#
.SYNOPSIS
    oxyde-win-maintenance - build an action plan from a scan report.

.DESCRIPTION
    Reads out\scan_latest.json, maps findings that carry an actionKind to
    action handlers found in actions\, and writes out\plan_<ts>.json
    (+ out\plan_latest.json). The restore point safety step is always
    included as default-selected.

.EXAMPLE
    .\PcPlan.ps1
    .\PcPlan.ps1 -Report out\scan_20261017_125917.json
#>
[CmdletBinding()]
param(
    [string]$Report,
    [string]$OutDir
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'lib\Common.psm1') -Force

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (-not $Report) { $Report = Join-Path $OutDir 'scan_latest.json' }
if (-not (Test-Path -LiteralPath $Report)) {
    Write-Warning "Scan report not found: $Report (run PcScan.ps1 first)."
    exit 1
}

$scan = Get-Content -LiteralPath $Report -Raw -Encoding UTF8 | ConvertFrom-Json

$scanProfile = "$($scan.profile)"
if (-not $scanProfile) { $scanProfile = 'unknown' }
if ($scanProfile -eq 'quick') {
    Write-Warning 'Latest scan used the quick profile: the plan may miss winget/driver actions. Run: .\PcScan.ps1 -Profile standard'
}

# Discover the action catalog (kind -> handler file).
$kindMap = @{}
$actionsDir = Join-Path $PSScriptRoot 'actions'
foreach ($f in @(Get-ChildItem -LiteralPath $actionsDir -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    if ($f.Name -match '^(\d+)-([a-z0-9\-]+)\.ps1$') { $kindMap[$Matches[2].ToLower()] = $f.FullName }
}

$actions = New-Object System.Collections.ArrayList
$unsupported = New-Object System.Collections.ArrayList

# Safety step: always available, default-selected.
[void]$actions.Add([pscustomobject]@{
        id             = 'restorepoint'
        kind           = 'restorepoint'
        title          = 'Create restore point (safety step)'
        risk           = 'low'
        adminRequired  = $true
        defaultSelected = $true
        payload        = @{ description = 'oxyde-win-maintenance: pre-actions checkpoint' }
        sourceFinding  = ''
    })

foreach ($f in @($scan.findings)) {
    $kind = "$($f.actionKind)".ToLower()
    if (-not $kind) { continue }
    if (-not $kindMap.ContainsKey($kind)) {
        [void]$unsupported.Add([pscustomobject]@{ findingId = "$($f.id)"; kind = $kind; title = "$($f.title)" })
        continue
    }
    if ($kind -eq 'restorepoint') { continue }   # already covered by the safety step

    # Dataset-driven expansion: the finding declares that its remediation is
    # generated from a report dataset (one bulk action + one action per item).
    if ("$($f.actionPayload.source)" -eq 'dataset') {
        $dsName = "$($f.actionPayload.dataset)"
        $rows = @()
        if ($dsName -and $scan.datasets) {
            $dsProp = @($scan.datasets.PSObject.Properties | Where-Object { $_.Name -eq $dsName })
            # Double @(): a single-row dataset deserializes to a scalar and
            # loses .Count on PS 5.1 unless re-wrapped as an array.
            if ($dsProp.Count -gt 0 -and $dsProp[0].Value) { $rows = @(@($dsProp[0].Value) | Where-Object { $null -ne $_ }) }
        }

        if ($kind -eq 'winget-upgrade' -and $rows.Count -gt 0) {
            [void]$actions.Add([pscustomobject]@{
                    id              = 'winget-upgrade:all'
                    kind            = $kind
                    title           = ("Upgrade all winget packages ({0})" -f $rows.Count)
                    risk            = 'medium'
                    adminRequired   = $true
                    defaultSelected = $true
                    payload         = @{ mode = 'all'; count = $rows.Count }
                    sourceFinding   = "$($f.id)"
                    timeoutSeconds  = 1800
                })
            foreach ($r in $rows) {
                $pn = "$($r.name)"
                $pkgId = "$($r.id)"
                [void]$actions.Add([pscustomobject]@{
                        id              = ("winget-upgrade:{0}" -f $pkgId)
                        kind            = $kind
                        title           = ("Upgrade {0} {1} -> {2}" -f $pn, "$($r.current)", "$($r.available)")
                        risk            = 'low'
                        adminRequired   = $true
                        defaultSelected = $false
                        payload         = @{ mode = 'one'; packageId = $pkgId; name = $pn; from = "$($r.current)"; to = "$($r.available)" }
                        sourceFinding   = "$($f.id)"
                        timeoutSeconds  = 600
                    })
            }
        }
        continue   # expanded (or nothing to expand); never a 1:1 action
    }

    # service-delete is offered but never preselected (_6 spec: deleting a
    # service is a decision, not a default). shadow-resize and integrity-repair
    # are never preselected either (_8 §2: explicit choices, not defaults).
    $defaultSel = ("$($f.status)" -in @('WARN', 'CRIT'))
    if ($kind -in @('service-delete', 'shadow-resize')) { $defaultSel = $false }

    $riskByKind = @{ 'shadow-resize' = 'low' }
    $risk = if ($riskByKind.ContainsKey($kind)) { $riskByKind[$kind] } else { 'medium' }

    [void]$actions.Add([pscustomobject]@{
            id              = ("{0}:{1}" -f $kind, "$($f.id)")
            kind            = $kind
            title           = "$($f.title)"
            risk            = $risk
            adminRequired   = [bool]$f.adminRequired
            defaultSelected = $defaultSel
            payload         = $f.actionPayload
            sourceFinding   = "$($f.id)"
        })
}

$plan = [pscustomobject]@{
    planVersion    = 1
    generatedAt    = (Get-Date).ToString('s')
    sourceReport   = (Resolve-Path -LiteralPath $Report).Path
    sourceProfile  = $scanProfile
    host           = "$($scan.host.name)"
    options        = [pscustomobject]@{ restorePointFirst = $true }
    actions        = @($actions)
    unsupported    = @($unsupported)
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$planPath = Join-Path $OutDir ("plan_$stamp.json")
Write-JsonFile -InputObject $plan -Path $planPath
Copy-Item -LiteralPath $planPath -Destination (Join-Path $OutDir 'plan_latest.json') -Force

# --- console summary ---
Write-Host ''
Write-Host ("Plan: {0}" -f $planPath)
Write-Host ("Source report: {0}" -f $plan.sourceReport)
Write-Host ("Actions: {0}" -f @($plan.actions).Count)
Write-Host ''
Write-Host ("{0,-58} {1,-16} {2,-7} {3,-6} {4}" -f 'Title', 'Kind', 'Risk', 'Admin', 'Default')
Write-Host ('-' * 100)
foreach ($a in $plan.actions) {
    $title = "$($a.title)"
    if ($title.Length -gt 56) { $title = $title.Substring(0, 53) + '...' }
    Write-Host ("{0,-58} {1,-16} {2,-7} {3,-6} {4}" -f $title, $a.kind, $a.risk, $(if ($a.adminRequired) { 'yes' } else { 'no' }), $(if ($a.defaultSelected) { 'yes' } else { 'no' }))
}
if ($unsupported.Count -gt 0) {
    Write-Host ''
    Write-Warning ("Findings with unsupported action kinds: {0}" -f $unsupported.Count)
    foreach ($u in $unsupported) { Write-Warning ("  {0} -> kind '{1}' (no handler in actions\)" -f $u.findingId, $u.kind) }
}
Write-Host ''
Write-Host 'Next: .\PcApply.ps1            (dry run)'
Write-Host '      .\PcApply.ps1 -Apply      (interactive apply)'
