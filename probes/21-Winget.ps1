# oxyde-win-maintenance probe: package upgrades available via winget.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Winget'
$findings = New-Object System.Collections.ArrayList
$rows = @()

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
$lines = @($raw -split "`r?`n")

# Find the separator line (dashes) under the header, then parse data rows.
$sepIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*-{3,}\s*$') { $sepIdx = $i; break }
}

# Column regex must tolerate both layouts:
#  - wide console: 2+ spaces between columns
#  - redirected/narrow output: single spaces (e.g. "Sottosistema Windows per Linux Microsoft.WSL 2.7.3.0  2.7.13")
# The ID column (dotted token) anchors the row; backtracking resolves names
# containing dotted tokens (e.g. "Python 3.12.9" before "Python.Python.3.12").
$rowRegex = '^(?<name>.+?)\s+(?<id>[^\s]*\.[^\s]+)\s+(?<ver>[0-9][^\s]*)\s+(?<avail>[0-9][^\s]*)(?:\s+(?<src>winget|msstore))?\s*$'

$unparsed = @()
if ($sepIdx -ge 0) {
    for ($i = $sepIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($rows.Count -gt 0) { break } else { continue }
        }
        if ($line -match '^\s*-{3,}') { continue }
        # Footer, localized: "N aggiornamenti disponibili." / "N upgrades available."
        if ($line -match '(?i)^\s*\d+\s+(aggiornament|updates?)' -or $line -match '(?i)(updates? available|aggiornamenti disponibili)') { break }
        $m = [regex]::Match($line, $rowRegex)
        if ($m.Success) {
            $rows += [pscustomobject]@{
                name      = $m.Groups['name'].Value.Trim()
                id        = $m.Groups['id'].Value
                current   = $m.Groups['ver'].Value
                available = $m.Groups['avail'].Value
                source    = $m.Groups['src'].Value
            }
        }
        else {
            $unparsed += $line
        }
    }
}

if ($rows.Count -gt 0) {
    $ev = @("Total: $($rows.Count)", 'Requires network')
    if ($unparsed.Count -gt 0) { $ev += "Unparsed lines: $($unparsed.Count)" }
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title ("Updates available via winget: {0}" -f $rows.Count) -Status 'WARN' `
                -Evidence $ev -SuggestedAction 'Apply updates: winget upgrade --all' -Source 'winget upgrade' `
                -ActionKind 'winget-upgrade' -ActionPayload @{ source = 'dataset'; dataset = 'wingetUpgrades' }))
}
elseif ($exit -ne 0) {
    $ev = @("Exit code: $exit", 'Requires network')
    if ($unparsed.Count -gt 0) { $ev += "First lines: " + (($unparsed | Select-Object -First 3) -join ' | ') }
    [void]$findings.Add((New-Finding -Id 'winget-failed' -Area $Area -Title ("winget upgrade failed (exit {0})" -f $exit) -Status 'WARN' `
                -Evidence $ev -SuggestedAction 'Check network connectivity and run manually: winget upgrade' -Source 'winget upgrade'))
}
elseif ($raw -match 'No installed|No applicable|No available|Nessun|non trovato') {
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title 'No winget updates available' -Status 'OK' `
                -Evidence @('Requires network') -Source 'winget upgrade'))
}
else {
    $ev = @("Exit code: $exit", 'Requires network')
    if ($unparsed.Count -gt 0) { $ev += "First lines: " + (($unparsed | Select-Object -First 3) -join ' | ') }
    [void]$findings.Add((New-Finding -Id 'winget-parse' -Area $Area -Title 'Unparseable winget output' -Status 'WARN' `
                -Evidence $ev -SuggestedAction 'Check manually with: winget upgrade' -Source 'winget upgrade'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ wingetUpgrades = $rows } -OutFile $OutFile
