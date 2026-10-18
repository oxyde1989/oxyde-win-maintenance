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
        [string]$JsonFileName = ''
    )

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
