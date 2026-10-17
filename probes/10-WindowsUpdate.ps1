# oxyde-win-maintenance probe: pending Windows updates (Windows Update COM) + last hotfix.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'WindowsUpdate'
$findings = New-Object System.Collections.ArrayList
$rows = @()

try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
    $n = [int]$result.Updates.Count

    for ($i = 0; $i -lt $n; $i++) {
        $u = $result.Updates.Item($i)
        $kbList = @($u.KBArticleIDs | ForEach-Object { "KB$_" })
        $kbTxt = if ($kbList.Count -gt 0) { $kbList -join ', ' } else { '' }
        $sev = "$($u.MsrcSeverity)"
        $isDriver = ($u.Type -eq 2)
        $mb = $null
        if ($u.MaxDownloadSize -gt 0) { $mb = [math]::Round($u.MaxDownloadSize / 1MB, 1) }
        $reboot = switch ([int]$u.InstallationBehavior.RebootBehavior) {
            0 { 'Not required' }
            1 { 'Always required' }
            2 { 'Possible' }
            default { 'N/A' }
        }

        $st = 'INFO'
        if (-not $isDriver -and ($sev -eq 'Critical' -or $sev -eq 'Important')) { $st = 'WARN' }

        $ev = @()
        if ($kbTxt) { $ev += "KB: $kbTxt" }
        if ($sev) { $ev += "MSRC severity: $sev" }
        $ev += "Type: $(if ($isDriver) { 'Driver' } else { 'Software' })"
        if ($mb) { $ev += "Download size: $mb MB" }
        $ev += "Reboot: $reboot"

        [void]$findings.Add((New-Finding -Id ("wu-{0}" -f $i) -Area $Area -Title "$($u.Title)" -Status $st `
                    -Evidence $ev -SuggestedAction 'Install via Windows Update' `
                    -Source 'Microsoft.Update.Session (COM)'))

        $rows += [pscustomobject]@{
            title    = "$($u.Title)"
            kb       = $kbTxt
            severity = $(if ($sev) { $sev } else { '' })
            type     = $(if ($isDriver) { 'Driver' } else { 'Software' })
            mb       = $mb
            reboot   = $reboot
        }
    }

    if ($n -gt 0) {
        [void]$findings.Add((New-Finding -Id 'wu-summary' -Area $Area -Title "Pending Windows updates: $n" -Status 'WARN' `
                    -Evidence @("Total: $n", ("Drivers: {0}" -f @($rows | Where-Object { $_.type -eq 'Driver' }).Count), ("Software: {0}" -f @($rows | Where-Object { $_.type -eq 'Software' }).Count)) `
                    -SuggestedAction 'Install all pending updates' -Source 'Microsoft.Update.Session (COM)'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'wu-summary' -Area $Area -Title 'No pending Windows updates' -Status 'OK' `
                    -Source 'Microsoft.Update.Session (COM)'))
    }

    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) } catch { }
}
catch {
    [void]$findings.Add((New-Finding -Id 'wu-error' -Area $Area -Title 'Windows Update search failed' -Status 'CRIT' `
                -Evidence @("$($_.Exception.Message)", 'Check connectivity and the wuauserv service') `
                -SuggestedAction 'Re-run the probe or check Windows Update manually' `
                -Source 'Microsoft.Update.Session (COM)'))
}

# Last installed hotfix
try {
    $last = Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    if ($last) {
        $days = [int]((Get-Date) - $last.InstalledOn).TotalDays
        $st = 'INFO'
        $action = ''
        if ($days -gt 45) {
            $st = 'WARN'
            $action = 'Verify Windows Update is functioning'
        }
        [void]$findings.Add((New-Finding -Id 'wu-last-hotfix' -Area $Area -Title ("Last hotfix: {0} ({1}, {2} days ago)" -f $last.HotFixID, $last.InstalledOn.ToString('yyyy-MM-dd'), $days) -Status $st `
                    -Evidence @("Description: $($last.Description)", "Installed by: $($last.InstalledBy)") `
                    -SuggestedAction $action -Source 'Win32_QuickFixEngineering (Get-HotFix)'))
    }
}
catch { }

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ updates = $rows } -OutFile $OutFile
