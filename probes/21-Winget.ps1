# oxyde-win-maintenance probe: package upgrades available via winget.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Winget'
$findings = New-Object System.Collections.ArrayList

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    [void]$findings.Add((New-Finding -Id 'winget-missing' -Area $Area -Title 'winget not available' -Status 'INFO' `
                -Evidence @('winget command not found in PATH', 'Requires network') -Source 'winget'))
    Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ wingetUpgrades = @() } -OutFile $OutFile
    return
}

$raw = ''
$exit = -1
try {
    # winget writes UTF-8; without this, accented output can arrive mangled.
    $oldEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $raw = & winget upgrade --source winget --disable-interactivity --accept-source-agreements 2>$null | Out-String
    $exit = $LASTEXITCODE
    try { [Console]::OutputEncoding = $oldEncoding } catch { }
}
catch {
    $raw = ''
}
$raw = $raw -replace "\x1B\[[0-9;?]*[A-Za-z]", ''

# Structure-based verdict (_8 §11): parsing and decision live in the pure
# helper Get-WingetUpgradeVerdict (lib\Common.psm1), fixture-tested in the
# smoke suite. The probe only maps the verdict to findings.
$verdict = Get-WingetUpgradeVerdict -ExitCode $exit -Text $raw

if ("$($verdict.state)" -eq 'updates') {
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title "$($verdict.title)" -Status 'WARN' `
                -Evidence @($verdict.evidence) -SuggestedAction 'Apply updates: winget upgrade --all' -Source 'winget upgrade' `
                -ActionKind 'winget-upgrade' -ActionPayload @{ source = 'dataset'; dataset = 'wingetUpgrades' }))
}
elseif ("$($verdict.state)" -eq 'failed') {
    [void]$findings.Add((New-Finding -Id 'winget-failed' -Area $Area -Title "$($verdict.title)" -Status 'WARN' `
                -Evidence @($verdict.evidence) -SuggestedAction 'Check network connectivity and run manually: winget upgrade' -Source 'winget upgrade'))
}
elseif ("$($verdict.state)" -eq 'none') {
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title "$($verdict.title)" -Status 'OK' `
                -Evidence @($verdict.evidence) -Source 'winget upgrade'))
}
else {
    [void]$findings.Add((New-Finding -Id 'winget-parse' -Area $Area -Title "$($verdict.title)" -Status 'WARN' `
                -Evidence @($verdict.evidence) -SuggestedAction 'Check manually with: winget upgrade' -Source 'winget upgrade'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ wingetUpgrades = @($verdict.rows) } -OutFile $OutFile
