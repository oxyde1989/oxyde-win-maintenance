# oxyde-win-maintenance probe: application inventory (Uninstall registry) + broken entries.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Apps'
$findings = New-Object System.Collections.ArrayList
$apps = @()

$keys = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine64' }
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'Machine32' }
    @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Scope = 'User' }
)

foreach ($k in $keys) {
    $items = Get-ItemProperty -Path $k.Path -ErrorAction SilentlyContinue
    foreach ($p in @($items)) {
        if (-not $p.DisplayName) { continue }
        if ($p.SystemComponent -eq 1) { continue }
        if ($p.ParentKeyName -or $p.ParentDisplayName) { continue }

        $sizeMB = $null
        if ($p.EstimatedSize) { $sizeMB = [math]::Round(($p.EstimatedSize / 1024), 1) }

        $installDate = ''
        if ("$($p.InstallDate)" -match '^(\d{4})(\d{2})(\d{2})$') {
            $installDate = "$($Matches[1])-$($Matches[2])-$($Matches[3])"
        }

        $isMsi = ($p.WindowsInstaller -eq 1)
        $quiet = -not [string]::IsNullOrWhiteSpace($p.QuietUninstallString)
        $uninstall = "$($p.UninstallString)"

        $apps += [pscustomobject]@{
            name        = "$($p.DisplayName)"
            version     = "$($p.DisplayVersion)"
            publisher   = "$($p.Publisher)"
            sizeMB      = $sizeMB
            installDate = $installDate
            msi         = $isMsi
            quiet       = $quiet
            scope       = $k.Scope
        }

        if ([string]::IsNullOrWhiteSpace($uninstall)) {
            [void]$findings.Add((New-Finding -Id ("app-nounin-" + ($p.DisplayName -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area `
                        -Title ("Broken uninstall entry: $($p.DisplayName)") -Status 'WARN' `
                        -Evidence @("Scope: $($k.Scope)", "Version: $($p.DisplayVersion)", "Publisher: $($p.Publisher)", 'No UninstallString in the registry') `
                        -SuggestedAction 'Remove the entry manually or with an uninstall tool' `
                        -Source 'Registry Uninstall (HKLM/HKLM32/HKCU)'))
        }
    }
}

$apps = @($apps | Sort-Object name -Unique)

$totalMB = 0
foreach ($a in $apps) { if ($a.sizeMB) { $totalMB += $a.sizeMB } }
$msiCount = @($apps | Where-Object { $_.msi }).Count
$noSilent = @($apps | Where-Object { -not $_.msi -and -not $_.quiet })
$totalSizeTxt = ($totalMB / 1024).ToString('N1', [System.Globalization.CultureInfo]::InvariantCulture)

[void]$findings.Add((New-Finding -Id 'apps-summary' -Area $Area -Title ("Installed applications: {0}" -f $apps.Count) -Status 'INFO' `
            -Evidence @(
                "Estimated total size: $totalSizeTxt GB",
                "MSI (native /qn silent): $msiCount",
                ("Without a known silent uninstall: {0}" -f $noSilent.Count)
            ) `
            -Source 'Registry Uninstall (HKLM/HKLM32/HKCU)'))

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ apps = $apps } -OutFile $OutFile
