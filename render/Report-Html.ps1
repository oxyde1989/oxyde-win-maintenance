# oxyde-win-maintenance - HTML renderer (Bootstrap 5 + jQuery + DataTables + Chart.js via CDN).
# Layout: sidebar navigation, dark/light theme, Bootstrap tooltips, KPI cards.

function New-HtmlReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$JsonFileName = ''
    )

    function HtmlE([string]$s) {
        if ($null -eq $s) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$s)
    }

    function JsStr([string]$s) {
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
        apps           = 'Installed applications'
        updates        = 'Pending Windows updates'
        wingetUpgrades = 'Available winget upgrades'
        appxApps       = 'AppX / MSIX packages (user)'
        orphanServices = 'Orphan services'
    }
    $datasetIcons = @{
        apps           = 'bi-app-indicator'
        updates        = 'bi-windows'
        wingetUpgrades = 'bi-box-seam'
        appxApps       = 'bi-grid-3x3-gap'
        orphanServices = 'bi-gear-wide-connected'
    }
    $colLabels = @{
        name = 'Name'; version = 'Version'; publisher = 'Publisher'; sizeMB = 'MB'
        installDate = 'Installed'; msi = 'MSI'; quiet = 'Silent'; scope = 'Scope'
        kb = 'KB'; severity = 'Severity'; mb = 'MB'; reboot = 'Reboot'; type = 'Type'
        id = 'Id'; available = 'Available'; current = 'Current'; source = 'Source'
        title = 'Title'; imagePath = 'ImagePath'; resolved = 'Resolved path'
        start = 'Start'; state = 'State'; display = 'Display name'
    }
    $areaTooltips = @{
        WindowsUpdate  = 'Pending updates reported by the Windows Update service (software and drivers), plus the most recent installed hotfix.'
        Apps           = 'Applications registered in the Uninstall registry keys (machine 64/32-bit and current user). Flags entries with no uninstall command.'
        Winget         = 'Package upgrades available through winget, parsed from the winget upgrade output (winget source only).'
        Appx           = 'Per-user AppX/MSIX packages: Store and modern apps. Framework and resource packages are excluded.'
        OrphanServices = 'Services whose ImagePath points to a file that no longer exists: typical leftovers of removed software.'
    }

    # Order areas by severity (crit, warn, info) descending.
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

    $hot = @($findings | Where-Object { $_.status -eq 'CRIT' -or $_.status -eq 'WARN' })

    # Dataset entries (ordered as in dsMap).
    $datasetEntries = @()
    foreach ($k in $dsMap.Keys) {
        $datasetEntries += [pscustomobject]@{ Name = "$k"; Value = $dsMap[$k] }
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

    # Verdict tone.
    if ($counts.CRIT -gt 0) { $vTone = 'danger'; $vIcon = 'bi-exclamation-octagon' }
    elseif ($counts.WARN -gt 0) { $vTone = 'warning'; $vIcon = 'bi-exclamation-triangle' }
    else { $vTone = 'success'; $vIcon = 'bi-check-circle' }

    $issueTotal = $counts.CRIT + $counts.WARN

    # JS chart arrays.
    $statusJs = '[' + (@($counts.CRIT, $counts.WARN, $counts.INFO, $counts.OK) -join ', ') + ']'
    $areaLabelsJs = '[' + ((@($areaStats | ForEach-Object { JsStr $_.name })) -join ', ') + ']'
    $areaCritJs = '[' + ((@($areaStats | ForEach-Object { $_.crit })) -join ', ') + ']'
    $areaWarnJs = '[' + ((@($areaStats | ForEach-Object { $_.warn })) -join ', ') + ']'
    $areaInfoJs = '[' + ((@($areaStats | ForEach-Object { $_.info })) -join ', ') + ']'
    $areaOkJs = '[' + ((@($areaStats | ForEach-Object { $_.ok })) -join ', ') + ']'

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('<!DOCTYPE html>')
    [void]$sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$sb.AppendLine('<title>oxyde-win-maintenance - PC Maintenance Report</title>')
    [void]$sb.AppendLine(@'
<script>
(function () {
  var t = 'light';
  try {
    t = localStorage.getItem('oxyde-win-maintenance-theme') || ((window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light');
  } catch (e) { }
  document.documentElement.setAttribute('data-bs-theme', t);
})();
</script>
'@)
    [void]$sb.AppendLine('<link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">')
    [void]$sb.AppendLine('<link href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css" rel="stylesheet">')
    [void]$sb.AppendLine('<link href="https://cdn.datatables.net/1.13.8/css/dataTables.bootstrap5.min.css" rel="stylesheet">')
    [void]$sb.AppendLine('<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap" rel="stylesheet">')
    [void]$sb.AppendLine(@'
<style>
:root { --pc-ink:#0f172a; --pc-muted:#64748b; --pc-page:#f4f6fb; --pc-sidebar-bg:#0f172a; --pc-sidebar-ink:#cbd5e1; --pc-thead:#f1f5f9; }
[data-bs-theme="dark"] { --pc-ink:#e2e8f0; --pc-muted:#94a3b8; --pc-page:#0b1220; --pc-sidebar-bg:#0b1220; --pc-sidebar-ink:#94a3b8; --pc-thead:#172036; }
html { scroll-behavior:smooth; }
body { background:var(--pc-page); color:var(--pc-ink); font-family:"Inter","Segoe UI",system-ui,sans-serif; }
.card { border-radius:1rem; }
.pc-layout { display:flex; min-height:100vh; }
.pc-sidebar { width:264px; flex:0 0 264px; position:sticky; top:0; height:100vh; overflow-y:auto; background:var(--pc-sidebar-bg); color:var(--pc-sidebar-ink); padding:1.4rem 1.1rem; display:flex; flex-direction:column; }
.pc-brand { color:#fff; font-weight:800; font-size:1rem; letter-spacing:-.02em; display:flex; align-items:center; gap:.5rem; }
.pc-brand-sub { font-size:.72rem; color:var(--pc-sidebar-ink); font-weight:500; }
.pc-nav-label { font-size:.68rem; text-transform:uppercase; letter-spacing:.09em; color:#64748b; margin:1.1rem 0 .3rem .2rem; }
.pc-nav .nav-link { color:var(--pc-sidebar-ink); border-radius:.65rem; padding:.42rem .65rem; display:flex; align-items:center; gap:.55rem; font-size:.9rem; }
.pc-nav .nav-link:hover { background:rgba(148,163,184,.11); color:#fff; }
.pc-nav .nav-link.active { background:rgba(99,102,241,.28); color:#fff; font-weight:600; }
.nav-count { margin-left:auto; font-size:.7rem; font-weight:700; border-radius:999px; padding:.08rem .5rem; background:rgba(148,163,184,.18); }
.nav-count.tone-danger { background:rgba(239,68,68,.9); color:#fff; }
.nav-count.tone-warning { background:rgba(245,158,11,.95); color:#1f2937; }
.pc-sidebar-footer { margin-top:auto; padding-top:1rem; font-size:.72rem; color:#64748b; }
.pc-main { flex:1 1 auto; min-width:0; padding:1.6rem 2rem 3rem; }
.pc-section { scroll-margin-top:1rem; }
@media (max-width:991.98px) { .pc-layout { flex-direction:column; } .pc-sidebar { position:static; width:100%; flex:auto; height:auto; } .pc-main { padding:1rem 1rem 2.5rem; } }
.hero { background:linear-gradient(135deg,#0f172a 0%,#1e293b 55%,#3730a3 130%); color:#fff; border-radius:1.25rem; padding:1.6rem 1.8rem; }
.hero-title { font-weight:800; letter-spacing:-.03em; margin-bottom:.35rem; }
.hero-sub { color:#cbd5e1; font-size:.85rem; display:flex; flex-wrap:wrap; gap:.35rem 1.1rem; align-items:center; }
.hero-sub i { margin-right:.35rem; opacity:.85; }
.verdict-pill { border-radius:999px; padding:.6rem 1.2rem; font-weight:700; display:inline-flex; align-items:center; gap:.5rem; box-shadow:0 .5rem 1.5rem rgba(0,0,0,.25); }
.kpi { border:0; transition:transform .15s ease, box-shadow .15s ease; }
.kpi:hover { transform:translateY(-2px); box-shadow:0 .6rem 1.2rem rgba(15,23,42,.12)!important; }
.kpi-icon { width:50px; height:50px; border-radius:15px; display:flex; align-items:center; justify-content:center; font-size:1.4rem; flex:0 0 auto; }
.kpi-value { font-size:1.65rem; font-weight:800; line-height:1; letter-spacing:-.02em; }
.kpi-label { font-size:.74rem; text-transform:uppercase; letter-spacing:.05em; color:var(--pc-muted); font-weight:600; }
.section-title { font-weight:800; letter-spacing:-.02em; }
.chart-box { position:relative; height:250px; }
.badge-status { font-size:.72rem; letter-spacing:.3px; }
td.ev { color:var(--pc-muted); font-size:.85rem; }
.pc-thead th { background:var(--pc-thead); color:var(--pc-muted); font-size:.74rem; text-transform:uppercase; letter-spacing:.04em; }
table.pc-findings td { vertical-align:top; }
.pc-search { max-width:230px; }
.stack-list { display:flex; flex-direction:column; gap:.5rem; }
.stack-item { display:flex; align-items:center; gap:.6rem; }
.stack-num { min-width:2.2rem; }
.disk-item { margin-bottom:1rem; }
.progress { background-color:rgba(148,163,184,.25); }
footer { color:var(--pc-muted); font-size:.85rem; }
</style>
'@)

    [void]$sb.AppendLine('</head><body>')
    [void]$sb.AppendLine('<div class="pc-layout">')

    # ===================== sidebar =====================
    [void]$sb.AppendLine('<aside class="pc-sidebar">')
    [void]$sb.AppendLine('<div class="pc-brand"><i class="bi bi-pc-display"></i> oxyde-win-maintenance</div>')
    [void]$sb.AppendLine('<div class="pc-brand-sub">PC Maintenance Report</div>')
    [void]$sb.AppendLine('<div class="btn-group btn-group-sm w-100 mt-3" role="group" aria-label="Theme">')
    [void]$sb.AppendLine('<button type="button" class="btn btn-outline-light" id="themeLight" onclick="pcSetTheme(''light'')"><i class="bi bi-sun"></i> Light</button>')
    [void]$sb.AppendLine('<button type="button" class="btn btn-outline-light" id="themeDark" onclick="pcSetTheme(''dark'')"><i class="bi bi-moon-stars"></i> Dark</button>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<div class="form-check form-switch mt-3 small">')
    [void]$sb.AppendLine('<input class="form-check-input" type="checkbox" role="switch" id="onlyIssues">')
    [void]$sb.AppendLine('<label class="form-check-label" for="onlyIssues" style="color:var(--pc-sidebar-ink)">Show issues only</label>')
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('<nav id="pcSidebarNav" class="nav flex-column pc-nav">')
    [void]$sb.AppendLine('<div class="pc-nav-label">Report</div>')
    [void]$sb.AppendLine('<a class="nav-link" href="#section-overview"><i class="bi bi-speedometer2"></i> Overview</a>')
    [void]$sb.AppendLine('<a class="nav-link" href="#section-system"><i class="bi bi-cpu"></i> System</a>')
    [void]$sb.AppendLine('<div class="pc-nav-label">Findings</div>')
    foreach ($stat in $areaStats) {
        $aid = ($stat.name -replace '[^A-Za-z0-9]', '')
        $issues = $stat.crit + $stat.warn
        $countTxt = if ($issues -gt 0) { $issues } else { ($stat.info + $stat.ok) }
        $tone = ''
        if ($stat.crit -gt 0) { $tone = ' tone-danger' } elseif ($stat.warn -gt 0) { $tone = ' tone-warning' }
        [void]$sb.AppendLine(('<a class="nav-link" href="#section-area-{0}"><i class="bi bi-dot"></i> {1}<span class="nav-count{2}">{3}</span></a>' -f $aid, (HtmlE $stat.name), $tone, $countTxt))
    }
    if ($datasetEntries.Count -gt 0) {
        [void]$sb.AppendLine('<div class="pc-nav-label">Data</div>')
        foreach ($ds in $datasetEntries) {
            $dsId = ($ds.Name -replace '[^A-Za-z0-9]', '')
            $title = $ds.Name
            if ($datasetTitles.ContainsKey($ds.Name)) { $title = $datasetTitles[$ds.Name] }
            $icon = 'bi-table'
            if ($datasetIcons.ContainsKey($ds.Name)) { $icon = $datasetIcons[$ds.Name] }
            [void]$sb.AppendLine(('<a class="nav-link" href="#section-ds-{0}"><i class="bi {1}"></i> {2}</a>' -f $dsId, $icon, (HtmlE $title)))
        }
    }
    [void]$sb.AppendLine('<div class="pc-nav-label">Run</div>')
    [void]$sb.AppendLine('<a class="nav-link" href="#section-probes"><i class="bi bi-terminal"></i> Probe runs</a>')
    [void]$sb.AppendLine('</nav>')
    [void]$sb.AppendLine(('<div class="pc-sidebar-footer">read-only scan &middot; schema v{0}</div>' -f (HtmlE ("$($Report.schemaVersion)"))))
    [void]$sb.AppendLine('</aside>')

    # ===================== main =====================
    [void]$sb.AppendLine('<main class="pc-main">')

    # --- hero ---
    $h = $Report.host
    $elevBadge = if ("$($h.elevated)" -eq 'True') { '<span class="badge bg-success-subtle text-success-emphasis">elevated</span>' } else { '<span class="badge bg-secondary-subtle text-secondary-emphasis">user session</span>' }
    $verdictTxt = if ($issueTotal -gt 0) { "&#9679; $issueTotal issues found" } else { '&#9679; No issues found' }
    [void]$sb.AppendLine('<header class="hero mb-4">')
    [void]$sb.AppendLine('<div class="d-flex flex-wrap align-items-center gap-3">')
    [void]$sb.AppendLine('<div class="flex-grow-1">')
    [void]$sb.AppendLine('<h1 class="hero-title h3">PC Maintenance Report</h1>')
    [void]$sb.AppendLine('<div class="hero-sub">')
    [void]$sb.AppendLine(('<span><i class="bi bi-hdd-network"></i>{0}</span>' -f (HtmlE $h.name)))
    [void]$sb.AppendLine(('<span><i class="bi bi-cpu"></i>{0}</span>' -f (HtmlE ("{0} {1}" -f $h.manufacturer, $h.model).Trim())))
    [void]$sb.AppendLine(('<span><i class="bi bi-windows"></i>{0} &middot; build {1}</span>' -f (HtmlE $h.osCaption), (HtmlE $h.osBuild)))
    [void]$sb.AppendLine(('<span><i class="bi bi-calendar3"></i>{0}</span>' -f (HtmlE $Report.generatedAt)))
    [void]$sb.AppendLine(('<span><i class="bi bi-stopwatch"></i>{0} s</span>' -f (([double]$Report.durationMs / 1000.0).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))))
    [void]$sb.AppendLine(('<span><i class="bi bi-shield-lock"></i>{0}</span>' -f $elevBadge))
    [void]$sb.AppendLine('</div></div>')
    [void]$sb.AppendLine('<div class="text-lg-end">')
    [void]$sb.AppendLine(('<div class="verdict-pill text-bg-{0}"><i class="bi {1}"></i>{2}</div>' -f $vTone, $vIcon, $verdictTxt))
    [void]$sb.AppendLine(('<div class="hero-sub justify-content-lg-end mt-2"><span>{0} critical &middot; {1} warnings &middot; {2} info</span></div>' -f $counts.CRIT, $counts.WARN, $counts.INFO))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div></header>')

    # --- overview: KPI status cards ---
    [void]$sb.AppendLine('<section id="section-overview" class="pc-section">')
    [void]$sb.AppendLine('<div class="row g-3 mb-3">')
    foreach ($c in @(
            @{ k = 'CRIT'; label = 'Critical'; tone = 'danger'; icon = 'bi-exclamation-octagon'; tip = 'Findings that need immediate attention: failed checks (for example a Windows Update search error) or critical system issues.' },
            @{ k = 'WARN'; label = 'Warnings'; tone = 'warning'; icon = 'bi-exclamation-triangle'; tip = 'Findings that recommend an action: pending updates, orphan services, broken uninstall entries, available upgrades.' },
            @{ k = 'INFO'; label = 'Info'; tone = 'info'; icon = 'bi-info-circle'; tip = 'Contextual findings. Useful to know, no action required.' },
            @{ k = 'OK'; label = 'OK'; tone = 'success'; icon = 'bi-check-circle'; tip = 'Checks completed successfully with nothing to report.' }
        )) {
        [void]$sb.AppendLine(('<div class="col-6 col-lg-3"><div class="kpi card shadow-sm h-100" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}"><div class="card-body d-flex align-items-center gap-3">' -f (HtmlE $c.tip)))
        [void]$sb.AppendLine(('<div class="kpi-icon bg-{0}-subtle text-{0}"><i class="bi {1}"></i></div>' -f $c.tone, $c.icon))
        [void]$sb.AppendLine(('<div><div class="kpi-value text-{0}">{1}</div><div class="kpi-label">{2}</div></div>' -f $c.tone, $counts[$c.k], $c.label))
        [void]$sb.AppendLine('</div></div></div>')
    }
    [void]$sb.AppendLine('</div>')

    # --- overview: KPI dataset metric cards ---
    if ($metricCards.Count -gt 0) {
        [void]$sb.AppendLine('<div class="row g-3 mb-4">')
        foreach ($m in $metricCards) {
            [void]$sb.AppendLine(('<div class="col-6 col-lg-3"><div class="kpi card shadow-sm h-100" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}"><div class="card-body d-flex align-items-center gap-3">' -f (HtmlE $m.tip)))
            [void]$sb.AppendLine(('<div class="kpi-icon bg-{0}-subtle text-{0}"><i class="bi {1}"></i></div>' -f $m.tone, $m.icon))
            [void]$sb.AppendLine(('<div><div class="kpi-value text-{0}">{1}</div><div class="kpi-label">{2}</div></div>' -f $m.tone, $m.value, $m.label))
            [void]$sb.AppendLine('</div></div></div>')
        }
        [void]$sb.AppendLine('</div>')
    }

    # --- overview: charts ---
    [void]$sb.AppendLine('<div class="row g-3 mb-4">')
    [void]$sb.AppendLine('<div class="col-lg-4"><div class="card shadow-sm h-100"><div class="card-body">')
    [void]$sb.AppendLine('<h6 class="section-title mb-3">Findings by status <i class="bi bi-info-circle text-secondary" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="Distribution of all findings by status. Hover the slices for exact counts."></i></h6>')
    [void]$sb.AppendLine('<div class="chart-box"><canvas id="chartStatus"></canvas></div>')
    [void]$sb.AppendLine('</div></div></div>')
    [void]$sb.AppendLine('<div class="col-lg-8"><div class="card shadow-sm h-100"><div class="card-body">')
    [void]$sb.AppendLine('<h6 class="section-title mb-3">Findings by area <i class="bi bi-info-circle text-secondary" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="Findings per scan area, stacked by status. Longer bars mean more findings in that area."></i></h6>')
    [void]$sb.AppendLine('<div class="chart-box"><canvas id="chartAreas"></canvas></div>')
    [void]$sb.AppendLine('</div></div></div>')
    [void]$sb.AppendLine('</div>')

    # --- overview: priority actions ---
    [void]$sb.AppendLine(('<div class="card shadow-sm mb-4 border-0 border-start border-4 border-{0}" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="Summary of the most relevant findings. Fix critical issues first, then work through the warnings."><div class="card-body">' -f $vTone))
    [void]$sb.AppendLine(('<h6 class="section-title mb-3"><i class="bi {0} text-{1}"></i> Priority actions</h6>' -f $vIcon, $vTone))
    if ($issueTotal -gt 0) {
        [void]$sb.AppendLine('<div class="stack-list">')
        foreach ($f in @($hot | Select-Object -First 8)) {
            $st = HtmlE $f.status
            $ic = $statusIcons[[string]$f.status]
            [void]$sb.AppendLine(('<div class="stack-item"><span class="badge badge-status rounded-pill text-bg-{0} stack-num"><i class="bi {1}"></i> {0}</span><span>{2}</span></div>' -f $st, $ic, (HtmlE $f.title)))
        }
        [void]$sb.AppendLine('</div>')
    }
    else {
        [void]$sb.AppendLine('<p class="mb-0 text-secondary">No critical issues or warnings found. The machine looks healthy.</p>')
    }
    [void]$sb.AppendLine('</div></div>')
    [void]$sb.AppendLine('</section>')

    # --- system ---
    [void]$sb.AppendLine('<section id="section-system" class="pc-section">')
    [void]$sb.AppendLine('<div class="card shadow-sm mb-4"><div class="card-body">')
    [void]$sb.AppendLine('<h6 class="section-title mb-3"><i class="bi bi-cpu text-secondary"></i> System <i class="bi bi-info-circle text-secondary" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="Hardware and OS inventory captured locally at scan time via CIM/WMI. Disk bars show free space per fixed volume."></i></h6>')

    $diskList = @()
    if ($h.disks) { $diskList = @($h.disks) | Where-Object { $null -ne $_ } }

    [void]$sb.AppendLine('<div class="row row-cols-1 row-cols-md-2 row-cols-xl-4 g-3 small">')
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
    foreach ($item in $specItems) {
        $val = if ($item.v) { HtmlE $item.v } else { $elevBadge }
        [void]$sb.AppendLine(('<div class="col"><div class="text-secondary kpi-label">{0}</div><div class="mt-1">{1}</div></div>' -f (HtmlE $item.l), $val))
    }
    [void]$sb.AppendLine('</div>')

    if ($diskList.Count -gt 0) {
        [void]$sb.AppendLine('<hr class="my-4">')
        [void]$sb.AppendLine('<div class="kpi-label text-secondary mb-3">Disks</div>')
        foreach ($d in $diskList) {
            $drive = HtmlE $d.drive
            $label = HtmlE $d.label
            $labelTxt = if ("$($d.label)" -ne '') { " ($label)" } else { '' }
            if ($null -ne $d.pctFree) {
                $pct = [double]$d.pctFree
                $pctInt = [int][math]::Truncate($pct)
                $tone = 'success'
                if ($pctInt -lt 10) { $tone = 'danger' } elseif ($pctInt -lt 20) { $tone = 'warning' }
                $inv = [System.Globalization.CultureInfo]::InvariantCulture
                $freeTxt = ([double]$d.freeGB).ToString('0.#', $inv)
                $sizeTxt = ([double]$d.sizeGB).ToString('0.#', $inv)
                $tip = "{0} free space: {1} GB of {2} GB ({3}%). Low free space can affect updates and performance." -f $d.drive, $freeTxt, $sizeTxt, $pctInt
                [void]$sb.AppendLine(('<div class="disk-item" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}">' -f (HtmlE $tip)))
                [void]$sb.AppendLine(('<div class="d-flex justify-content-between small mb-1"><span><i class="bi bi-device-hdd text-secondary"></i> {0}{1}</span><span class="text-secondary">{2} / {3} GB free ({4}%)</span></div>' -f $drive, $labelTxt, $freeTxt, $sizeTxt, $pctInt))
                [void]$sb.AppendLine(('<div class="progress" style="height:8px;" role="progressbar" aria-valuenow="{0}" aria-valuemin="0" aria-valuemax="100"><div class="progress-bar bg-{1}" style="width:{0}%"></div></div>' -f $pctInt, $tone))
                [void]$sb.AppendLine('</div>')
            }
            else {
                [void]$sb.AppendLine(('<div class="disk-item"><div class="d-flex justify-content-between small mb-1"><span><i class="bi bi-device-hdd text-secondary"></i> {0}{1}</span><span class="text-secondary">free space unavailable</span></div></div>' -f $drive, $labelTxt))
            }
        }
    }
    [void]$sb.AppendLine('</div></div>')
    [void]$sb.AppendLine('</section>')

    # --- findings per area ---
    $areaJsIds = @()
    foreach ($stat in $areaStats) {
        $areaName = $stat.name
        $aid = ($areaName -replace '[^A-Za-z0-9]', '')
        $areaJsIds += "'$aid'"
        $probeRun = $Report.probes | Where-Object { $_.area -eq $areaName } | Select-Object -First 1
        $meta = ''
        if ($probeRun) { $meta = ('<span class="text-secondary small ms-2">{0} ms</span>' -f $probeRun.durationMs) }
        $areaTip = "Scan area $areaName."
        if ($areaTooltips.ContainsKey($areaName)) { $areaTip = $areaTooltips[$areaName] }

        [void]$sb.AppendLine(('<section id="section-area-{0}" class="pc-section"><div class="card shadow-sm mb-4 area-card" data-areaid="{0}" data-filter="ALL">' -f $aid))
        [void]$sb.AppendLine('<div class="card-header d-flex flex-wrap align-items-center gap-2" style="border-radius:1rem 1rem 0 0;">')
        [void]$sb.AppendLine(('<h5 class="mb-0 me-1 section-title">{0}</h5>' -f (HtmlE $areaName)))
        [void]$sb.AppendLine(('<i class="bi bi-info-circle text-secondary" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="{0}"></i>' -f (HtmlE $areaTip)))
        if ($stat.crit -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-danger">{0}</span>' -f $stat.crit)) }
        if ($stat.warn -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-warning">{0}</span>' -f $stat.warn)) }
        if ($stat.info -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-info">{0}</span>' -f $stat.info)) }
        if ($stat.ok -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-success">{0}</span>' -f $stat.ok)) }
        [void]$sb.AppendLine($meta)
        [void]$sb.AppendLine('<div class="btn-group btn-group-sm ms-auto" role="group">')
        foreach ($b in @(
                @{ s = 'ALL'; l = 'All' }, @{ s = 'CRIT'; l = 'CRIT' }, @{ s = 'WARN'; l = 'WARN' },
                @{ s = 'INFO'; l = 'INFO' }, @{ s = 'OK'; l = 'OK' }
            )) {
            $activeCls = if ($b.s -eq 'ALL') { ' active' } else { '' }
            [void]$sb.AppendLine(('<button type="button" class="btn btn-outline-secondary btn-filter{0}" onclick="pcFilter(''{1}'',''{2}'',this)">{3}</button>' -f $activeCls, $aid, $b.s, $b.l))
        }
        [void]$sb.AppendLine('</div>')
        [void]$sb.AppendLine('<input type="text" class="form-control form-control-sm pc-search" placeholder="Search findings...">')
        [void]$sb.AppendLine('</div>')

        $areaFindings = @($areaGroups[$areaName])
        if ($areaFindings.Count -eq 0) {
            [void]$sb.AppendLine('<div class="card-body text-secondary small">No findings for this area.</div></div></section>')
            continue
        }

        [void]$sb.AppendLine('<div class="table-responsive"><table class="table table-hover align-middle pc-findings mb-0">')
        [void]$sb.AppendLine('<thead class="pc-thead"><tr><th style="width:100px">Status</th><th style="width:28%">Title</th><th>Evidence</th><th style="width:22%">Suggested action</th><th style="width:14%">Source</th></tr></thead><tbody>')
        foreach ($f in $areaFindings) {
            $evLines = @($f.evidence | ForEach-Object { HtmlE $_ }) -join '<br>'
            $st = HtmlE $f.status
            $ic = $statusIcons[[string]$f.status]
            $adminTag = ''
            if ("$($f.adminRequired)" -eq 'True') { $adminTag = ' <span class="badge text-bg-secondary">admin</span>' }
            [void]$sb.AppendLine(('<tr class="finding" data-status="{0}"><td><span class="badge badge-status rounded-pill text-bg-{0}"><i class="bi {1}"></i> {0}</span></td><td>{2}</td><td class="ev">{3}</td><td>{4}{5}</td><td class="ev">{6}</td></tr>' -f
                    $st, $ic, (HtmlE $f.title), $evLines, (HtmlE $f.suggestedAction), $adminTag, (HtmlE $f.source)))
        }
        [void]$sb.AppendLine('</tbody></table></div>')
        [void]$sb.AppendLine('<div class="pc-empty text-secondary small p-3 d-none">No findings visible with the current filter.</div>')
        [void]$sb.AppendLine('</div></section>')
    }

    # --- datasets ---
    if ($datasetEntries.Count -gt 0) {
        [void]$sb.AppendLine('<section id="section-data" class="pc-section">')
        [void]$sb.AppendLine('<h5 class="section-title mb-3 mt-5"><i class="bi bi-table text-secondary"></i> Data detail</h5>')
        foreach ($ds in $datasetEntries) {
            $rows = @($ds.Value) | Where-Object { $null -ne $_ }
            $title = $ds.Name
            if ($datasetTitles.ContainsKey($ds.Name)) { $title = $datasetTitles[$ds.Name] }
            $icon = 'bi-table'
            if ($datasetIcons.ContainsKey($ds.Name)) { $icon = $datasetIcons[$ds.Name] }
            $tableId = 'ds-' + ($ds.Name -replace '[^A-Za-z0-9]', '')
            $dsId = 'section-ds-' + ($ds.Name -replace '[^A-Za-z0-9]', '')

            [void]$sb.AppendLine(('<div class="card shadow-sm mb-4" id="{0}"><div class="card-header" style="border-radius:1rem 1rem 0 0;">' -f $dsId))
            [void]$sb.AppendLine(('<h5 class="mb-0 section-title"><i class="bi {0} text-secondary"></i> {1} <span class="text-secondary small">({2} rows)</span></h5>' -f $icon, (HtmlE $title), $rows.Count))
            [void]$sb.AppendLine('</div>')
            if ($rows.Count -eq 0) {
                [void]$sb.AppendLine('<div class="card-body text-secondary small">No data.</div></div>')
                continue
            }
            [void]$sb.AppendLine('<div class="table-responsive"><table class="table table-striped table-hover mb-0 pc-dt" id="' + $tableId + '">')
            [void]$sb.AppendLine('<thead class="pc-thead"><tr>')
            $cols = @($rows[0].PSObject.Properties.Name)
            foreach ($c in $cols) {
                $lbl = $c
                if ($colLabels.ContainsKey($c)) { $lbl = $colLabels[$c] }
                [void]$sb.AppendLine(('<th>{0}</th>' -f (HtmlE $lbl)))
            }
            [void]$sb.AppendLine('</tr></thead><tbody>')
            foreach ($row in $rows) {
                [void]$sb.AppendLine('<tr>')
                foreach ($c in $cols) {
                    $v = "$($row.$c)"
                    if ($null -eq $row.$c -or $v -eq '') { $v = '&mdash;' } else { $v = HtmlE $v }
                    [void]$sb.AppendLine(('<td>{0}</td>' -f $v))
                }
                [void]$sb.AppendLine('</tr>')
            }
            [void]$sb.AppendLine('</tbody></table></div></div>')
        }
        [void]$sb.AppendLine('</section>')
    }

    # --- probe runs ---
    [void]$sb.AppendLine('<section id="section-probes" class="pc-section">')
    [void]$sb.AppendLine('<div class="card shadow-sm mt-4"><div class="card-header" style="border-radius:1rem 1rem 0 0;"><h6 class="mb-0 section-title"><i class="bi bi-terminal text-secondary"></i> Probe runs</h6></div>')
    [void]$sb.AppendLine('<div class="table-responsive"><table class="table table-sm mb-0"><thead class="pc-thead"><tr><th>Area</th><th>File</th><th>Status</th><th>Duration</th><th>Error</th></tr></thead><tbody>')
    foreach ($p in @($Report.probes)) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3} ms</td><td class="ev">{4}</td></tr>' -f
                (HtmlE $p.area), (HtmlE $p.file), (HtmlE $p.status), (HtmlE ("$($p.durationMs)")), (HtmlE $p.error)))
    }
    [void]$sb.AppendLine('</tbody></table></div></div>')
    [void]$sb.AppendLine(('<p class="mt-2">Report: {0} &middot; schema v{1} &middot; read-only scan, no changes to the system.</p>' -f
            (HtmlE $JsonFileName), (HtmlE ("$($Report.schemaVersion)"))))
    [void]$sb.AppendLine('</section>')

    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('</div>')

    # --- scripts ---
    [void]$sb.AppendLine('<script src="https://code.jquery.com/jquery-3.7.1.min.js"></script>')
    [void]$sb.AppendLine('<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>')
    [void]$sb.AppendLine('<script src="https://cdn.datatables.net/1.13.8/js/jquery.dataTables.min.js"></script>')
    [void]$sb.AppendLine('<script src="https://cdn.datatables.net/1.13.8/js/dataTables.bootstrap5.min.js"></script>')
    [void]$sb.AppendLine('<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>')

    $jsBlock = @'
<script>
var PC_AREAS = [__PC_AREAS__];
var PC_STATUS = __PC_STATUS__;
var PC_AREA_LABELS = __PC_AREA_LABELS__;
var PC_AREA_CRIT = __PC_AREA_CRIT__;
var PC_AREA_WARN = __PC_AREA_WARN__;
var PC_AREA_INFO = __PC_AREA_INFO__;
var PC_AREA_OK = __PC_AREA_OK__;
var PC_COLORS = { crit: '#ef4444', warn: '#f59e0b', info: '#3b82f6', ok: '#10b981' };
var pcCharts = {};

function pcApply($card) {
  var status = $card.attr('data-filter') || 'ALL';
  var q = ($card.find('.pc-search').val() || '').toLowerCase();
  $card.find('tr.finding').each(function () {
    var st = $(this).attr('data-status');
    var okS = (status === 'ALL') || (status === 'ISSUES' ? (st === 'CRIT' || st === 'WARN') : st === status);
    var okQ = !q || $(this).text().toLowerCase().indexOf(q) >= 0;
    $(this).toggle(okS && okQ);
  });
  var visible = $card.find('tr.finding:visible').length;
  $card.find('.pc-empty').toggle(visible === 0);
}

function pcFilter(areaId, status, btn) {
  var $card = $('#area-' + areaId);
  $card.attr('data-filter', status);
  if (btn) { $card.find('.btn-filter').removeClass('active'); $(btn).addClass('active'); }
  pcApply($card);
}

function pcThemeChartColors(theme) {
  var tick = (theme === 'dark') ? '#94a3b8' : '#64748b';
  Object.keys(pcCharts).forEach(function (k) {
    var ch = pcCharts[k];
    if (!ch) { return; }
    if (ch.options.scales) {
      if (ch.options.scales.x && ch.options.scales.x.ticks) { ch.options.scales.x.ticks.color = tick; }
      if (ch.options.scales.y && ch.options.scales.y.ticks) { ch.options.scales.y.ticks.color = tick; }
    }
    if (ch.options.plugins && ch.options.plugins.legend && ch.options.plugins.legend.labels) {
      ch.options.plugins.legend.labels.color = tick;
    }
    ch.update();
  });
}

function pcSetTheme(theme) {
  document.documentElement.setAttribute('data-bs-theme', theme);
  try { localStorage.setItem('oxyde-win-maintenance-theme', theme); } catch (e) { }
  $('#themeLight').toggleClass('active', theme === 'light');
  $('#themeDark').toggleClass('active', theme === 'dark');
  pcThemeChartColors(theme);
}

function pcSpy() {
  var pos = $(window).scrollTop() + 140;
  var current = '';
  $('.pc-section').each(function () {
    if ($(this).offset().top <= pos) { current = $(this).attr('id'); }
  });
  $('#pcSidebarNav .nav-link').removeClass('active');
  if (current) { $('#pcSidebarNav .nav-link[href="#' + current + '"]').addClass('active'); }
}

$(function () {
  $('.pc-search').on('input', function () { pcApply($(this).closest('.area-card')); });

  $('#onlyIssues').on('change', function () {
    var on = $(this).is(':checked');
    var target = on ? 'ISSUES' : 'ALL';
    $.each(PC_AREAS, function (i, aid) {
      var $card = $('#area-' + aid);
      $card.attr('data-filter', target);
      $card.find('.btn-filter').removeClass('active');
      if (!on) { $card.find('.btn-filter').first().addClass('active'); }
      pcApply($card);
    });
  });

  $('table.pc-dt').each(function () {
    $(this).DataTable({
      pageLength: 15,
      lengthMenu: [[15, 30, 60, -1], [15, 30, 60, 'All']],
      order: []
    });
  });

  document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(function (el) {
    new bootstrap.Tooltip(el, { container: 'body' });
  });

  Chart.defaults.font.family = 'Inter, "Segoe UI", system-ui, sans-serif';

  var elStatus = document.getElementById('chartStatus');
  if (elStatus) {
    pcCharts.status = new Chart(elStatus, {
      type: 'doughnut',
      data: {
        labels: ['Critical', 'Warnings', 'Info', 'OK'],
        datasets: [{
          data: PC_STATUS,
          backgroundColor: [PC_COLORS.crit, PC_COLORS.warn, PC_COLORS.info, PC_COLORS.ok],
          borderWidth: 0,
          hoverOffset: 6
        }]
      },
      options: {
        maintainAspectRatio: false,
        cutout: '68%',
        plugins: { legend: { position: 'bottom', labels: { boxWidth: 10, usePointStyle: true } } }
      }
    });
  }

  var elAreas = document.getElementById('chartAreas');
  if (elAreas) {
    pcCharts.areas = new Chart(elAreas, {
      type: 'bar',
      data: {
        labels: PC_AREA_LABELS,
        datasets: [
          { label: 'Critical', data: PC_AREA_CRIT, backgroundColor: PC_COLORS.crit, borderRadius: 4, stack: 's' },
          { label: 'Warnings', data: PC_AREA_WARN, backgroundColor: PC_COLORS.warn, borderRadius: 4, stack: 's' },
          { label: 'Info', data: PC_AREA_INFO, backgroundColor: PC_COLORS.info, borderRadius: 4, stack: 's' },
          { label: 'OK', data: PC_AREA_OK, backgroundColor: PC_COLORS.ok, borderRadius: 4, stack: 's' }
        ]
      },
      options: {
        indexAxis: 'y',
        maintainAspectRatio: false,
        scales: {
          x: { stacked: true, grid: { display: false }, ticks: { precision: 0 } },
          y: { stacked: true, grid: { display: false } }
        },
        plugins: { legend: { position: 'bottom', labels: { boxWidth: 10, usePointStyle: true } } }
      }
    });
  }

  var theme = document.documentElement.getAttribute('data-bs-theme') || 'light';
  $('#themeLight').toggleClass('active', theme === 'light');
  $('#themeDark').toggleClass('active', theme === 'dark');
  pcThemeChartColors(theme);

  $(window).on('scroll', pcSpy);
  pcSpy();
});
</script>
'@

    $jsBlock = $jsBlock -replace '__PC_AREAS__', ($areaJsIds -join ', ')
    $jsBlock = $jsBlock -replace '__PC_STATUS__', $statusJs
    $jsBlock = $jsBlock -replace '__PC_AREA_LABELS__', $areaLabelsJs
    $jsBlock = $jsBlock -replace '__PC_AREA_CRIT__', $areaCritJs
    $jsBlock = $jsBlock -replace '__PC_AREA_WARN__', $areaWarnJs
    $jsBlock = $jsBlock -replace '__PC_AREA_INFO__', $areaInfoJs
    $jsBlock = $jsBlock -replace '__PC_AREA_OK__', $areaOkJs
    [void]$sb.AppendLine($jsBlock)

    [void]$sb.AppendLine('</body></html>')

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $sb.ToString(), $enc)

    return $OutFile
}
