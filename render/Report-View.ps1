# oxyde-win-maintenance - report view model (_9 Part A step 2).
# New-ReportView turns a scan report into a stable intermediate object:
# hero data, KPI cards, per-area groups with their findings, datasets,
# probes and the chart arrays. From here on the HTML section builders read
# only this object - no section touches $Report.findings directly - so a
# missing section is an assertion failure (smoke A24.2), not an empty page.

function New-ReportView {
    param([Parameter(Mandatory)]$Report)

    function View-HtmlE([string]$s) {
        if ($null -eq $s) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$s)
    }

    function View-JsStr([string]$s) {
        return '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"'
    }

    $findings = @($Report.findings)
    $counts = @{ CRIT = 0; WARN = 0; INFO = 0; OK = 0 }
    foreach ($f in $findings) {
        $st = [string]$f.status
        if ($counts.ContainsKey($st)) { $counts[$st]++ }
    }

    $statusIcons = @{
        CRIT = 'bi-exclamation-octagon'
        WARN = 'bi-exclamation-triangle'
        INFO = 'bi-info-circle'
        OK   = 'bi-check-circle'
    }

    # Datasets: normalize to a lookup (hashtable in-memory / PSCustomObject from JSON).
    $dsMap = @{}
    if ($Report.datasets -is [System.Collections.IDictionary]) {
        foreach ($k in $Report.datasets.Keys) { $dsMap["$k"] = $Report.datasets[$k] }
    }
    elseif ($Report.datasets) {
        foreach ($prop in @($Report.datasets.PSObject.Properties)) { $dsMap[$prop.Name] = $prop.Value }
    }

    $datasetTitles = @{
        apps              = 'Installed applications'
        updates           = 'Pending Windows updates'
        wingetUpgrades    = 'Available winget upgrades'
        appxApps          = 'AppX / MSIX packages (user)'
        orphanServices    = 'Orphan services'
        problemDevices    = 'Problem devices (Device Manager style)'
        drivers           = 'Installed drivers (inventory)'
        integritySessions = 'Component store (CBS sessions)'
        integrityArchive  = 'Component store archive (corruption history)'
        shutdownEvents    = 'Unexpected shutdowns and bug checks (90 days)'
        topSystemErrors   = 'Top recurring system errors (30 days)'
        spaceConsumers    = 'Disk space consumers'
        shadowStorage     = 'Shadow storage'
        avProducts        = 'Registered antivirus products'
        firewallProfiles  = 'Firewall profiles'
        platformTrust     = 'Platform trust (TPM, Secure Boot, activation)'
        physicalDisks     = 'Physical disks (health, wear)'
        startupEntries    = 'Startup entries (Run keys, folders, tasks, services)'
        wuHealth          = 'Windows Update health (30 days)'
    }
    $datasetIcons = @{
        apps              = 'bi-app-indicator'
        updates           = 'bi-windows'
        wingetUpgrades    = 'bi-box-seam'
        appxApps          = 'bi-grid-3x3-gap'
        orphanServices    = 'bi-gear-wide-connected'
        problemDevices    = 'bi-exclamation-diamond'
        drivers           = 'bi-hdd-stack'
        integritySessions = 'bi-patch-check'
        integrityArchive  = 'bi-archive'
        shutdownEvents    = 'bi-power'
        topSystemErrors   = 'bi-journal-text'
        spaceConsumers    = 'bi-pie-chart'
        shadowStorage     = 'bi-stack'
        avProducts        = 'bi-shield-check'
        firewallProfiles  = 'bi-fire'
        platformTrust     = 'bi-shield-lock'
        physicalDisks     = 'bi-device-ssd'
        startupEntries    = 'bi-rocket-takeoff'
        wuHealth          = 'bi-heart-pulse'
    }
    $colLabels = @{
        name = 'Name'; version = 'Version'; publisher = 'Publisher'; sizeMB = 'MB'
        installDate = 'Installed'; msi = 'MSI'; quiet = 'Silent'; scope = 'Scope'
        kb = 'KB'; severity = 'Severity'; mb = 'MB'; reboot = 'Reboot'; type = 'Type'
        id = 'Id'; available = 'Available'; current = 'Current'; source = 'Source'
        title = 'Title'; imagePath = 'ImagePath'; resolved = 'Resolved path'
        start = 'Start'; state = 'State'; display = 'Display name'
        lastUsed = 'Last used'; launches = 'Launches'
        device = 'Device'; class = 'Class'; problem = 'Problem'; provider = 'Provider'
        driverVersion = 'Driver version'; driverDate = 'Driver date'; date = 'Date'
        instanceId = 'Instance ID'
        sessions = 'Sessions'; repairNeeded = 'RepairNeeded'; rebootRequired = 'Reboot required'
        payloadCorruption = 'Payload corruption'; markers = 'Markers'; lastMarkerAt = 'Last marker'
        file = 'File'; count = 'Count'; last = 'Last'; sample = 'Sample'
        item = 'Item'; path = 'Path'; note = 'Note'
        product = 'Product'; exe = 'Executable'; enabled = 'Enabled'
        check = 'Check'
        used = 'Used'; maximum = 'Maximum'; allocated = 'Allocated'
        media = 'Type'; bus = 'Bus'; sizeGB = 'Size (GB)'; health = 'Health'
        operational = 'Status'; wear = 'Wear %'; temperature = 'Temp'; powerOnHours = 'Power-on (h)'
        readErrors = 'Read errors'; writeErrors = 'Write errors'; predictFailure = 'Predict failure'
        kind = 'Kind'; command = 'Command'; exists = 'Target exists'
        value = 'Value'
    }
    $areaTooltips = @{
        WindowsUpdate  = 'Pending updates reported by the Windows Update service (software and drivers), plus the most recent installed hotfix. Quick profile: service state only, no COM search.'
        Apps           = 'Applications registered in the Uninstall registry keys (machine 64/32-bit and current user). Flags entries with no uninstall command. Last used / Launches come from the Explorer launch history (UserAssist) of the current user: apps launched by other means may show no data.'
        Winget         = 'Package upgrades available through winget, parsed from the winget upgrade output (winget source only). Requires network.'
        Appx           = 'Per-user AppX/MSIX packages: Store and modern apps. Framework and resource packages are excluded.'
        Drivers        = 'Consultative device-centric view: devices with a real problem (Device Manager style, with the installed driver version) and the installed driver inventory. Driver updates published on Windows Update appear under the WindowsUpdate area.'
        Integrity      = 'Component store health: current CBS servicing sessions (RepairNeeded/reboot flags) and the previous servicing archive (corruption markers, when readable without elevation). Deep scan adds DISM /ScanHealth and sfc /verifyonly elevated.'
        EventLog       = 'Critical System events of the last 90 days: unexpected shutdowns (Kernel-Power 41 / EventLog 6008) and bug checks (BSOD 1001), plus the top recurring system errors of the last 30 days.'
        Space          = 'Disk space: free space per drive, main consumers (temp, WER, Recycle Bin, Windows.old, pagefile, hiberfil) measured with capped walks, and shadow storage (requires elevation: deep scan).'
        Security       = 'Security posture: Microsoft Defender status and signature age, antivirus products registered in Security Center (with residue detection when the executable is missing) and the firewall profiles.'
        OrphanServices = 'Services whose ImagePath points to a file that no longer exists: typical leftovers of removed software.'
        Storage        = 'Storage health of the physical disks: model, media/bus, health and operational status (unelevated signal), plus SMART predict-failure, wear, temperature and error counters when the deep scan runs elevated.'
        Startup        = 'What starts with Windows: Run/RunOnce registry keys, the Startup folders (shortcuts resolved), scheduled tasks and third-party automatic services. Flags entries whose target file no longer exists (typical uninstall residue).'
        System         = 'Engine-level notes about the scan itself (for example a deep profile requested without elevation).'
    }

    # Order areas by severity (crit, warn, info) descending; each area keeps
    # its findings, so the section builder is a pure renderer of this list.
    $areaGroups = @{}
    foreach ($f in $findings) {
        $a = [string]$f.area
        if (-not $areaGroups.ContainsKey($a)) { $areaGroups[$a] = New-Object System.Collections.ArrayList }
        [void]$areaGroups[$a].Add($f)
    }
    foreach ($run in @($Report.probes)) {
        if (-not $areaGroups.ContainsKey([string]$run.area)) { $areaGroups[[string]$run.area] = New-Object System.Collections.ArrayList }
    }
    $areaStats = @()
    foreach ($a in $areaGroups.Keys) {
        $c = @{ CRIT = 0; WARN = 0; INFO = 0; OK = 0 }
        foreach ($f in @($areaGroups[$a])) { if ($c.ContainsKey([string]$f.status)) { $c[[string]$f.status]++ } }
        $areaStats += [pscustomobject]@{
            name  = $a
            crit  = $c.CRIT; warn = $c.WARN; info = $c.INFO; ok = $c.OK
            score = ($c.CRIT * 10000 + $c.WARN * 100 + $c.INFO)
        }
    }
    $areaStats = @($areaStats | Sort-Object -Property @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.name } })

    $areas = @()
    foreach ($stat in $areaStats) {
        $issues = $stat.crit + $stat.warn
        $areas += [pscustomobject]@{
            name     = $stat.name
            aid      = ($stat.name -replace '[^A-Za-z0-9]', '')
            crit     = $stat.crit; warn = $stat.warn; info = $stat.info; ok = $stat.ok
            findings = @($areaGroups[$stat.name])
            navCount = $(if ($issues -gt 0) { $issues } else { ($stat.info + $stat.ok) })
            navTone  = $(if ($stat.crit -gt 0) { ' tone-danger' } elseif ($stat.warn -gt 0) { ' tone-warning' } else { '' })
        }
    }

    $hot = @($findings | Where-Object { $_.status -eq 'CRIT' -or $_.status -eq 'WARN' })

    # Dataset entries with their display identity (ordered as in dsMap).
    $datasets = @()
    foreach ($k in $dsMap.Keys) {
        $title = "$k"
        if ($datasetTitles.ContainsKey("$k")) { $title = $datasetTitles["$k"] }
        $icon = 'bi-table'
        if ($datasetIcons.ContainsKey("$k")) { $icon = $datasetIcons["$k"] }
        $datasets += [pscustomobject]@{ name = "$k"; dsId = ("$k" -replace '[^A-Za-z0-9]', ''); title = $title; icon = $icon; rows = $dsMap[$k] }
    }

    # KPI cards derived from datasets (only when the dataset exists).
    $metricCards = @()
    if ($dsMap.ContainsKey('wingetUpgrades')) {
        $metricCards += @{ label = 'Winget upgrades'; value = @(@($dsMap['wingetUpgrades']) | Where-Object { $null -ne $_ }).Count; icon = 'bi-box-seam'; tone = 'primary'; tip = 'Installed packages with an available upgrade, detected via winget upgrade (winget source). Counts only rows parsed from the winget output.' }
    }
    if ($dsMap.ContainsKey('updates')) {
        $metricCards += @{ label = 'Pending updates'; value = @(@($dsMap['updates']) | Where-Object { $null -ne $_ }).Count; icon = 'bi-windows'; tone = 'info'; tip = 'Windows updates (software and drivers) queued for installation, queried from the Windows Update service.' }
    }
    if ($dsMap.ContainsKey('orphanServices')) {
        $metricCards += @{ label = 'Orphan services'; value = @(@($dsMap['orphanServices']) | Where-Object { $null -ne $_ }).Count; icon = 'bi-gear-wide-connected'; tone = 'warning'; tip = 'Services whose ImagePath points to a file that no longer exists. Typical leftovers of removed software.' }
    }
    if ($dsMap.ContainsKey('apps')) {
        $metricCards += @{ label = 'Installed apps'; value = @(@($dsMap['apps']) | Where-Object { $null -ne $_ }).Count; icon = 'bi-app-indicator'; tone = 'secondary'; tip = 'Applications registered in the Uninstall registry keys (machine 64/32-bit and current user).' }
    }

    # Status KPI cards (counts filled at render time from $view.counts).
    $kpiStatus = @(
        @{ k = 'CRIT'; label = 'Critical'; tone = 'danger'; icon = 'bi-exclamation-octagon'; tip = 'Findings that need immediate attention: failed checks (for example a Windows Update search error) or critical system issues.' },
        @{ k = 'WARN'; label = 'Warnings'; tone = 'warning'; icon = 'bi-exclamation-triangle'; tip = 'Findings that recommend an action: pending updates, orphan services, broken uninstall entries, available upgrades.' },
        @{ k = 'INFO'; label = 'Info'; tone = 'info'; icon = 'bi-info-circle'; tip = 'Contextual findings. Useful to know, no action required.' },
        @{ k = 'OK'; label = 'OK'; tone = 'success'; icon = 'bi-check-circle'; tip = 'Checks completed successfully with nothing to report.' }
    )

    # Verdict tone.
    if ($counts.CRIT -gt 0) { $vTone = 'danger'; $vIcon = 'bi-exclamation-octagon' }
    elseif ($counts.WARN -gt 0) { $vTone = 'warning'; $vIcon = 'bi-exclamation-triangle' }
    else { $vTone = 'success'; $vIcon = 'bi-check-circle' }

    $issueTotal = $counts.CRIT + $counts.WARN

    # Health verdict (schema v5); absent on older reports -> legacy behavior.
    $health = $null
    if ($Report.health) { $health = $Report.health }

    # Hero presentation pieces (computed once, rendered by Write-Hero).
    $h = $Report.host
    $elevBadge = if ("$($h.elevated)" -eq 'True') { '<span class="badge bg-success-subtle text-success-emphasis">elevated</span>' } else { '<span class="badge bg-secondary-subtle text-secondary-emphasis">user session</span>' }
    $verdictTxt = if ($issueTotal -gt 0) { "&#9679; $issueTotal issues found" } else { '&#9679; No issues found' }
    $scoreTip = ''
    if ($health) {
        $vLabel = switch ("$($health.verdict)") { 'OK' { 'HEALTHY' } 'WARNING' { 'ATTENTION NEEDED' } 'CRITICAL' { 'CRITICAL' } default { "$($health.verdict)" } }
        $partialTxt = ''
        if ($health.coverage -and "$($health.coverage.partial)" -eq 'True') { $partialTxt = ' (partial)' }
        $issuesTxt = ''
        if ("$($health.issues)" -ne '') { $issuesTxt = ' &middot; ' + (View-HtmlE ("$($health.issues)")) + ' issues' }
        $verdictTxt = ("&#9679; {0} &middot; score {1}{2}{3}" -f $vLabel, (View-HtmlE ("$($health.score)")), $issuesTxt, $partialTxt)
        # The score is relative to the profile's area set (D19); the issue count is absolute (D22).
        $scoreTip = ("Score: 100 - 25 per critical - 8 per warning, roll-up summaries excluded. It is relative to the '{0}' profile area set: only compare runs with the same profile. The issue count is absolute (scored critical + warnings)." -f "$($health.profile)")
    }
    $covRun = 0; $covTotal = 0; $covTip = ''
    if ($health -and $health.coverage) {
        $covRun = @($health.coverage.areasRun).Count
        $covSkip = @($health.coverage.areasSkipped)
        # Distinguish a real coverage loss from the profile's declared scope (D19).
        $covTip = if ($covSkip.Count -gt 0) {
            if (@($health.coverage.explicitAreas).Count -gt 0) { 'Explicit -Areas narrowing; not run: ' + ($covSkip -join ', ') }
            else { 'Not part of this profile''s area set: ' + ($covSkip -join ', ') }
        }
        else { 'All discovered areas were run.' }
        $covTotal = $covRun + $covSkip.Count
    }

    # JS chart arrays.
    $statusJs = '[' + (@($counts.CRIT, $counts.WARN, $counts.INFO, $counts.OK) -join ', ') + ']'
    $areaLabelsJs = '[' + ((@($areas | ForEach-Object { View-JsStr $_.name })) -join ', ') + ']'
    $areaCritJs = '[' + ((@($areas | ForEach-Object { $_.crit })) -join ', ') + ']'
    $areaWarnJs = '[' + ((@($areas | ForEach-Object { $_.warn })) -join ', ') + ']'
    $areaInfoJs = '[' + ((@($areas | ForEach-Object { $_.info })) -join ', ') + ']'
    $areaOkJs = '[' + ((@($areas | ForEach-Object { $_.ok })) -join ', ') + ']'

    # System inventory for the System section.
    $disks = @()
    if ($h.disks) { $disks = @($h.disks) | Where-Object { $null -ne $_ } }
    $specItems = @(
        @{ l = 'CPU'; v = "$($h.cpuName)" },
        @{ l = 'Cores / Threads'; v = $(if ($h.cpuCores) { "$($h.cpuCores) / $($h.cpuThreads)" } else { '' }) },
        @{ l = 'Memory'; v = $(if ($h.ramGB) { "$($h.ramGB) GB" } else { '' }) },
        @{ l = 'BIOS'; v = ("{0} {1}" -f $h.biosVersion, $h.biosDate).Trim() },
        @{ l = 'OS installed'; v = "$($h.osInstall)" },
        @{ l = 'Last boot'; v = "$($h.lastBoot)" },
        @{ l = 'Uptime'; v = "$($h.uptime)" },
        @{ l = 'PowerShell'; v = "$($h.psVersion)" },
        @{ l = 'Host'; v = "$($h.name)" },
        @{ l = 'Model'; v = ("{0} {1}" -f $h.manufacturer, $h.model).Trim() },
        @{ l = 'User'; v = "$($h.user)" },
        @{ l = 'Session'; v = $null }
    )

    return [pscustomobject]@{
        report       = $Report
        counts       = $counts
        statusIcons  = $statusIcons
        issueTotal   = $issueTotal
        hot          = $hot
        health       = $health
        vTone        = $vTone
        vIcon        = $vIcon
        verdictHtml  = $verdictTxt
        scoreTip     = $scoreTip
        elevBadge    = $elevBadge
        covRun       = $covRun
        covTotal     = $covTotal
        covTip       = $covTip
        areas        = $areas
        datasets     = $datasets
        probes       = @($Report.probes)
        colLabels    = $colLabels
        areaTooltips = $areaTooltips
        kpiStatus    = $kpiStatus
        metricCards  = $metricCards
        charts       = @{ status = $statusJs; labels = $areaLabelsJs; crit = $areaCritJs; warn = $areaWarnJs; info = $areaInfoJs; ok = $areaOkJs }
        system       = @{ specItems = $specItems; disks = $disks }
    }
}
