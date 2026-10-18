<#
.SYNOPSIS
    oxyde-win-maintenance console - WinForms GUI orchestrating scan, findings, actions and log.

.DESCRIPTION
    Thin shell over the entry points: runs PcScan.ps1 / PcPlan.ps1 / PcApply.ps1
    as child processes, tails their output live and requests elevation only for
    the apply step (single UAC). See docs\DECISIONS.md D9.

.USAGE
    .\PcConsole.ps1
#>
#requires -Version 5.1
param(
    [switch]$AutoScan   # testing aid: start a scan automatically right after launch
)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptRoot = $PSScriptRoot
$OutDir = Join-Path $ScriptRoot 'out'
$PsExe = Join-Path $PSHOME 'powershell.exe'
Import-Module (Join-Path $ScriptRoot 'lib\Common.psm1') -Force

# ---------------- state ----------------
$script:process = $null          # child process being watched
$script:logFile = $null          # file the child writes its output to (tailed by the timer)
$script:logLen = [long]0         # characters already flushed to the UI
$script:logBox = $null
$script:onDone = $null
$script:elevWatch = $null        # @{ proc=...; logLen=0; logPath=$null }
$script:plan = $null
$script:planActions = @()
$script:loadingPlan = $false
$script:health = $null
$script:findingsAll = @()
$script:errLog = Join-Path $env:TEMP 'oxyde_console_error.log'

# ---------------- helpers ----------------
# UI event handlers must never kill the app: any error is logged, the window stays open.
function Write-UiError {
    param([string]$Context)
    try {
        $msg = "[{0}] {1}: {2}`r`n{3}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Context, $_.Exception.Message, $_.ScriptStackTrace
        [System.IO.File]::AppendAllText($script:errLog, $msg, (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Invoke-Guarded {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body }
    catch { Write-UiError $Name }
}

function Quote-PS([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

function Append-Line {
    param([System.Windows.Forms.RichTextBox]$Box, [string]$Text)
    if (-not $Text) { return }
    $Box.AppendText($Text)
    if (-not $Text.EndsWith("`n")) { $Box.AppendText("`r`n") }
    $Box.SelectionStart = $Box.TextLength
    $Box.ScrollToCaret()
}

# Reads only the new part of a log file (safe while the writer holds it open)
# and appends it to the UI box. Returns the new character count consumed.
function Read-LogDelta {
    param([string]$Path, [long]$LastLen, [System.Windows.Forms.RichTextBox]$Box)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $LastLen }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
            $full = $sr.ReadToEnd()
            $sr.Dispose()
        }
        finally { $fs.Dispose() }

        if ($full.Length -lt $LastLen) { $LastLen = 0 }
        if ($full.Length -gt $LastLen) {
            Append-Line -Box $Box -Text $full.Substring([int]$LastLen)
            return [long]$full.Length
        }
        return $LastLen
    }
    catch { return $LastLen }
}

function Set-Busy([bool]$Busy) {
    $btnHealth.Enabled = -not $Busy
    $btnDeep.Enabled = -not $Busy
    $btnScan.Enabled = -not $Busy
    $btnPlan.Enabled = -not $Busy
    $btnDryRun.Enabled = -not $Busy
    $btnApply.Enabled = -not $Busy
    $btnReload.Enabled = -not $Busy
    $btnReloadPlan.Enabled = -not $Busy
    $btnPlanActions.Enabled = -not $Busy
    $btnCleanOut.Enabled = -not $Busy
    $progBar.Style = 'Marquee'
    $progBar.Visible = $Busy
    if ($Busy) { $progBar.MarqueeAnimationSpeed = 30 } else { $progBar.MarqueeAnimationSpeed = 0 }
}

function Start-Child {
    param(
        [string]$ScriptPath,
        [string]$ParamText,
        [System.Windows.Forms.RichTextBox]$Box,
        [scriptblock]$Done,
        [string]$JobName = 'run'
    )
    try {
        # The child writes all its streams to a log file; the UI timer tails it.
        # (No .NET output events: those callbacks run on pool threads and can
        # crash the process or corrupt shared state - see docs\DECISIONS.md D9.)
        $logFile = Join-Path $env:TEMP ("oxyde_gui_{0}.log" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
        $cmd = "& $(Quote-PS $ScriptPath) $ParamText *>&1 | Out-File -LiteralPath $(Quote-PS $logFile) -Encoding utf8"
        Append-Line -Box $Box -Text ("--- {0} started {1} ---`r`n> {2}" -f $JobName, (Get-Date -Format 'HH:mm:ss'), $ParamText)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $PsExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        $script:process = $proc
        $script:logFile = $logFile
        $script:logLen = [long]0
        $script:logBox = $Box
        $script:onDone = $Done
        Set-Busy $true
    }
    catch {
        Write-UiError 'Start-Child'
        Append-Line -Box $Box -Text ("Failed to start {0}: {1}" -f $JobName, $_.Exception.Message)
        Set-Busy $false
    }
}

function Start-Elevated {
    param(
        [string]$ParamText,
        [System.Windows.Forms.RichTextBox]$Box,
        [scriptblock]$Done,
        [string]$JobName = 'apply (elevated)',
        [string]$ScriptFile = 'PcApply.ps1'
    )
    # The elevated child writes all streams to a log file (tailed by the timer).
    $logFile = Join-Path $env:TEMP ("oxyde_gui_{0}.log" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    Set-Content -LiteralPath $logFile -Value '' -Encoding UTF8 -ErrorAction SilentlyContinue
    Append-Line -Box $Box -Text ("--- {0} started {1} (UAC prompt expected) ---`r`n> {2} {3}" -f $JobName, (Get-Date -Format 'HH:mm:ss'), $ScriptFile, $ParamText)
    $inner = "& $(Quote-PS (Join-Path $ScriptRoot $ScriptFile)) $ParamText *>&1 | Out-File -LiteralPath $(Quote-PS $logFile) -Encoding utf8"
    $args = "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`""
    try {
        $proc = Start-Process -FilePath $PsExe -Verb RunAs -ArgumentList $args -PassThru -ErrorAction Stop
        $script:elevWatch = @{ proc = $proc; logLen = [long]0; logPath = $logFile }
        $script:logBox = $Box
        $script:onDone = $Done
        Set-Busy $true
    }
    catch {
        Append-Line -Box $Box -Text ("Elevation cancelled or failed: {0}" -f $_.Exception.Message)
    }
}

# ---------------- form ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'oxyde-win-maintenance console'
$form.Size = New-Object System.Drawing.Size(1240, 840)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1130, 700)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

# ================= SCAN TAB =================
$tabScan = New-Object System.Windows.Forms.TabPage
$tabScan.Text = 'Scan'
$tabs.Controls.Add($tabScan)

$scanTop = New-Object System.Windows.Forms.Panel
$scanTop.Dock = 'Top'; $scanTop.Height = 118
$tabScan.Controls.Add($scanTop)

$lblAreas = New-Object System.Windows.Forms.Label
$lblAreas.Text = 'Areas:'; $lblAreas.Location = New-Object System.Drawing.Point(10, 8); $lblAreas.AutoSize = $true
$scanTop.Controls.Add($lblAreas)

$clbAreas = New-Object System.Windows.Forms.CheckedListBox
$clbAreas.Location = New-Object System.Drawing.Point(10, 28)
$clbAreas.Size = New-Object System.Drawing.Size(720, 80)
$clbAreas.MultiColumn = $true
$clbAreas.ColumnWidth = 165
$clbAreas.CheckOnClick = $true
$scanTop.Controls.Add($clbAreas)

$areaNames = @()
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $ScriptRoot 'probes') -Filter '*.ps1')) {
    if ($f.Name -match '^(\d+)-([A-Za-z0-9]+)\.ps1$') { $areaNames += $Matches[2] }
}
foreach ($a in ($areaNames | Sort-Object)) { [void]$clbAreas.Items.Add($a, $true) }

# Toolbar: row 1 = the three run actions, colour-coded by cost (green = fast
# and safe, blue = full picture, amber = slow + elevation). Row 2 = utilities,
# deliberately neutral so colour keeps meaning "how heavy is this action".
$btnHealth = New-Object System.Windows.Forms.Button
$btnHealth.Text = 'Run quick check'; $btnHealth.Location = New-Object System.Drawing.Point(745, 26); $btnHealth.Size = New-Object System.Drawing.Size(115, 30)
$btnHealth.BackColor = [System.Drawing.Color]::FromArgb(198, 239, 206)
$scanTop.Controls.Add($btnHealth)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = 'Run standard scan'; $btnScan.Location = New-Object System.Drawing.Point(865, 26); $btnScan.Size = New-Object System.Drawing.Size(130, 30)
$btnScan.BackColor = [System.Drawing.Color]::FromArgb(219, 234, 254)
$scanTop.Controls.Add($btnScan)

$btnDeep = New-Object System.Windows.Forms.Button
$btnDeep.Text = 'Run deep scan'; $btnDeep.Location = New-Object System.Drawing.Point(1000, 26); $btnDeep.Size = New-Object System.Drawing.Size(115, 30)
$btnDeep.BackColor = [System.Drawing.Color]::FromArgb(255, 236, 204)
$scanTop.Controls.Add($btnDeep)

$btnOpenReport = New-Object System.Windows.Forms.Button
$btnOpenReport.Text = 'Open report'; $btnOpenReport.Location = New-Object System.Drawing.Point(745, 62); $btnOpenReport.Size = New-Object System.Drawing.Size(115, 28)
$btnOpenReport.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$scanTop.Controls.Add($btnOpenReport)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = 'Open out folder'; $btnOpenFolder.Location = New-Object System.Drawing.Point(865, 62); $btnOpenFolder.Size = New-Object System.Drawing.Size(95, 28)
$btnOpenFolder.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$scanTop.Controls.Add($btnOpenFolder)

$btnCleanOut = New-Object System.Windows.Forms.Button
$btnCleanOut.Text = 'Clean out\'; $btnCleanOut.Location = New-Object System.Drawing.Point(965, 62); $btnCleanOut.Size = New-Object System.Drawing.Size(150, 28)
$btnCleanOut.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$scanTop.Controls.Add($btnCleanOut)

$progBar = New-Object System.Windows.Forms.ProgressBar
$progBar.Location = New-Object System.Drawing.Point(10, 108); $progBar.Size = New-Object System.Drawing.Size(1100, 6)
$progBar.Visible = $false
$scanTop.Controls.Add($progBar)

# Health verdict banner (colored by verdict, hidden when no health block).
$verdictPanel = New-Object System.Windows.Forms.Panel
$verdictPanel.Dock = 'Top'; $verdictPanel.Height = 34; $verdictPanel.Visible = $false
$tabScan.Controls.Add($verdictPanel)

$lblVerdict = New-Object System.Windows.Forms.Label
$lblVerdict.Dock = 'Fill'
$lblVerdict.TextAlign = 'MiddleLeft'
$lblVerdict.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$lblVerdict.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$verdictPanel.Controls.Add($lblVerdict)

$rtbScan = New-Object System.Windows.Forms.RichTextBox
$rtbScan.Dock = 'Fill'; $rtbScan.ReadOnly = $true; $rtbScan.BackColor = [System.Drawing.Color]::FromArgb(16, 23, 42)
$rtbScan.ForeColor = [System.Drawing.Color]::Gainsboro; $rtbScan.Font = New-Object System.Drawing.Font('Consolas', 9)
$rtbScan.WordWrap = $false
$tabScan.Controls.Add($rtbScan)
$rtbScan.BringToFront()

# ================= FINDINGS TAB =================
$tabFindings = New-Object System.Windows.Forms.TabPage
$tabFindings.Text = 'Findings'
$tabs.Controls.Add($tabFindings)

$findTop = New-Object System.Windows.Forms.Panel
$findTop.Dock = 'Top'; $findTop.Height = 46
$tabFindings.Controls.Add($findTop)

$btnReload = New-Object System.Windows.Forms.Button
$btnReload.Text = 'Reload report'; $btnReload.Location = New-Object System.Drawing.Point(10, 8); $btnReload.Size = New-Object System.Drawing.Size(110, 30)
$findTop.Controls.Add($btnReload)

$btnPlan = New-Object System.Windows.Forms.Button
$btnPlan.Text = 'Build action plan'; $btnPlan.Location = New-Object System.Drawing.Point(130, 8); $btnPlan.Size = New-Object System.Drawing.Size(130, 30)
$findTop.Controls.Add($btnPlan)

$lblFindInfo = New-Object System.Windows.Forms.Label
$lblFindInfo.Location = New-Object System.Drawing.Point(275, 14); $lblFindInfo.AutoSize = $true
$lblFindInfo.ForeColor = [System.Drawing.Color]::DimGray
$findTop.Controls.Add($lblFindInfo)

$chkIssuesOnly = New-Object System.Windows.Forms.CheckBox
$chkIssuesOnly.Text = 'Issues only (hide INFO/OK)'; $chkIssuesOnly.Location = New-Object System.Drawing.Point(640, 13)
$chkIssuesOnly.AutoSize = $true
$findTop.Controls.Add($chkIssuesOnly)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false; $grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'; $grid.RowHeadersVisible = $false
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
foreach ($col in @(
        @{ n = 'Status'; w = 8 }, @{ n = 'Area'; w = 12 }, @{ n = 'Title'; w = 45 }, @{ n = 'Suggested action'; w = 35 }
    )) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $col.n; $c.HeaderText = $col.n; $c.FillWeight = $col.w
    [void]$grid.Columns.Add($c)
}
$tabFindings.Controls.Add($grid)
$grid.BringToFront()

# ================= ACTIONS TAB =================
$tabActions = New-Object System.Windows.Forms.TabPage
$tabActions.Text = 'Actions'
$tabs.Controls.Add($tabActions)

$actTop = New-Object System.Windows.Forms.Panel
$actTop.Dock = 'Top'; $actTop.Height = 76
$tabActions.Controls.Add($actTop)

$btnReloadPlan = New-Object System.Windows.Forms.Button
$btnReloadPlan.Text = 'Reload plan'; $btnReloadPlan.Location = New-Object System.Drawing.Point(10, 8); $btnReloadPlan.Size = New-Object System.Drawing.Size(100, 30)
$actTop.Controls.Add($btnReloadPlan)

$btnPlanActions = New-Object System.Windows.Forms.Button
$btnPlanActions.Text = 'Build plan from last scan'; $btnPlanActions.Location = New-Object System.Drawing.Point(505, 8); $btnPlanActions.Size = New-Object System.Drawing.Size(160, 30)
$actTop.Controls.Add($btnPlanActions)

$btnDryRun = New-Object System.Windows.Forms.Button
$btnDryRun.Text = 'Dry run selected'; $btnDryRun.Location = New-Object System.Drawing.Point(120, 8); $btnDryRun.Size = New-Object System.Drawing.Size(120, 30)
$actTop.Controls.Add($btnDryRun)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = 'Apply selected...'; $btnApply.Location = New-Object System.Drawing.Point(250, 8); $btnApply.Size = New-Object System.Drawing.Size(120, 30)
$btnApply.BackColor = [System.Drawing.Color]::FromArgb(255, 236, 204)
$actTop.Controls.Add($btnApply)

$chkRestoreFirst = New-Object System.Windows.Forms.CheckBox
$chkRestoreFirst.Text = 'Create restore point first'; $chkRestoreFirst.Location = New-Object System.Drawing.Point(390, 14)
$chkRestoreFirst.AutoSize = $true; $chkRestoreFirst.Checked = $true
$actTop.Controls.Add($chkRestoreFirst)

$lblActInfo = New-Object System.Windows.Forms.Label
$lblActInfo.Location = New-Object System.Drawing.Point(10, 48); $lblActInfo.AutoSize = $true
$lblActInfo.ForeColor = [System.Drawing.Color]::DimGray
$actTop.Controls.Add($lblActInfo)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
$tabActions.Controls.Add($split)
$split.Panel1MinSize = 120; $split.Panel2MinSize = 120
# Dock order fix (same pattern as the Scan/Findings tabs): the Fill body must
# be front-most so that $actTop (Dock=Top) keeps its height instead of
# collapsing to zero. SplitterDistance is set later, in the Shown handler.
$split.BringToFront()

$clbActions = New-Object System.Windows.Forms.CheckedListBox
$clbActions.Dock = 'Fill'; $clbActions.CheckOnClick = $true
$split.Panel1.Controls.Add($clbActions)

$rtbActions = New-Object System.Windows.Forms.RichTextBox
$rtbActions.Dock = 'Fill'; $rtbActions.ReadOnly = $true; $rtbActions.BackColor = [System.Drawing.Color]::FromArgb(16, 23, 42)
$rtbActions.ForeColor = [System.Drawing.Color]::Gainsboro; $rtbActions.Font = New-Object System.Drawing.Font('Consolas', 9)
$rtbActions.WordWrap = $false
$split.Panel2.Controls.Add($rtbActions)

# ================= LOG TAB =================
$tabLog = New-Object System.Windows.Forms.TabPage
$tabLog.Text = 'Log'
$tabs.Controls.Add($tabLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock = 'Fill'; $rtbLog.ReadOnly = $true; $rtbLog.BackColor = [System.Drawing.Color]::FromArgb(16, 23, 42)
$rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro; $rtbLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$rtbLog.WordWrap = $false
$tabLog.Controls.Add($rtbLog)

# ---------------- data loaders ----------------
$script:rowColors = @{
    CRIT = [System.Drawing.Color]::FromArgb(253, 226, 226)
    WARN = [System.Drawing.Color]::FromArgb(254, 243, 199)
    INFO = [System.Drawing.Color]::FromArgb(219, 234, 254)
    OK   = [System.Drawing.Color]::FromArgb(220, 252, 231)
}

function Render-Findings {
    try {
        $grid.Rows.Clear()
        $shown = 0
        foreach ($f in $script:findingsAll) {
            if ($chkIssuesOnly.Checked -and "$($f.status)" -notin @('CRIT', 'WARN')) { continue }
            $i = $grid.Rows.Add("$($f.status)", "$($f.area)", "$($f.title)", "$($f.suggestedAction)")
            if ($script:rowColors.ContainsKey("$($f.status)")) { $grid.Rows[$i].DefaultCellStyle.BackColor = $script:rowColors["$($f.status)"] }
            $shown++
        }
        $lblFindInfo.Text = ("{0} findings shown of {1}" -f $shown, $script:findingsAll.Count)
    }
    catch { Write-UiError 'Render-Findings' }
}

function Update-VerdictBanner {
    try {
        if (-not $script:health) { $verdictPanel.Visible = $false; return }
        $v = "$($script:health.verdict)"
        $label = $v
        switch ($v) {
            'OK' { $verdictPanel.BackColor = [System.Drawing.Color]::FromArgb(220, 252, 231); $lblVerdict.ForeColor = [System.Drawing.Color]::FromArgb(20, 83, 45); $label = 'HEALTHY' }
            'WARNING' { $verdictPanel.BackColor = [System.Drawing.Color]::FromArgb(254, 243, 199); $lblVerdict.ForeColor = [System.Drawing.Color]::FromArgb(120, 53, 15); $label = 'ATTENTION NEEDED' }
            'CRITICAL' { $verdictPanel.BackColor = [System.Drawing.Color]::FromArgb(253, 226, 226); $lblVerdict.ForeColor = [System.Drawing.Color]::FromArgb(127, 29, 29); $label = 'CRITICAL' }
            default { $verdictPanel.BackColor = [System.Drawing.Color]::FromArgb(226, 232, 240); $lblVerdict.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85) }
        }
        $issuesTxt = ''
        if ("$($script:health.issues)" -ne '') { $issuesTxt = ", $($script:health.issues) issues" }
        $txt = "{0} - score {1}{2}  |  {3} critical, {4} warnings  |  profile: {5}{6}" -f $label, "$($script:health.score)", $issuesTxt, "$($script:health.counts.crit)", "$($script:health.counts.warn)", "$($script:health.profile)", $(if ("$($script:health.adminUsed)" -eq 'True') { ' (elevated)' } else { '' })
        if ($script:health.coverage -and "$($script:health.coverage.partial)" -eq 'True') { $txt += '  |  partial coverage' }
        $top = @($script:health.topIssues) | Select-Object -First 1
        if ($top.Count -gt 0) { $txt += ("  |  top: " + "$($top[0].title)") }
        $lblVerdict.Text = $txt
        $verdictPanel.Visible = $true
    }
    catch { Write-UiError 'Update-VerdictBanner' }
}

function Load-Report {
    try {
        $reportPath = Join-Path $OutDir 'scan_latest.json'
        $script:findingsAll = @()
        $script:health = $null
        Update-VerdictBanner
        if (-not (Test-Path -LiteralPath $reportPath)) {
            $grid.Rows.Clear()
            $lblFindInfo.Text = 'No report found. Run a scan first.'
            return
        }
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:findingsAll = @($report.findings)
        if ($report.health) { $script:health = $report.health }
        Update-VerdictBanner
        Render-Findings
    }
    catch {
        Write-UiError 'Load-Report'
        $lblFindInfo.Text = ("Report load failed: {0}" -f $_.Exception.Message)
    }
}

function Load-Plan {
    $script:loadingPlan = $true
    try {
        $planPath = Join-Path $OutDir 'plan_latest.json'
        $clbActions.Items.Clear()
        $script:plan = $null
        $script:planActions = @()
        if (-not (Test-Path -LiteralPath $planPath)) {
            $lblActInfo.Text = 'No plan found. Build one from the Findings tab.'
            return
        }
        $script:plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:planActions = @($script:plan.actions)
        $i = 0
        foreach ($a in $script:planActions) {
            $admin = if ($a.adminRequired) { 'admin' } else { 'user' }
            $text = ("{0}  [{1}, risk {2}, {3}]" -f "$($a.title)", "$($a.kind)", "$($a.risk)", $admin)
            $checked = [bool]$a.defaultSelected
            if ("$($a.kind)" -eq 'restorepoint' -and -not $chkRestoreFirst.Checked) { $checked = $false }
            [void]$clbActions.Items.Add($text, $checked)
            $i++
        }
        # Freshness: age and source profile of the report the plan was built from.
        $age = ''
        if ($script:plan.generatedAt) {
            try {
                $mins = [int]((Get-Date) - [datetime]$script:plan.generatedAt).TotalMinutes
                if ($mins -lt 0) { $mins = 0 }
                if ($mins -lt 1) { $age = 'just now' }
                elseif ($mins -lt 60) { $age = "$mins min ago" }
                elseif ($mins -lt 1440) { $age = ("{0} h ago" -f [int]($mins / 60)) }
                else { $age = ("{0} d ago" -f [int]($mins / 1440)) }
            }
            catch { }
        }
        $prof = "$($script:plan.sourceProfile)"; if (-not $prof) { $prof = 'unknown' }
        $src = Split-Path -Leaf "$($script:plan.sourceReport)"
        $lblActInfo.Text = ("Plan: {0} actions | source: {1} ({2}{3})" -f $script:planActions.Count, $src, $prof, $(if ($age) { ", built $age" } else { '' }))
    }
    catch {
        Write-UiError 'Load-Plan'
        $lblActInfo.Text = ("Plan load failed: {0}" -f $_.Exception.Message)
    }
    finally {
        $script:loadingPlan = $false
    }
}

function Get-SelectedActionIds {
    $ids = @()
    for ($i = 0; $i -lt $clbActions.Items.Count; $i++) {
        if ($clbActions.GetItemChecked($i)) { $ids += "$($script:planActions[$i].id)" }
    }
    return $ids
}

# ---------------- events ----------------
$btnHealth.Add_Click({
        $tabs.SelectedTab = $tabScan
        Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcScan.ps1') -ParamText ("-Profile quick -OutDir $(Quote-PS $OutDir)") -Box $rtbScan -JobName 'health check (quick)' -Done {
            Load-Report
            $chkIssuesOnly.Checked = $true
            $tabs.SelectedTab = $tabFindings
            Append-Line -Box $rtbScan -Text '--- health check finished ---'
        }
    })

$btnDeep.Add_Click({
        $msg = "Run a deep scan (elevated, one UAC prompt)?`n`nIt uses the deep profile and is declared in the report."
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'oxyde-win-maintenance - deep scan', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        $tabs.SelectedTab = $tabScan
        Start-Elevated -ScriptFile 'PcScan.ps1' -ParamText ("-Profile deep -OutDir $(Quote-PS $OutDir)") -Box $rtbScan -JobName 'deep scan (elevated)' -Done {
            Load-Report
            Append-Line -Box $rtbScan -Text '--- deep scan finished ---'
        }
    })

$btnScan.Add_Click({
        $areas = @()
        for ($i = 0; $i -lt $clbAreas.Items.Count; $i++) {
            if ($clbAreas.GetItemChecked($i)) { $areas += $clbAreas.Items[$i] }
        }
        $paramText = '-Profile standard '
        if ($areas.Count -gt 0 -and $areas.Count -ne $clbAreas.Items.Count) {
            $paramText += "-Areas $(Quote-PS ($areas -join ',')) "
        }
        $paramText += "-OutDir $(Quote-PS $OutDir)"
        $tabs.SelectedTab = $tabScan
        Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcScan.ps1') -ParamText $paramText -Box $rtbScan -JobName 'scan (standard)' -Done {
            Load-Report
            Append-Line -Box $rtbScan -Text '--- scan finished ---'
        }
    })

$chkIssuesOnly.Add_CheckedChanged({ Invoke-Guarded -Name 'issues filter' -Body { Render-Findings } })

$btnOpenReport.Add_Click({
        $html = Join-Path $OutDir 'scan_latest.html'
        if (Test-Path -LiteralPath $html) { Start-Process $html } else { [System.Windows.Forms.MessageBox]::Show('No HTML report found. Run a scan first.') }
    })

$btnOpenFolder.Add_Click({ Start-Process explorer.exe $OutDir })

# Two-step cleanup: preview via the shared library function, explicit
# confirmation, then execute. Deletes only timestamped scan/plan/apply artifacts
# (allowlist); *_latest.*, logs, subfolders and everything else survive (D20).
$btnCleanOut.Add_Click({
        Invoke-Guarded -Name 'clean out' -Body {
            $r = Clear-OxydeOutput -OutDir $OutDir
            if (-not $r.exists) { [System.Windows.Forms.MessageBox]::Show('out\ folder not found.'); return }
            if (@($r.items).Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Nothing to delete: no timestamped scan/plan/apply files.'); return }
            $mb = ([math]::Round($r.totalBytes / 1MB, 1)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
            $keepPreview = if (@($r.keep).Count -gt 8) { ((@($r.keep) | Select-Object -First 8) -join "`r`n") + "`r`n... (+$(@($r.keep).Count - 8) more)" } else { (@($r.keep) -join "`r`n") }
            $msg = @"
Delete $(@($r.items).Count) file(s), $mb MB?

Never touched: *_latest.*, *.log, undo\ and verify_*\ folders, subdirectories and every other file.

Top-level files kept:
$keepPreview
"@
            $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'oxyde-win-maintenance - clean out\', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { return }
            $exec = Clear-OxydeOutput -OutDir $OutDir -Execute
            Append-Line -Box $rtbLog -Text ("--- out\ cleanup {0}: removed {1} file(s), skipped {2}, manifest {3} ---" -f (Get-Date -Format 'HH:mm:ss'), @($exec.removed).Count, @($exec.skipped).Count, (Split-Path -Leaf "$($exec.manifestPath)"))
            foreach ($s in @($exec.skipped)) { Append-Line -Box $rtbLog -Text ("    skipped {0}: {1}" -f $s.path, $s.reason) }
            [System.Windows.Forms.MessageBox]::Show(("Removed {0} file(s). Details in the Log tab." -f @($exec.removed).Count), 'oxyde-win-maintenance')
        }
    })

$btnReload.Add_Click({ Load-Report })

$btnPlan.Add_Click({
        $tabs.SelectedTab = $tabFindings
        $rtbLog.Clear()
        Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcPlan.ps1') -ParamText ("-OutDir $(Quote-PS $OutDir)") -Box $rtbLog -JobName 'plan' -Done {
            Load-Plan
            Append-Line -Box $rtbLog -Text '--- plan finished (see Actions tab) ---'
        }
    })

$btnReloadPlan.Add_Click({ Load-Plan })

$btnPlanActions.Add_Click({
        $tabs.SelectedTab = $tabActions
        $rtbLog.Clear()
        Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcPlan.ps1') -ParamText ("-OutDir $(Quote-PS $OutDir)") -Box $rtbLog -JobName 'plan' -Done {
            Load-Plan
            Append-Line -Box $rtbActions -Text '--- plan built from last scan (list updated above) ---'
        }
    })

$btnDryRun.Add_Click({
        $ids = Get-SelectedActionIds
        if ($ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No actions selected.'); return }
        $paramText = "-Plan $(Quote-PS (Join-Path $OutDir 'plan_latest.json')) -OutDir $(Quote-PS $OutDir) -Only $(Quote-PS ($ids -join ','))"
        Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcApply.ps1') -ParamText $paramText -Box $rtbActions -JobName 'dry run' -Done {
            Append-Line -Box $rtbActions -Text '--- dry run finished ---'
        }
    })

$btnApply.Add_Click({
        $ids = Get-SelectedActionIds
        if ($ids.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('No actions selected.'); return }
        $needsAdmin = $false
        foreach ($id in $ids) {
            $act = $script:planActions | Where-Object { "$($_.id)" -eq $id } | Select-Object -First 1
            if ($act -and $act.adminRequired) { $needsAdmin = $true; break }
        }
        $msg = "Apply {0} selected action(s) now?`n`nThis will change the system." -f $ids.Count
        if ($needsAdmin) { $msg += "`nA single UAC prompt will be requested." }
        $answer = [System.Windows.Forms.MessageBox]::Show($msg, 'oxyde-win-maintenance - confirm apply', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }

        $paramText = "-Plan $(Quote-PS (Join-Path $OutDir 'plan_latest.json')) -Apply -Yes -OutDir $(Quote-PS $OutDir) -Only $(Quote-PS ($ids -join ','))"
        if ($needsAdmin) {
            Start-Elevated -ParamText $paramText -Box $rtbActions -JobName 'apply' -Done {
                $applyPath = Join-Path $OutDir 'apply_latest.json'
                if (Test-Path -LiteralPath $applyPath) {
                    $apply = Get-Content -LiteralPath $applyPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    Append-Line -Box $rtbActions -Text ("--- apply finished: {0} ---" -f (($apply.results | Group-Object status | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '))
                }
                else { Append-Line -Box $rtbActions -Text '--- apply finished (no result file) ---' }
                Load-Plan
            }
        }
        else {
            Start-Child -ScriptPath (Join-Path $ScriptRoot 'PcApply.ps1') -ParamText $paramText -Box $rtbActions -JobName 'apply' -Done {
                Append-Line -Box $rtbActions -Text '--- apply finished ---'
                Load-Plan
            }
        }
    })

$chkRestoreFirst.Add_CheckedChanged({
        for ($i = 0; $i -lt $clbActions.Items.Count; $i++) {
            if ("$($script:planActions[$i].kind)" -eq 'restorepoint') {
                $clbActions.SetItemChecked($i, $chkRestoreFirst.Checked)
            }
        }
    })

# Bulk vs single winget upgrades are mutually exclusive.
$clbActions.Add_ItemCheck({
        param($sender, $e)
        Invoke-Guarded -Name 'actions check' -Body {
            if ($script:loadingPlan) { return }
            if ($e.Index -lt 0 -or $e.Index -ge $script:planActions.Count) { return }
            $act = $script:planActions[$e.Index]
            if ("$($act.kind)" -ne 'winget-upgrade') { return }
            $mode = "$($act.payload.mode)"
            if ($e.NewValue -ne [System.Windows.Forms.CheckState]::Checked) { return }

            $script:loadingPlan = $true
            try {
                for ($i = 0; $i -lt $script:planActions.Count; $i++) {
                    $other = $script:planActions[$i]
                    if ("$($other.kind)" -ne 'winget-upgrade') { continue }
                    $om = "$($other.payload.mode)"
                    if ($mode -eq 'all' -and $om -eq 'one') { $clbActions.SetItemChecked($i, $false) }
                    if ($mode -eq 'one' -and $om -eq 'all') { $clbActions.SetItemChecked($i, $false) }
                }
            }
            finally { $script:loadingPlan = $false }
        }
    })

# ---------------- timer: live output + elevated watch + completion ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 350
$timer.Add_Tick({ Invoke-Guarded -Name 'timer tick' -Body {
            if ($script:process) {
                if ($script:logFile) {
                    $script:logLen = Read-LogDelta -Path $script:logFile -LastLen $script:logLen -Box $script:logBox
                }
                if ($script:process.HasExited) {
                    Start-Sleep -Milliseconds 150
                    if ($script:logFile) {
                        $script:logLen = Read-LogDelta -Path $script:logFile -LastLen $script:logLen -Box $script:logBox
                    }
                    $done = $script:onDone
                    $script:process = $null; $script:onDone = $null; $script:logFile = $null
                    Set-Busy $false
                    if ($done) { & $done }
                }
            }
            elseif ($script:elevWatch) {
                $ew = $script:elevWatch
                if (-not $ew.logPath) {
                    $newest = Get-ChildItem -LiteralPath $OutDir -Filter 'apply_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    if ($newest -and $newest.LastWriteTime -ge (Get-Date).AddMinutes(-5)) { $ew.logPath = $newest.FullName }
                }
                if ($ew.logPath) {
                    $ew.logLen = Read-LogDelta -Path $ew.logPath -LastLen $ew.logLen -Box $script:logBox
                }
                if ($ew.proc.HasExited) {
                    if ($ew.logPath) {
                        $ew.logLen = Read-LogDelta -Path $ew.logPath -LastLen $ew.logLen -Box $script:logBox
                    }
                    $done = $script:onDone
                    $script:elevWatch = $null; $script:onDone = $null
                    Set-Busy $false
                    if ($done) { & $done }
                }
            }
        }
    })
$timer.Start()

# ---------------- start ----------------
Load-Report
Load-Plan
Append-Line -Box $rtbScan -Text 'oxyde-win-maintenance console ready. "Run quick check" for a quick verdict, "Run standard scan" for the full picture.'
Append-Line -Box $rtbLog -Text 'oxyde-win-maintenance console ready.'

if ($AutoScan) {
    $autoTimer = New-Object System.Windows.Forms.Timer
    $autoTimer.Interval = 1500
    $autoTimer.Add_Tick({ $autoTimer.Stop(); $btnScan.PerformClick() })
    $autoTimer.Start()
}

# Deterministic layout once the form is shown: splitter distance is set after
# the container has a real size (min sizes are applied at construction), then
# a one-shot geometry dump is written to the Log tab and to a temp file, so the
# layout can be verified without the UI (acceptance for the Actions-tab fix).
$form.Add_Shown({
        Invoke-Guarded -Name 'layout init' -Body {
            $h = $split.Height
            if ($h -gt 0) {
                $d = [int]($h * 0.4)
                if ($d -lt $split.Panel1MinSize) { $d = $split.Panel1MinSize }
                $max = $h - $split.Panel2MinSize
                if ($d -gt $max) { $d = $max }
                if ($max -ge $split.Panel1MinSize) { $split.SplitterDistance = $d }
            }
        }
        Invoke-Guarded -Name 'layout diagnostics' -Body {
            $planExists = Test-Path -LiteralPath (Join-Path $OutDir 'plan_latest.json')
            $line = ("layout: actTop.height={0} split={1}x{2} splitter={3} clbActions={4}x{5} items={6} planExists={7}" -f `
                    $actTop.Bounds.Height, $split.Bounds.Width, $split.Bounds.Height, $split.SplitterDistance, `
                    $clbActions.Bounds.Width, $clbActions.Bounds.Height, $clbActions.Items.Count, $planExists)
            Append-Line -Box $rtbLog -Text $line
            $btnLine = ("buttons: quick='{0}'@{1},{2} {3}x{4} | standard='{5}'@{6},{7} {8}x{9} | deep='{10}'@{11},{12} {13}x{14} | report='{15}'@{16},{17} | folder='{18}'@{19},{20} | clean='{21}'@{22},{23} minSize={24}" -f `
                    $btnHealth.Text, $btnHealth.Left, $btnHealth.Top, $btnHealth.Width, $btnHealth.Height, `
                    $btnScan.Text, $btnScan.Left, $btnScan.Top, $btnScan.Width, $btnScan.Height, `
                    $btnDeep.Text, $btnDeep.Left, $btnDeep.Top, $btnDeep.Width, $btnDeep.Height, `
                    $btnOpenReport.Text, $btnOpenReport.Left, $btnOpenReport.Top, `
                    $btnOpenFolder.Text, $btnOpenFolder.Left, $btnOpenFolder.Top, `
                    $btnCleanOut.Text, $btnCleanOut.Left, $btnCleanOut.Top, `
                    "$($form.MinimumSize.Width)x$($form.MinimumSize.Height)")
            Append-Line -Box $rtbLog -Text $btnLine
            try {
                $layoutLog = Join-Path $env:TEMP 'oxyde_console_layout.log'
                [System.IO.File]::WriteAllText($layoutLog, ($line + "`r`n" + $btnLine + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            }
            catch { }
        }
    })

[void]$form.ShowDialog()
$timer.Stop()
