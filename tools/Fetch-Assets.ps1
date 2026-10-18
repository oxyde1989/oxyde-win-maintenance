# oxyde-win-maintenance - downloads the pinned report assets into assets\vendor
# so the HTML report renders offline. Run once (and re-run to repair).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path $PSScriptRoot -Parent
$vendor = Join-Path $root 'assets\vendor'

function Get-Asset {
    param([string]$Url, [string]$RelPath, [string]$UserAgent = '')
    $dest = Join-Path $vendor $RelPath
    $dir = Split-Path $dest -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $params = @{ Uri = $Url; OutFile = $dest; UseBasicParsing = $true }
    if ($UserAgent) { $params.UserAgent = $UserAgent }
    Invoke-WebRequest @params
    $size = (Get-Item -LiteralPath $dest).Length
    Write-Host ("{0,-50} {1,9:N0} bytes" -f $RelPath, $size)
}

# --- pinned vendor files (versions match the former CDN links) ---
$files = @(
    @{ u = 'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css'; p = 'bootstrap\bootstrap.min.css' }
    @{ u = 'https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js'; p = 'bootstrap\bootstrap.bundle.min.js' }
    @{ u = 'https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css'; p = 'bootstrap-icons\bootstrap-icons.min.css' }
    @{ u = 'https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/fonts/bootstrap-icons.woff2'; p = 'bootstrap-icons\fonts\bootstrap-icons.woff2' }
    @{ u = 'https://code.jquery.com/jquery-3.7.1.min.js'; p = 'jquery\jquery-3.7.1.min.js' }
    @{ u = 'https://cdn.datatables.net/1.13.8/css/dataTables.bootstrap5.min.css'; p = 'datatables\dataTables.bootstrap5.min.css' }
    @{ u = 'https://cdn.datatables.net/1.13.8/js/jquery.dataTables.min.js'; p = 'datatables\jquery.dataTables.min.js' }
    @{ u = 'https://cdn.datatables.net/1.13.8/js/dataTables.bootstrap5.min.js'; p = 'datatables\dataTables.bootstrap5.min.js' }
    @{ u = 'https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js'; p = 'chartjs\chart.umd.min.js' }
)
foreach ($f in $files) { Get-Asset -Url $f.u -RelPath $f.p }

# --- Inter (latin subset, weights 400-800) ---
# Google serves the same variable-font woff2 for every weight: fetch it once
# and emit one @font-face per weight pointing at the single file.
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
$interCss = (Invoke-WebRequest -Uri 'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&display=swap' -UserAgent $ua -UseBasicParsing).Content
$blocks = [regex]::Matches($interCss, '/\* (?<subset>[\w-]+) \*/\s*@font-face\s*\{(?<body>[^}]+)\}')
$fontCss = New-Object System.Text.StringBuilder
[void]$fontCss.AppendLine('/* Inter (latin) - vendored from Google Fonts for offline use */')
$faces = 0
$fetched = @{}
foreach ($b in $blocks) {
    if ($b.Groups['subset'].Value -ne 'latin') { continue }
    $body = $b.Groups['body'].Value
    $w = [regex]::Match($body, 'font-weight:\s*(\d+)').Groups[1].Value
    $u = [regex]::Match($body, 'url\((https://[^)]+\.woff2)\)').Groups[1].Value
    if (-not $w -or -not $u) { continue }
    if (-not $fetched.ContainsKey($u)) { Get-Asset -Url $u -RelPath 'inter\Inter.woff2'; $fetched[$u] = $true }
    [void]$fontCss.AppendLine(("@font-face {{ font-family: 'Inter'; font-style: normal; font-weight: {0}; font-display: swap; src: url('Inter.woff2') format('woff2'); }}" -f $w))
    $faces++
}
$cssPath = Join-Path $vendor 'inter\inter.css'
[System.IO.File]::WriteAllText($cssPath, $fontCss.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("{0,-50} {1,9:N0} bytes ({2} faces)" -f 'inter\inter.css', (Get-Item -LiteralPath $cssPath).Length, $faces)

if ($faces -lt 5) { Write-Warning ("Expected 5 Inter faces (400-800), got {0}: re-run the fetch." -f $faces) }
Write-Host ''
Write-Host ("Assets ready in: {0}" -f $vendor)
