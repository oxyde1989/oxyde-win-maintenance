var PC_AREAS = [__PC_AREAS__];
var PC_STATUS = __PC_STATUS__;
var PC_AREA_LABELS = __PC_AREA_LABELS__;
var PC_AREA_CRIT = __PC_AREA_CRIT__;
var PC_AREA_WARN = __PC_AREA_WARN__;
var PC_AREA_INFO = __PC_AREA_INFO__;
var PC_AREA_OK = __PC_AREA_OK__;
var PC_COLORS = { crit: '#ef4444', warn: '#f59e0b', info: '#3b82f6', ok: '#10b981' };
var pcCharts = {};
var PC_HAS_JQ = !!window.jQuery;
var PC_HAS_DT = PC_HAS_JQ && !!(window.jQuery.fn && window.jQuery.fn.DataTable);
var PC_HAS_BS = !!window.bootstrap;
var PC_HAS_CHART = !!window.Chart;

function pcApply($card) {
  if (!PC_HAS_JQ) { return; }
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
  if (!PC_HAS_JQ) { return; }
  var $card = $('#area-' + areaId);
  $card.attr('data-filter', status);
  if (btn) { $card.find('.btn-filter').removeClass('active'); $(btn).addClass('active'); }
  pcApply($card);
}

function pcThemeChartColors(theme) {
  if (!PC_HAS_CHART) { return; }
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
  if (!PC_HAS_JQ) { return; }
  document.documentElement.setAttribute('data-bs-theme', theme);
  try { localStorage.setItem('oxyde-win-maintenance-theme', theme); } catch (e) { }
  $('#themeLight').toggleClass('active', theme === 'light');
  $('#themeDark').toggleClass('active', theme === 'dark');
  pcThemeChartColors(theme);
}

function pcSpy() {
  if (!PC_HAS_JQ) { return; }
  var pos = $(window).scrollTop() + 140;
  var current = '';
  $('.pc-section').each(function () {
    if ($(this).offset().top <= pos) { current = $(this).attr('id'); }
  });
  $('#pcSidebarNav .nav-link').removeClass('active');
  if (current) { $('#pcSidebarNav .nav-link[href="#' + current + '"]').addClass('active'); }
}

function pcInit() {
  if (!PC_HAS_JQ) { return; }
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

  if (PC_HAS_DT) {
    $('table.pc-dt').each(function () {
      $(this).DataTable({
        pageLength: 15,
        lengthMenu: [[15, 30, 60, -1], [15, 30, 60, 'All']],
        order: []
      });
    });
  }

  if (PC_HAS_BS) {
    document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(function (el) {
      new bootstrap.Tooltip(el, { container: 'body' });
    });
  }

  if (PC_HAS_CHART) {
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
  }

  var theme = document.documentElement.getAttribute('data-bs-theme') || 'light';
  $('#themeLight').toggleClass('active', theme === 'light');
  $('#themeDark').toggleClass('active', theme === 'dark');
  pcThemeChartColors(theme);

  $(window).on('scroll', pcSpy);
  pcSpy();
}

if (PC_HAS_JQ) { jQuery(pcInit); }
