<#
.SYNOPSIS
    oxyde-win-maintenance - remove tool-generated artifacts from out\ (CLI entry for Clear-OxydeOutput).

.DESCRIPTION
    Deletes only timestamped scan_*.json/html, plan_*.json and apply_*.json
    files at the top level of out\. Never touched: *_latest.*, *.log
    transcripts, subdirectories (undo\, verify_\...), every other file and
    anything outside out\. Preview first, explicit confirmation, optional
    audit manifest (cleanup_<ts>.json). See docs\DECISIONS.md D20.

.EXAMPLE
    .\Clean-Out.ps1                 # preview + interactive confirmation
    .\Clean-Out.ps1 -Preview        # list only, delete nothing
    .\Clean-Out.ps1 -Yes            # scripted: no prompt
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [switch]$Preview,
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'out' }

function Format-SizeMB {
    param([long]$Bytes)
    return ([math]::Round($Bytes / 1MB, 1)).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

$r = Clear-OxydeOutput -OutDir $OutDir
if (-not $r.exists) {
    Write-Host ("out\ folder not found: {0}" -f $OutDir)
    exit 0
}

Write-Host ("out\ cleanup - {0}" -f $r.outDir)
Write-Host ("Deletable: {0} file(s), {1} MB" -f @($r.items).Count, (Format-SizeMB $r.totalBytes))
foreach ($p in @($r.items)) { Write-Host ("  del  {0}" -f (Split-Path -Leaf $p)) }
Write-Host ("Kept (top level): {0} file(s)" -f @($r.keep).Count)
foreach ($k in @($r.keep)) { Write-Host ("  keep {0}" -f $k) }

if (@($r.items).Count -eq 0) { Write-Host 'Nothing to delete.'; exit 0 }
if ($Preview) { exit 0 }

if (-not $Yes) {
    $answer = Read-Host ("Delete {0} file(s)? [y/N]" -f @($r.items).Count)
    if ($answer -notmatch '^(y|yes|s|si)$') { Write-Host 'Aborted.'; exit 0 }
}

$exec = Clear-OxydeOutput -OutDir $OutDir -Execute
Write-Host ("Removed: {0} | skipped: {1}" -f @($exec.removed).Count, @($exec.skipped).Count)
foreach ($s in @($exec.skipped)) { Write-Host ("  skipped {0}: {1}" -f $s.path, $s.reason) }
Write-Host ("Manifest: {0}" -f $exec.manifestPath)
exit 0
