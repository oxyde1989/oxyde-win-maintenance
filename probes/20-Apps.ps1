# oxyde-win-maintenance probe: application inventory (Uninstall registry) + broken entries.
# "Last used" / "Launches" come from the current user's Explorer launch history (UserAssist).
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

function ConvertFrom-Rot13([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 65 -and $c -le 90) { [void]$sb.Append([char]((($c - 65 + 13) % 26) + 65)) }
        elseif ($c -ge 97 -and $c -le 122) { [void]$sb.Append([char]((($c - 97 + 13) % 26) + 97)) }
        else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}

function Get-NormalizedToken([string]$Text) {
    ($Text -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

# Explorer launch history (UserAssist): Value names are ROT13-encoded; on current
# Windows builds the last-use FILETIME sits at offset 60 of the binary value
# (offset 8 on legacy 16-byte entries). Executables match by file name,
# AppID / shortcut entries by normalized name.
function Get-UserAssistUsage {
    $exeMap = @{}
    $tokens = @()
    $root = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist'
    foreach ($sub in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $k = Get-Item "$($sub.PSPath)\Count" -ErrorAction SilentlyContinue
        if (-not $k) { continue }
        foreach ($n in $k.GetValueNames()) {
            $b = $k.GetValue($n)
            if (-not ($b -is [byte[]]) -or $b.Length -lt 16) { continue }
            $count = [BitConverter]::ToUInt32($b, 4)
            if ($b.Length -ge 68) { $ft = [BitConverter]::ToInt64($b, 60) } else { $ft = [BitConverter]::ToInt64($b, 8) }
            if ($ft -le 0) { continue }
            $last = $null
            try {
                $d = [datetime]::FromFileTime($ft)
                if ($d.Year -ge 1990 -and $d.Year -le 2100) { $last = $d }
            }
            catch { }
            if (-not $last) { continue }

            $name = ConvertFrom-Rot13 $n
            if (-not $name) { continue }
            $leaf = $name
            $i = $leaf.LastIndexOf('\')
            if ($i -ge 0) { $leaf = $leaf.Substring($i + 1) }

            if ($leaf -match '(?i)^(.+)\.exe$') {
                $exeKey = $Matches[1].ToLowerInvariant()
                # Generic file names belong to many products: matching them would cross-attribute usage.
                if ($exeKey -notmatch '^(unins\d+|uninstall|setup|install|installer|update|updater|patch|launcher|client|helper)$') {
                    $cur = $exeMap[$exeKey]
                    if (-not $cur -or $last -gt $cur.last) { $exeMap[$exeKey] = [pscustomobject]@{ last = $last; count = $count } }
                }
            }
            elseif ($leaf -match '(?i)^(.+)\.lnk$') {
                $tok = Get-NormalizedToken $Matches[1]
                if ($tok.Length -ge 4) { $tokens += [pscustomobject]@{ norm = $tok; last = $last; count = $count } }
            }
            elseif ($name -notmatch '^UEME_') {
                $tok = Get-NormalizedToken $name
                if ($tok.Length -ge 4) { $tokens += [pscustomobject]@{ norm = $tok; last = $last; count = $count } }
            }
        }
    }
    @{ exe = $exeMap; tokens = $tokens }
}

# Best usage match for an app: executable name wins over exact normalized name,
# which wins over containment (min 4 chars each side). Ties go to the latest date.
function Find-AppUsage {
    param([string]$DisplayName, [string]$DisplayIcon, $Usage)
    $best = $null
    $bestPr = 0

    $icon = "$DisplayIcon"
    if ($icon -match '(?i)^"?([^",]+\.exe)') {
        $exeKey = [System.IO.Path]::GetFileNameWithoutExtension($Matches[1]).ToLowerInvariant()
        $u = $Usage.exe[$exeKey]
        if ($u) { $best = $u; $bestPr = 4 }
    }

    $appNorm = Get-NormalizedToken $DisplayName
    if ($appNorm.Length -ge 4) {
        foreach ($t in $Usage.tokens) {
            $pr = 0
            if ($t.norm -eq $appNorm) { $pr = 3 }
            elseif ($t.norm.Length -ge 4 -and ($appNorm.Contains($t.norm) -or $t.norm.Contains($appNorm))) { $pr = 2 }
            if ($pr -gt $bestPr -or ($pr -eq $bestPr -and $best -and $t.last -gt $best.last)) {
                $best = $t; $bestPr = $pr
            }
        }
    }
    $best
}

$Area = 'Apps'
$findings = New-Object System.Collections.ArrayList
$usage = Get-UserAssistUsage
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

        $lastUsed = ''
        $launches = ''
        $match = Find-AppUsage -DisplayName "$($p.DisplayName)" -DisplayIcon "$($p.DisplayIcon)" -Usage $usage
        if ($match) {
            $lastUsed = $match.last.ToString('yyyy-MM-dd')
            $launches = $match.count
        }

        $apps += [pscustomobject]@{
            name        = "$($p.DisplayName)"
            version     = "$($p.DisplayVersion)"
            publisher   = "$($p.Publisher)"
            sizeMB      = $sizeMB
            installDate = $installDate
            lastUsed    = $lastUsed
            launches    = $launches
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
$withUsage = @($apps | Where-Object { $_.lastUsed }).Count
$totalSizeTxt = ($totalMB / 1024).ToString('N1', [System.Globalization.CultureInfo]::InvariantCulture)

[void]$findings.Add((New-Finding -Id 'apps-summary' -Area $Area -Title ("Installed applications: {0}" -f $apps.Count) -Status 'INFO' `
            -Evidence @(
                "Estimated total size: $totalSizeTxt GB",
                "MSI (native /qn silent): $msiCount",
                ("Without a known silent uninstall: {0}" -f $noSilent.Count),
                ("With usage history (UserAssist, current user): {0}" -f $withUsage)
            ) `
            -Source 'Registry Uninstall (HKLM/HKLM32/HKCU) + UserAssist'))

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ apps = $apps } -OutFile $OutFile
