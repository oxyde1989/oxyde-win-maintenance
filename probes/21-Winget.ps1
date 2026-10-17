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
                -Evidence @('winget command not found in PATH') -Source 'winget'))
    Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ wingetUpgrades = @() } -OutFile $OutFile
    return
}

$raw = ''
try {
    $raw = & winget upgrade --source winget --disable-interactivity --accept-source-agreements 2>$null | Out-String
}
catch {
    $raw = ''
}
$exit = $LASTEXITCODE
$raw = $raw -replace "\x1B\[[0-9;]*[A-Za-z]", ''
$lines = @($raw -split "`r?`n")

# Find the separator line (dashes) under the header, then parse data rows.
$sepIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^-{3,}') { $sepIdx = $i; break }
}

$unparsed = @()
if ($sepIdx -ge 0) {
    for ($i = $sepIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($rows.Count -gt 0) { break } else { continue }
        }
        if ($line -match '^\s*-{3,}') { continue }
        $m = [regex]::Match($line, '^(?<name>.+?)\s{2,}(?<id>\S+)\s{2,}(?<ver>\S+)\s{2,}(?<avail>\S+)(\s{2,}(?<src>\S+))?\s*$')
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
    $ev = @("Total: $($rows.Count)")
    if ($unparsed.Count -gt 0) { $ev += "Unparsed lines: $($unparsed.Count)" }
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title ("Updates available via winget: {0}" -f $rows.Count) -Status 'WARN' `
                -Evidence $ev -SuggestedAction 'Apply updates: winget upgrade --all' -Source 'winget upgrade'))
}
elseif ($raw -match 'No installed|No applicable|No available|Nessun|non trovato') {
    [void]$findings.Add((New-Finding -Id 'winget-summary' -Area $Area -Title 'No winget updates available' -Status 'OK' -Source 'winget upgrade'))
}
else {
    $ev = @("Exit code: $exit")
    if ($unparsed.Count -gt 0) { $ev += "First lines: " + (($unparsed | Select-Object -First 3) -join ' | ') }
    [void]$findings.Add((New-Finding -Id 'winget-parse' -Area $Area -Title 'Unparseable winget output' -Status 'INFO' `
                -Evidence $ev -SuggestedAction 'Check manually with: winget upgrade' -Source 'winget upgrade'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ wingetUpgrades = $rows } -OutFile $OutFile
