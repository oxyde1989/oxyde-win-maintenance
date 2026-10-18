# oxyde-win-maintenance - HTML renderer (orchestrator, _9 Part A step 2).
# The computation lives in Report-View.ps1 (stable view model) and the markup
# in Report-Sections.ps1 (section builders); this file resolves the asset
# mode, loads the embedded blocks and calls the writers in order.

. (Join-Path $PSScriptRoot 'Report-View.ps1')
. (Join-Path $PSScriptRoot 'Report-Sections.ps1')

function New-HtmlReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$JsonFileName = '',
        [switch]$InlineAssets,
        [switch]$ExternalAssets
    )
    if ($InlineAssets -and $ExternalAssets) { throw 'Use either -InlineAssets (default) or -ExternalAssets, not both.' }
    $inlineAssets = -not $ExternalAssets

    # Relative path between two directories (PS 5.1 has no
    # [System.IO.Path]::GetRelativePath); returns $null on different drives.
    function Get-RelativeDirPath([string]$FromDir, [string]$ToDir) {
        try {
            $from = [System.IO.Path]::GetFullPath($FromDir).TrimEnd('\', '/')
            $to = [System.IO.Path]::GetFullPath($ToDir).TrimEnd('\', '/')
            $fromParts = @($from -split '[\\/]')
            $toParts = @($to -split '[\\/]')
            if ($fromParts[0] -ne $toParts[0]) { return $null }
            $i = 0
            while ($i -lt $fromParts.Count -and $i -lt $toParts.Count -and $fromParts[$i] -eq $toParts[$i]) { $i++ }
            $up = @()
            if ($i -lt $fromParts.Count) { $up = @($fromParts[$i..($fromParts.Count - 1)] | ForEach-Object { '..' }) }
            $down = @()
            if ($i -lt $toParts.Count) { $down = @($toParts[$i..($toParts.Count - 1)]) }
            $rel = (@($up + $down) -join '/')
            if (-not $rel) { $rel = '.' }
            return $rel
        }
        catch { return $null }
    }

    # Vendored assets (offline report); when missing, the report falls back to
    # a minimal inline style and skips every external request.
    $assetsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\vendor'
    $hasAssets = Test-Path -LiteralPath (Join-Path $assetsDir 'bootstrap\bootstrap.min.css')
    $assetBase = ''
    if ($hasAssets) {
        $assetBase = Get-RelativeDirPath -FromDir (Split-Path -Parent ([System.IO.Path]::GetFullPath($OutFile))) -ToDir $assetsDir
        if (-not $assetBase) { $hasAssets = $false }
    }

    # Own stylesheet and script (_9 Part A step 1): read once, embed exactly.
    $assetRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\report'
    $reportCss = ''
    $reportJs = ''
    try {
        $cssPath = Join-Path $assetRoot 'report.css'
        if (Test-Path -LiteralPath $cssPath) { $reportCss = [System.IO.File]::ReadAllText($cssPath).TrimEnd([char]13, [char]10) }
    }
    catch { $reportCss = '' }
    try {
        $jsPath = Join-Path $assetRoot 'report.js'
        if (Test-Path -LiteralPath $jsPath) { $reportJs = [System.IO.File]::ReadAllText($jsPath).TrimEnd([char]13, [char]10) }
    }
    catch { $reportJs = '' }

    # Asset blocks: embedded by default (-InlineAssets), one self-contained
    # file that survives being moved alone; -ExternalAssets keeps the small
    # report with references beside assets\. Fonts referenced by the vendored
    # CSS become data: URIs in inline mode.
    function Get-EmbeddedCss([string]$RelativePath) {
        $path = Join-Path $assetsDir $RelativePath
        $txt = [System.IO.File]::ReadAllText($path)
        $dir = Split-Path $path -Parent
        $txt = [regex]::Replace($txt, 'url\(([^)]+)\)', {
                param($m)
                $u = $m.Groups[1].Value.Trim("'", '"')
                if ($u -match '^(data:|https?:|//)') { return $m.Value }
                $u = ($u -split '[?#]')[0]
                $p = Join-Path $dir $u
                if (-not (Test-Path -LiteralPath $p)) { return $m.Value }
                $mime = 'application/octet-stream'
                if ($p -match '\.woff2$') { $mime = 'font/woff2' } elseif ($p -match '\.woff$') { $mime = 'font/woff' } elseif ($p -match '\.ttf$') { $mime = 'font/ttf' } elseif ($p -match '\.svg$') { $mime = 'image/svg+xml' }
                $bytes = [System.IO.File]::ReadAllBytes($p)
                return ('url("data:{0};base64,{1}")' -f $mime, [Convert]::ToBase64String($bytes))
            })
        return $txt
    }

    $headAssets = @()
    $footAssets = @()
    if ($hasAssets) {
        try {
            if ($inlineAssets) {
                $headAssets += ('<style>' + "`n" + (Get-EmbeddedCss 'bootstrap\bootstrap.min.css') + "`n" + '</style>')
                $headAssets += ('<style>' + "`n" + (Get-EmbeddedCss 'bootstrap-icons\bootstrap-icons.min.css') + "`n" + '</style>')
                $headAssets += ('<style>' + "`n" + (Get-EmbeddedCss 'datatables\dataTables.bootstrap5.min.css') + "`n" + '</style>')
                $headAssets += ('<style>' + "`n" + (Get-EmbeddedCss 'inter\inter.css') + "`n" + '</style>')
                foreach ($jsFile in @('jquery\jquery-3.7.1.min.js', 'bootstrap\bootstrap.bundle.min.js', 'datatables\jquery.dataTables.min.js', 'datatables\dataTables.bootstrap5.min.js', 'chartjs\chart.umd.min.js')) {
                    $footAssets += ('<script>' + "`n" + [System.IO.File]::ReadAllText((Join-Path $assetsDir $jsFile)) + "`n" + '</script>')
                }
            }
            else {
                $headAssets += ('<link href="{0}/bootstrap/bootstrap.min.css" rel="stylesheet">' -f $assetBase)
                $headAssets += ('<link href="{0}/bootstrap-icons/bootstrap-icons.min.css" rel="stylesheet">' -f $assetBase)
                $headAssets += ('<link href="{0}/datatables/dataTables.bootstrap5.min.css" rel="stylesheet">' -f $assetBase)
                $headAssets += ('<link href="{0}/inter/inter.css" rel="stylesheet">' -f $assetBase)
                $footAssets += ('<script src="{0}/jquery/jquery-3.7.1.min.js"></script>' -f $assetBase)
                $footAssets += ('<script src="{0}/bootstrap/bootstrap.bundle.min.js"></script>' -f $assetBase)
                $footAssets += ('<script src="{0}/datatables/jquery.dataTables.min.js"></script>' -f $assetBase)
                $footAssets += ('<script src="{0}/datatables/dataTables.bootstrap5.min.js"></script>' -f $assetBase)
                $footAssets += ('<script src="{0}/chartjs/chart.umd.min.js"></script>' -f $assetBase)
            }
        }
        catch {
            # An unreadable asset must degrade, not abort the report.
            $hasAssets = $false
            $headAssets = @('<!-- offline mode: vendored assets not found, minimal inline style -->')
            $footAssets = @()
        }
    }
    else {
        $headAssets += '<!-- offline mode: vendored assets not found, minimal inline style -->'
    }

    $view = New-ReportView -Report $Report

    # Script placeholder substitution happens here, in the orchestrator; the
    # section builders never post-process the script.
    $jsBlock = $reportJs
    if ($jsBlock) {
        $areaJsIds = (($view.areas | ForEach-Object { "'$($_.aid)'" }) -join ', ')
        $jsBlock = $jsBlock -replace '__PC_AREAS__', $areaJsIds
        $jsBlock = $jsBlock -replace '__PC_STATUS__', $view.charts.status
        $jsBlock = $jsBlock -replace '__PC_AREA_LABELS__', $view.charts.labels
        $jsBlock = $jsBlock -replace '__PC_AREA_CRIT__', $view.charts.crit
        $jsBlock = $jsBlock -replace '__PC_AREA_WARN__', $view.charts.warn
        $jsBlock = $jsBlock -replace '__PC_AREA_INFO__', $view.charts.info
        $jsBlock = $jsBlock -replace '__PC_AREA_OK__', $view.charts.ok
    }

    $ctx = @{
        sb           = New-Object System.Text.StringBuilder
        view         = $view
        hasAssets    = $hasAssets
        assetBase    = $assetBase
        reportCss    = $reportCss
        jsBlock      = $jsBlock
        jsonFileName = $JsonFileName
        headAssets   = $headAssets
        footAssets   = $footAssets
    }

    Write-Head -ctx $ctx
    Write-Hero -ctx $ctx
    Write-Overview -ctx $ctx
    Write-Areas -ctx $ctx
    Write-Datasets -ctx $ctx
    Write-Probes -ctx $ctx
    Write-Footer -ctx $ctx

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutFile, $ctx.sb.ToString(), $enc)

    return $OutFile
}
