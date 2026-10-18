# oxyde-win-maintenance probe: pending Windows updates (Windows Update COM) + last hotfix.
# Quick profile: the COM search is skipped (dominant cost); service state only.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'WindowsUpdate'
$findings = New-Object System.Collections.ArrayList
$rows = @()
$light = ($env:OXYDE_PROFILE -eq 'quick')

if ($light) {
    try {
        $svc = Get-Service -Name wuauserv -ErrorAction Stop
        $startType = ''
        try { $startType = "$($svc.StartType)" } catch { }
        $ev = @("Service: wuauserv ($($svc.DisplayName))")
        if ($startType) { $ev += "Start type: $startType" }
        $st = 'OK'
        if ($startType -eq 'Disabled') {
            $st = 'WARN'
            $ev += 'The service is disabled: updates will not install.'
        }
        elseif ($svc.Status -ne 'Running' -and $startType -eq 'Automatic') {
            $st = 'WARN'
            $ev += 'The service should be running (start type Automatic) but is stopped.'
        }
        elseif ($svc.Status -ne 'Running') {
            # Manual/trigger start: idle when no update activity is normal on Windows 10/11.
            $ev += "The service is idle (start type $startType): normal on-demand behaviour."
        }
        $ev += 'Quick profile: the update search (COM) is skipped; run a standard scan for pending updates'
        [void]$findings.Add((New-Finding -Id 'wu-service' -Area $Area -Title ("Windows Update service: {0}" -f $svc.Status) -Status $st `
                    -Evidence $ev `
                    -SuggestedAction $(if ($st -eq 'WARN') { 'Check the Windows Update service configuration' } else { '' }) `
                    -Source 'Get-Service (SCM)'))
    }
    catch {
        [void]$findings.Add((New-Finding -Id 'wu-service' -Area $Area -Title 'Windows Update service not found' -Status 'WARN' `
                    -Evidence @("$($_.Exception.Message)") -Source 'Get-Service (SCM)'))
    }
    [void]$findings.Add((New-Finding -Id 'wu-summary' -Area $Area -Title 'Pending updates: not checked (quick profile)' -Status 'INFO' `
                -Evidence @('Run a standard profile scan for the Windows Update search', 'Requires network') `
                -Category 'summary' -Source 'oxyde-win-maintenance quick profile'))
}
else {
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
            $ev += 'Requires network'

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
                        -Evidence @("Total: $n", ("Drivers: {0}" -f @($rows | Where-Object { $_.type -eq 'Driver' }).Count), ("Software: {0}" -f @($rows | Where-Object { $_.type -eq 'Software' }).Count), 'Requires network') `
                        -SuggestedAction 'Install all pending updates' -Category 'summary' -Source 'Microsoft.Update.Session (COM)'))
        }
        else {
            [void]$findings.Add((New-Finding -Id 'wu-summary' -Area $Area -Title 'No pending Windows updates' -Status 'OK' `
                        -Evidence @('Requires network') -Category 'summary' -Source 'Microsoft.Update.Session (COM)'))
        }

        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($session) } catch { }
    }
    catch {
        [void]$findings.Add((New-Finding -Id 'wu-error' -Area $Area -Title 'Windows Update search failed' -Status 'CRIT' `
                    -Evidence @("$($_.Exception.Message)", 'Check connectivity and the wuauserv service', 'Requires network') `
                    -SuggestedAction 'Re-run the probe or check Windows Update manually' `
                    -Source 'Microsoft.Update.Session (COM)'))
    }
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

# --- update health (standard/deep only; folded in per roadmap _3 Batch 2) ---
# Service states + WU client event history (id 19 success, 20 install failure,
# 31 download failure) + SoftwareDistribution size. The failure signal WARNs
# only when failures accumulate AND updates have not succeeded recently, so it
# cannot double-count the stalled-updates story with wu-last-hotfix.
if (-not $light) {
    $healthRows = @()
    $lastSuccessAt = $null
    $lastSuccessTitle = ''
    $failCount = 0
    $lastFailCode = ''
    $lastFailAt = $null

    try {
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($svc) { $healthRows += [pscustomobject]@{ item = 'wuauserv'; value = "$($svc.Status)/$($svc.StartType)"; note = '' } }
        $bits = Get-Service -Name BITS -ErrorAction SilentlyContinue
        if ($bits) { $healthRows += [pscustomobject]@{ item = 'BITS'; value = "$($bits.Status)/$($bits.StartType)"; note = $(if ($bits.Status -ne 'Running') { 'normal when idle: starts on demand' } else { '' }) } }
    }
    catch { }

    try {
        $wuEvents = @(Get-WinEvent -FilterHashtable @{ ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 400 -ErrorAction Stop)
        $succ = @($wuEvents | Where-Object { $_.Id -eq 19 } | Sort-Object TimeCreated -Descending)
        if ($succ.Count -gt 0) {
            $lastSuccessAt = $succ[0].TimeCreated
            $msg = "$($succ[0].Message)"
            $lastSuccessTitle = (($msg -split ':')[-1]).Trim()
            if ($lastSuccessTitle.Length -gt 120) { $lastSuccessTitle = $lastSuccessTitle.Substring(0, 120) + ' ...' }
        }
        $fails = @($wuEvents | Where-Object { $_.Id -in @(20, 31) } | Sort-Object TimeCreated -Descending)
        $failCount = $fails.Count
        if ($failCount -gt 0) {
            $lastFailAt = $fails[0].TimeCreated
            $m = [regex]::Match("$($fails[0].Message)", '0x[0-9a-fA-F]{8}')
            if ($m.Success) { $lastFailCode = $m.Value }
        }
    }
    catch { }

    try {
        $sd = Get-DirSizeCapped -Root (Join-Path $env:SystemRoot 'SoftwareDistribution') -FileCap 20000 -MsBudget 1500
        if ($sd) {
            $sdMB = [math]::Round($sd.bytes / 1MB, 1)
            $note = ''
            if ($sd.capped) { $note = "capped at $($sd.files) files / $($sd.ms) ms (actual size is larger)" }
            $healthRows += [pscustomobject]@{ item = 'SoftwareDistribution'; value = ((Format-Num $sdMB) + ' MB'); note = $note }
            if ($sdMB -ge 10240) {
                [void]$findings.Add((New-Finding -Id 'wu-sd-size' -Area $Area -Title ("Windows Update cache is large: {0} GB" -f (Format-Num ([math]::Round($sdMB / 1024, 1)))) -Status 'WARN' `
                            -Evidence @("Path: $(Join-Path $env:SystemRoot 'SoftwareDistribution')", ("Size: {0} MB" -f (Format-Num $sdMB)), 'A large cache often means stalled or repeatedly failing updates.') `
                            -SuggestedAction 'Review Windows Update health before clearing the cache' -Source 'Capped directory walk'))
            }
        }
    }
    catch { }

    if ($lastSuccessAt) { $healthRows += [pscustomobject]@{ item = 'Last successful install'; value = $lastSuccessAt.ToString('yyyy-MM-dd HH:mm'); note = $lastSuccessTitle } }
    if ($failCount -gt 0) {
        $healthRows += [pscustomobject]@{ item = 'Failed attempts (30 days)'; value = "$failCount"; note = ("last: {0}{1}" -f $lastFailAt.ToString('yyyy-MM-dd HH:mm'), $(if ($lastFailCode) { " ($lastFailCode)" } else { '' })) }
    }

    $failuresRecent = ($failCount -ge 3)
    $staleSuccess = (-not $lastSuccessAt) -or (((Get-Date) - $lastSuccessAt).TotalDays -gt 7)
    if ($failuresRecent -and $staleSuccess) {
        [void]$findings.Add((New-Finding -Id 'wu-health' -Area $Area -Title ("Windows Update: {0} failure(s) in 30 days, last success {1}" -f $failCount, $(if ($lastSuccessAt) { $lastSuccessAt.ToString('yyyy-MM-dd') } else { 'not found' })) -Status 'WARN' `
                    -Evidence @(($healthRows | Where-Object { $_.item -in @('Failed attempts (30 days)', 'Last successful install') } | ForEach-Object { "{0}: {1} {2}" -f $_.item, $_.value, $_.note })) `
                    -SuggestedAction 'Check Windows Update manually; the update pipeline may be stalled' -Source 'WindowsUpdateClient events (30 days)'))
    }
    else {
        $title = if ($lastSuccessAt) { ("Windows Update health: last success {0}, {1} failure(s) in 30 days" -f $lastSuccessAt.ToString('yyyy-MM-dd'), $failCount) } else { 'Windows Update health: no successful install found in 30 days' }
        [void]$findings.Add((New-Finding -Id 'wu-health' -Area $Area -Title $title -Status 'INFO' `
                    -Evidence @(($healthRows | Where-Object { $_.item -in @('Failed attempts (30 days)', 'Last successful install') } | ForEach-Object { "{0}: {1} {2}" -f $_.item, $_.value, $_.note })) `
                    -Source 'WindowsUpdateClient events (30 days)'))
    }
    $wuHealthRows = @($healthRows)
}
else {
    $wuHealthRows = @()
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ updates = $rows; wuHealth = $wuHealthRows } -OutFile $OutFile
