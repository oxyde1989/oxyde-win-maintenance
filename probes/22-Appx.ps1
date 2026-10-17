# oxyde-win-maintenance probe: AppX/MSIX packages (Store apps, Copilot, new Teams, etc.).
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Appx'
$findings = New-Object System.Collections.ArrayList
$rows = @()

$pkgs = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        -not $_.IsFramework -and -not $_.IsResourcePackage
    })

foreach ($p in $pkgs) {
    $pub = "$($p.PublisherDisplayName)"
    $rows += [pscustomobject]@{
        name      = "$($p.Name)"
        version   = "$($p.Version)"
        publisher = $pub
    }
}

$rows = @($rows | Sort-Object name -Unique)

$thirdParty = @($rows | Where-Object { $_.publisher -and $_.publisher -notlike '*Microsoft*' -and $_.publisher -notlike '*Windows*' })
[void]$findings.Add((New-Finding -Id 'appx-summary' -Area $Area -Title ("Installed AppX/MSIX packages (user): {0}" -f $rows.Count) -Status 'INFO' `
            -Evidence @(("Third-party (non-Microsoft publisher): {0}" -f $thirdParty.Count)) `
            -Source 'Get-AppxPackage (current user)'))

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ appxApps = $rows } -OutFile $OutFile
