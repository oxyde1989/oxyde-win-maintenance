# oxyde-win-maintenance probe: services whose ImagePath points to a missing file (orphans).
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'OrphanServices'
$findings = New-Object System.Collections.ArrayList
$rows = @()
$root = 'HKLM:\SYSTEM\CurrentControlSet\Services'

$svcKeys = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
$total = $svcKeys.Count
$unreadable = 0
$checked = 0
$orphans = 0

foreach ($svc in $svcKeys) {
    try {
        $props = Get-ItemProperty -LiteralPath $svc.PSPath -ErrorAction Stop
    }
    catch {
        $unreadable++
        continue
    }

    $name = $svc.PSChildName
    $imagePath = "$($props.ImagePath)"
    if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }

    $resolved = Expand-ImagePath -ImagePath $imagePath
    if (-not $resolved) { continue }

    $checked++
    if (Test-Path -LiteralPath $resolved -PathType Leaf) { continue }

    $orphans++
    $startType = switch ("$($props.Start)") {
        '0' { 'Boot' } '1' { 'System' } '2' { 'Automatic' }
        '3' { 'Manual' } '4' { 'Disabled' } default { "N/A ($($props.Start))" }
    }
    $state = 'N/A'
    $svcObj = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($svcObj) { $state = "$($svcObj.Status)" }

    $ev = @("ImagePath: $imagePath", "Resolved path missing: $resolved", "Start: $startType", "State: $state")
    if ($props.DisplayName) { $ev += "Name: $($props.DisplayName)" }

    [void]$findings.Add((New-Finding -Id ("svc-" + $name.ToLower()) -Area $Area `
                -Title ("Orphan service: {0}" -f $name) -Status 'WARN' `
                -Evidence $ev -SuggestedAction ("sc.exe delete `"{0}`" (requires admin)" -f $name) `
                -Source $root))

    $rows += [pscustomobject]@{
        name      = $name
        display   = "$($props.DisplayName)"
        imagePath = $imagePath
        resolved  = $resolved
        start     = $startType
        state     = $state
    }
}

if ($orphans -gt 0) {
    [void]$findings.Add((New-Finding -Id 'svc-summary' -Area $Area -Title ("Orphan services found: {0}" -f $orphans) -Status 'WARN' `
                -Evidence @("Services scanned: $total", "ImagePaths checked: $checked", "Orphans: $orphans") `
                -SuggestedAction 'Remove orphan services from the registry' -Source $root))
}
else {
    [void]$findings.Add((New-Finding -Id 'svc-summary' -Area $Area -Title 'No orphan services found' -Status 'OK' `
                -Evidence @("Services scanned: $total", "ImagePaths checked: $checked") -Source $root))
}

if ($unreadable -gt 0) {
    [void]$findings.Add((New-Finding -Id 'svc-unreadable' -Area $Area -Title ("Unreadable service keys: {0}" -f $unreadable) -Status 'INFO' `
                -Evidence @('Some HKLM\SYSTEM\CurrentControlSet\Services keys are not readable without elevation') `
                -SuggestedAction 'Re-run the probe elevated for full coverage' -AdminRequired $true -Source $root))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ orphanServices = $rows } -OutFile $OutFile
