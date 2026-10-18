# oxyde-win-maintenance - report section builders (_9 Part A step 2).
# Each writer takes one context object: @{ sb; view; hasAssets; assetBase;
# reportCss; jsBlock }. The orchestrator (Report-Html.ps1) builds the view,
# loads the asset blocks and calls the writers in order; no writer touches
# $Report.findings directly (it reads the view model only).

function Section-HtmlE([string]$s) {
    if ($null -eq $s) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$s)
}

function Write-Head {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb
    $v = $ctx.view

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
    if ($ctx.hasAssets) {
        [void]$sb.AppendLine(('<link href="{0}/bootstrap/bootstrap.min.css" rel="stylesheet">' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<link href="{0}/bootstrap-icons/bootstrap-icons.min.css" rel="stylesheet">' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<link href="{0}/datatables/dataTables.bootstrap5.min.css" rel="stylesheet">' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<link href="{0}/inter/inter.css" rel="stylesheet">' -f $ctx.assetBase))
    }
    else {
        [void]$sb.AppendLine('<!-- offline mode: vendored assets not found, minimal inline style -->')
    }
    # _9 Part A: the stylesheet comes from assets\report\report.css (read and
    # embedded); a built-in minimal style keeps the report usable if missing.
    if ($ctx.reportCss) {
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine($ctx.reportCss)
        [void]$sb.AppendLine('</style>')
    }
    else {
        [void]$sb.AppendLine('<style>')
        [void]$sb.AppendLine('body{font-family:"Segoe UI",system-ui,sans-serif}.card{border:1px solid rgba(148,163,184,.3);border-radius:1rem;padding:1rem;margin-bottom:1.25rem}.hero{background:#0f172a;color:#fff;border-radius:1rem;padding:1.4rem}.table{border-collapse:collapse;width:100%}.table td,.table th{padding:.35rem .5rem;border-bottom:1px solid rgba(148,163,184,.35);text-align:left}.verdict-pill{display:inline-block;border-radius:999px;padding:.5rem 1rem;font-weight:700;background:#475569;color:#fff}')
        [void]$sb.AppendLine('</style>')
    }

    if (-not $ctx.hasAssets) {
        [void]$sb.AppendLine(@'
<style>
/* minimal offline fallback: no external assets available */
body { font-family:"Segoe UI",system-ui,sans-serif; }
.card { border:1px solid rgba(148,163,184,.3); border-radius:1rem; padding:1rem; margin-bottom:1.25rem; }
.hero { background:#0f172a; color:#fff; border-radius:1rem; padding:1.4rem; }
.hero a, .hero-sub { color:#cbd5e1; }
.table { border-collapse:collapse; width:100%; }
.table td, .table th { padding:.35rem .5rem; border-bottom:1px solid rgba(148,163,184,.35); text-align:left; vertical-align:top; }
.badge { border:1px solid rgba(148,163,184,.5); border-radius:.5rem; padding:.05rem .4rem; font-size:.78rem; }
.verdict-pill { display:inline-block; border-radius:999px; padding:.5rem 1rem; font-weight:700; background:#475569; color:#fff; }
.progress { background:rgba(148,163,184,.25); height:1rem; border-radius:.5rem; overflow:hidden; }
.progress-bar { background:#6366f1; height:100%; }
nav.nav { display:flex; flex-direction:column; gap:.15rem; }
.nav-link { text-decoration:none; color:inherit; padding:.25rem .5rem; border-radius:.5rem; display:block; }
.chart-box { display:none; }
.stack-list { display:flex; flex-direction:column; gap:.4rem; }
</style>
'@)
    }

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
    foreach ($area in $v.areas) {
        [void]$sb.AppendLine(('<a class="nav-link" href="#section-area-{0}"><i class="bi bi-dot"></i> {1}<span class="nav-count{2}">{3}</span></a>' -f $area.aid, (Section-HtmlE $area.name), $area.navTone, $area.navCount))
    }
    if ($v.datasets.Count -gt 0) {
        [void]$sb.AppendLine('<div class="pc-nav-label">Data</div>')
        foreach ($ds in $v.datasets) {
            [void]$sb.AppendLine(('<a class="nav-link" href="#section-ds-{0}"><i class="bi {1}"></i> {2}</a>' -f $ds.dsId, $ds.icon, (Section-HtmlE $ds.title)))
        }
    }
    [void]$sb.AppendLine('<div class="pc-nav-label">Run</div>')
    [void]$sb.AppendLine('<a class="nav-link" href="#section-probes"><i class="bi bi-terminal"></i> Probe runs</a>')
    [void]$sb.AppendLine('</nav>')
    [void]$sb.AppendLine(('<div class="pc-sidebar-footer">read-only scan &middot; schema v{0}</div>' -f (Section-HtmlE ("$($v.report.schemaVersion)"))))
    [void]$sb.AppendLine('</aside>')

    # ===================== main =====================
    [void]$sb.AppendLine('<main class="pc-main">')
}

function Write-Hero {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb
    $v = $ctx.view
    $h = $v.report.host

    [void]$sb.AppendLine('<header class="hero mb-4">')
    [void]$sb.AppendLine('<div class="d-flex flex-wrap align-items-center gap-3">')
    [void]$sb.AppendLine('<div class="flex-grow-1">')
    [void]$sb.AppendLine('<h1 class="hero-title h3">PC Maintenance Report</h1>')
    [void]$sb.AppendLine('<div class="hero-sub">')
    [void]$sb.AppendLine(('<span><i class="bi bi-hdd-network"></i>{0}</span>' -f (Section-HtmlE $h.name)))
    [void]$sb.AppendLine(('<span><i class="bi bi-cpu"></i>{0}</span>' -f (Section-HtmlE ("{0} {1}" -f $h.manufacturer, $h.model).Trim())))
    [void]$sb.AppendLine(('<span><i class="bi bi-windows"></i>{0} &middot; build {1}</span>' -f (Section-HtmlE $h.osCaption), (Section-HtmlE $h.osBuild)))
    [void]$sb.AppendLine(('<span><i class="bi bi-calendar3"></i>{0}</span>' -f (Section-HtmlE $v.report.generatedAt)))
    [void]$sb.AppendLine(('<span><i class="bi bi-stopwatch"></i>{0} s</span>' -f (([double]$v.report.durationMs / 1000.0).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))))
    if ($v.health) {
        [void]$sb.AppendLine(('<span><i class="bi bi-sliders"></i>profile: {0}</span>' -f (Section-HtmlE ("$($v.health.profile)"))))
        if ($v.health.coverage) {
            [void]$sb.AppendLine(('<span title="{0}"><i class="bi bi-clipboard-check"></i>coverage: {1}/{2} areas</span>' -f (Section-HtmlE $v.covTip), $v.covRun, $v.covTotal))
        }
    }
    [void]$sb.AppendLine(('<span><i class="bi bi-shield-lock"></i>{0}</span>' -f $v.elevBadge))
    [void]$sb.AppendLine('</div></div>')
    [void]$sb.AppendLine('<div class="text-lg-end">')
    [void]$sb.AppendLine(('<div class="verdict-pill text-bg-{0}" title="{3}"><i class="bi {1}"></i>{2}</div>' -f $v.vTone, $v.vIcon, $v.verdictHtml, (Section-HtmlE "$($v.scoreTip)")))
    [void]$sb.AppendLine(('<div class="hero-sub justify-content-lg-end mt-2"><span>{0} critical &middot; {1} warnings &middot; {2} info</span></div>' -f $v.counts.CRIT, $v.counts.WARN, $v.counts.INFO))
    [void]$sb.AppendLine('</div>')
    [void]$sb.AppendLine('</div></header>')

    # --- top issues (score drivers), from the health block ---
    if ($v.health -and @($v.health.topIssues).Count -gt 0) {
        [void]$sb.AppendLine('<div class="card shadow-sm border-0 mb-4"><div class="card-body py-3">')
        [void]$sb.AppendLine('<div class="d-flex align-items-center gap-2 mb-2"><i class="bi bi-flag"></i><span class="fw-bold">Top issues</span><span class="text-secondary small">(drivers of the health score)</span></div>')
        [void]$sb.AppendLine('<div class="stack-list">')
        foreach ($ti in @($v.health.topIssues)) {
            $sIcon = 'bi-info-circle'
            if ($v.statusIcons.ContainsKey("$($ti.status)")) { $sIcon = $v.statusIcons["$($ti.status)"] }
            $sTone = if ("$($ti.status)" -eq 'CRIT') { 'text-danger' } else { 'text-warning' }
            [void]$sb.AppendLine(('<div class="stack-item"><i class="bi {0} {1}"></i><span class="badge bg-secondary-subtle text-secondary-emphasis">{2}</span><span>{3}</span></div>' -f $sIcon, $sTone, (Section-HtmlE ("$($ti.area)")), (Section-HtmlE ("$($ti.title)"))))
        }
        [void]$sb.AppendLine('</div></div></div>')
    }
}

function Write-Overview {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb
    $v = $ctx.view

    # --- overview: KPI status cards ---
    [void]$sb.AppendLine('<section id="section-overview" class="pc-section">')
    [void]$sb.AppendLine('<div class="row g-3 mb-3">')
    foreach ($c in $v.kpiStatus) {
        [void]$sb.AppendLine(('<div class="col-6 col-lg-3"><div class="kpi card shadow-sm h-100" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}"><div class="card-body d-flex align-items-center gap-3">' -f (Section-HtmlE $c.tip)))
        [void]$sb.AppendLine(('<div class="kpi-icon bg-{0}-subtle text-{0}"><i class="bi {1}"></i></div>' -f $c.tone, $c.icon))
        [void]$sb.AppendLine(('<div><div class="kpi-value text-{0}">{1}</div><div class="kpi-label">{2}</div></div>' -f $c.tone, $v.counts[$c.k], $c.label))
        [void]$sb.AppendLine('</div></div></div>')
    }
    [void]$sb.AppendLine('</div>')

    # --- overview: KPI dataset metric cards ---
    if ($v.metricCards.Count -gt 0) {
        [void]$sb.AppendLine('<div class="row g-3 mb-4">')
        foreach ($m in $v.metricCards) {
            [void]$sb.AppendLine(('<div class="col-6 col-lg-3"><div class="kpi card shadow-sm h-100" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}"><div class="card-body d-flex align-items-center gap-3">' -f (Section-HtmlE $m.tip)))
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
    [void]$sb.AppendLine(('<div class="card shadow-sm mb-4 border-0 border-start border-4 border-{0}" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="Summary of the most relevant findings. Fix critical issues first, then work through the warnings."><div class="card-body">' -f $v.vTone))
    [void]$sb.AppendLine(('<h6 class="section-title mb-3"><i class="bi {0} text-{1}"></i> Priority actions</h6>' -f $v.vIcon, $v.vTone))
    if ($v.issueTotal -gt 0) {
        [void]$sb.AppendLine('<div class="stack-list">')
        foreach ($f in @($v.hot | Select-Object -First 8)) {
            $st = Section-HtmlE $f.status
            $ic = $v.statusIcons[[string]$f.status]
            [void]$sb.AppendLine(('<div class="stack-item"><span class="badge badge-status rounded-pill text-bg-{0} stack-num"><i class="bi {1}"></i> {0}</span><span>{2}</span></div>' -f $st, $ic, (Section-HtmlE $f.title)))
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
    [void]$sb.AppendLine('<div class="row row-cols-1 row-cols-md-2 row-cols-xl-4 g-3 small">')
    foreach ($item in $v.system.specItems) {
        $val = if ($item.v) { Section-HtmlE $item.v } else { $v.elevBadge }
        [void]$sb.AppendLine(('<div class="col"><div class="text-secondary kpi-label">{0}</div><div class="mt-1">{1}</div></div>' -f (Section-HtmlE $item.l), $val))
    }
    [void]$sb.AppendLine('</div>')

    if ($v.system.disks.Count -gt 0) {
        [void]$sb.AppendLine('<hr class="my-4">')
        [void]$sb.AppendLine('<div class="kpi-label text-secondary mb-3">Disks</div>')
        foreach ($d in $v.system.disks) {
            $drive = Section-HtmlE $d.drive
            $label = Section-HtmlE $d.label
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
                [void]$sb.AppendLine(('<div class="disk-item" data-bs-toggle="tooltip" data-bs-placement="top" data-bs-title="{0}">' -f (Section-HtmlE $tip)))
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
}

function Write-Area {
    param([Parameter(Mandatory)]$ctx, [Parameter(Mandatory)]$area)
    $sb = $ctx.sb
    $v = $ctx.view

    $areaName = $area.name
    $aid = $area.aid
    $probeRun = @($v.probes | Where-Object { $_.area -eq $areaName }) | Select-Object -First 1
    $meta = ''
    if ($probeRun) { $meta = ('<span class="text-secondary small ms-2">{0} ms</span>' -f $probeRun.durationMs) }
    $areaTip = "Scan area $areaName."
    if ($v.areaTooltips.ContainsKey($areaName)) { $areaTip = $v.areaTooltips[$areaName] }

    # _8 §10: the status-filter script selects the card by id ("area-<Area>");
    # the id is the contract between the renderer and pcFilter()/onlyIssues.
    [void]$sb.AppendLine(('<section id="section-area-{0}" class="pc-section"><div class="card shadow-sm mb-4 area-card" id="area-{0}" data-areaid="{0}" data-filter="ALL">' -f $aid))
    [void]$sb.AppendLine('<div class="card-header d-flex flex-wrap align-items-center gap-2" style="border-radius:1rem 1rem 0 0;">')
    [void]$sb.AppendLine(('<h5 class="mb-0 me-1 section-title">{0}</h5>' -f (Section-HtmlE $areaName)))
    [void]$sb.AppendLine(('<i class="bi bi-info-circle text-secondary" data-bs-toggle="tooltip" data-bs-placement="right" data-bs-title="{0}"></i>' -f (Section-HtmlE $areaTip)))
    if ($area.crit -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-danger">{0}</span>' -f $area.crit)) }
    if ($area.warn -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-warning">{0}</span>' -f $area.warn)) }
    if ($area.info -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-info">{0}</span>' -f $area.info)) }
    if ($area.ok -gt 0) { [void]$sb.AppendLine(('<span class="badge rounded-pill text-bg-success">{0}</span>' -f $area.ok)) }
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

    $areaFindings = @($area.findings)
    if ($areaFindings.Count -eq 0) {
        [void]$sb.AppendLine('<div class="card-body text-secondary small">No findings for this area.</div></div></section>')
        return
    }

    [void]$sb.AppendLine('<div class="table-responsive"><table class="table table-hover align-middle pc-findings mb-0">')
    [void]$sb.AppendLine('<thead class="pc-thead"><tr><th style="width:100px">Status</th><th style="width:28%">Title</th><th>Evidence</th><th style="width:22%">Suggested action</th><th style="width:14%">Source</th></tr></thead><tbody>')
    foreach ($f in $areaFindings) {
        $evLines = @($f.evidence | ForEach-Object { Section-HtmlE $_ }) -join '<br>'
        $st = Section-HtmlE $f.status
        $ic = $v.statusIcons[[string]$f.status]
        $adminTag = ''
        if ("$($f.adminRequired)" -eq 'True') { $adminTag = ' <span class="badge text-bg-secondary">admin</span>' }
        [void]$sb.AppendLine(('<tr class="finding" data-status="{0}"><td><span class="badge badge-status rounded-pill text-bg-{0}"><i class="bi {1}"></i> {0}</span></td><td>{2}</td><td class="ev">{3}</td><td>{4}{5}</td><td class="ev">{6}</td></tr>' -f
                $st, $ic, (Section-HtmlE $f.title), $evLines, (Section-HtmlE $f.suggestedAction), $adminTag, (Section-HtmlE $f.source)))
    }
    [void]$sb.AppendLine('</tbody></table></div>')
    [void]$sb.AppendLine('<div class="pc-empty text-secondary small p-3 d-none">No findings visible with the current filter.</div>')
    [void]$sb.AppendLine('</div></section>')
}

function Write-Areas {
    param([Parameter(Mandatory)]$ctx)
    foreach ($area in $ctx.view.areas) { Write-Area -ctx $ctx -area $area }
}

function Write-Datasets {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb
    $v = $ctx.view

    if ($v.datasets.Count -eq 0) { return }
    [void]$sb.AppendLine('<section id="section-data" class="pc-section">')
    [void]$sb.AppendLine('<h5 class="section-title mb-3 mt-5"><i class="bi bi-table text-secondary"></i> Data detail</h5>')
    foreach ($ds in $v.datasets) {
        $rows = @($ds.rows) | Where-Object { $null -ne $_ }
        $tableId = 'ds-' + $ds.dsId
        $dsId = 'section-ds-' + $ds.dsId

        [void]$sb.AppendLine(('<div class="card shadow-sm mb-4" id="{0}"><div class="card-header" style="border-radius:1rem 1rem 0 0;">' -f $dsId))
        [void]$sb.AppendLine(('<h5 class="mb-0 section-title"><i class="bi {0} text-secondary"></i> {1} <span class="text-secondary small">({2} rows)</span></h5>' -f $ds.icon, (Section-HtmlE $ds.title), $rows.Count))
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
            if ($v.colLabels.ContainsKey($c)) { $lbl = $v.colLabels[$c] }
            [void]$sb.AppendLine(('<th>{0}</th>' -f (Section-HtmlE $lbl)))
        }
        [void]$sb.AppendLine('</tr></thead><tbody>')
        foreach ($row in $rows) {
            [void]$sb.AppendLine('<tr>')
            foreach ($c in $cols) {
                $val = "$($row.$c)"
                if ($null -eq $row.$c -or $val -eq '') { $val = '&mdash;' } else { $val = Section-HtmlE $val }
                [void]$sb.AppendLine(('<td>{0}</td>' -f $val))
            }
            [void]$sb.AppendLine('</tr>')
        }
        [void]$sb.AppendLine('</tbody></table></div></div>')
    }
    [void]$sb.AppendLine('</section>')
}

function Write-Probes {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb
    $v = $ctx.view

    [void]$sb.AppendLine('<section id="section-probes" class="pc-section">')
    [void]$sb.AppendLine('<div class="card shadow-sm mt-4"><div class="card-header" style="border-radius:1rem 1rem 0 0;"><h6 class="mb-0 section-title"><i class="bi bi-terminal text-secondary"></i> Probe runs</h6></div>')
    [void]$sb.AppendLine('<div class="table-responsive"><table class="table table-sm mb-0"><thead class="pc-thead"><tr><th>Area</th><th>File</th><th>Status</th><th>Duration</th><th>Error</th></tr></thead><tbody>')
    foreach ($p in @($v.probes)) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3} ms</td><td class="ev">{4}</td></tr>' -f
                (Section-HtmlE $p.area), (Section-HtmlE $p.file), (Section-HtmlE $p.status), (Section-HtmlE ("$($p.durationMs)")), (Section-HtmlE $p.error)))
    }
    [void]$sb.AppendLine('</tbody></table></div></div>')
    [void]$sb.AppendLine(('<p class="mt-2">Report: {0} &middot; schema v{1} &middot; read-only scan, no changes to the system.</p>' -f
            (Section-HtmlE $ctx.jsonFileName), (Section-HtmlE ("$($v.report.schemaVersion)"))))
    [void]$sb.AppendLine('</section>')
}

function Write-Footer {
    param([Parameter(Mandatory)]$ctx)
    $sb = $ctx.sb

    [void]$sb.AppendLine('</main>')
    [void]$sb.AppendLine('</div>')

    # --- scripts ---
    if ($ctx.hasAssets) {
        [void]$sb.AppendLine(('<script src="{0}/jquery/jquery-3.7.1.min.js"></script>' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<script src="{0}/bootstrap/bootstrap.bundle.min.js"></script>' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<script src="{0}/datatables/jquery.dataTables.min.js"></script>' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<script src="{0}/datatables/dataTables.bootstrap5.min.js"></script>' -f $ctx.assetBase))
        [void]$sb.AppendLine(('<script src="{0}/chartjs/chart.umd.min.js"></script>' -f $ctx.assetBase))
    }
    [void]$sb.AppendLine(('<script>window.OXYDE_ASSETS = {0};</script>' -f $(if ($ctx.hasAssets) { 'true' } else { 'false' })))

    if ($ctx.jsBlock) {
        [void]$sb.AppendLine('<script>')
        [void]$sb.AppendLine($ctx.jsBlock)
        [void]$sb.AppendLine('</script>')
    }

    [void]$sb.AppendLine('</body></html>')
}
