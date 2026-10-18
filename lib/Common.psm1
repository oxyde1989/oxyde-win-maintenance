# oxyde-win-maintenance - functions shared by the engine, the probes and the action handlers.

$script:OxydeVersion = '0.8.0'

function Get-OxydeVersion {
    return $script:OxydeVersion
}

# Invariant-culture number formatting for evidence strings: machine-readable
# text must be stable regardless of the host locale ("88.6", never "88,6").
function Format-Num {
    param([object]$Value)
    if ($null -eq $Value) { return '' }
    try { return ([double]$Value).ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return "$Value" }
}

function New-Finding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('OK', 'INFO', 'WARN', 'CRIT')][string]$Status,
        [object[]]$Evidence = @(),
        [string]$SuggestedAction = '',
        [bool]$AdminRequired = $false,
        [string]$Source = '',
        [string]$Category = '',
        [string]$ActionKind = '',
        [object]$ActionPayload = $null
    )
    [pscustomobject]@{
        id              = $Id
        area            = $Area
        title           = $Title
        status          = $Status
        evidence        = @($Evidence | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { "$_" })
        suggestedAction = $SuggestedAction
        adminRequired   = $AdminRequired
        source          = $Source
        category        = $Category
        actionKind      = $ActionKind
        actionPayload   = $ActionPayload
    }
}

function Write-JsonFile {
    param(
        $InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    $json = $InputObject | ConvertTo-Json -Depth 12
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $enc)
}

function Write-ProbeResult {
    param(
        [object[]]$Findings = @(),
        $Datasets = @{},
        [Parameter(Mandatory)][string]$OutFile
    )
    $payload = [pscustomobject]@{
        findings = @($Findings)
        datasets = $Datasets
    }
    Write-JsonFile -InputObject $payload -Path $OutFile
}

# Contract object returned by every action handler (see docs\ROADMAP.md).
function New-ActionResult {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Title = '',
        [Parameter(Mandatory)][ValidateSet('dryrun', 'done', 'failed', 'skipped', 'denied', 'throttled')][string]$Status,
        [ValidateSet('pass', 'fail', 'skipped')][string]$Precheck = 'skipped',
        [string]$Command = '',
        [int]$ExitCode = 0,
        [string]$Output = '',
        [ValidateSet('pass', 'fail', 'unknown', 'skipped')][string]$Verify = 'skipped',
        [string]$UndoHint = '',
        [string]$UndoFile = '',
        [int]$DurationMs = 0
    )
    [pscustomobject]@{
        id         = $Id
        kind       = $Kind
        title      = $Title
        status     = $Status
        precheck   = $Precheck
        command    = $Command
        exitCode   = $ExitCode
        output     = $Output
        verify     = $Verify
        undoHint   = $UndoHint
        undoFile   = $UndoFile
        durationMs = $DurationMs
    }
}

function Write-ActionResult {
    param(
        $Result,
        [Parameter(Mandatory)][string]$OutFile
    )
    Write-JsonFile -InputObject $Result -Path $OutFile
}

# Capped directory walk: skips unreadable folders, stops at the file/time cap
# (naive Get-ChildItem -Recurse is ~2.5x slower and unreadable dirs abort
# EnumerateFiles, so walk per-directory with a stack). Shared by the Space and
# WindowsUpdate probes.
function Get-DirSizeCapped {
    param([string]$Root, [int]$FileCap = 20000, [int]$MsBudget = 1200)
    if (-not (Test-Path -LiteralPath $Root)) { return $null }
    $sum = [long]0
    $files = 0
    $capped = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        if ($files -ge $FileCap -or $sw.ElapsedMilliseconds -gt $MsBudget) { $capped = $true; break }
        $dir = $stack.Pop()
        try { foreach ($f in [System.IO.Directory]::GetFiles($dir)) { try { $sum += (New-Object System.IO.FileInfo($f)).Length; $files++ } catch { } } } catch { }
        try { foreach ($d in [System.IO.Directory]::GetDirectories($dir)) { $stack.Push($d) } } catch { }
    }
    $sw.Stop()
    [pscustomobject]@{ bytes = $sum; files = $files; capped = $capped; ms = $sw.ElapsedMilliseconds }
}

# Deletes only tool-generated artifacts from out\ (timestamped scan/plan/apply
# .json/.html). Allowlist-based and preview-by-default: *_latest.*, *.log files,
# subdirectories (undo\, verify_\...), every other file and anything outside
# out\ survive by design. See docs\DECISIONS.md D20.
function Clear-OxydeOutput {
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [switch]$Execute
    )
    $result = [pscustomobject]@{
        exists       = $false
        outDir       = $OutDir
        items        = @()      # candidate files to delete (full paths)
        keep         = @()      # top-level file names that do not match (display)
        removed      = @()
        skipped      = @()
        totalBytes   = [long]0
        manifestPath = ''
        error        = ''
    }
    try {
        if (-not (Test-Path -LiteralPath $OutDir)) { return $result }
        $result.exists = $true
        $rootFull = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\') + '\'
        $pattern = '^(scan|plan|apply)_\d{8}_\d{6}\.(json|html)$'

        $items = New-Object System.Collections.ArrayList
        $keep = New-Object System.Collections.ArrayList
        foreach ($f in @(Get-ChildItem -LiteralPath $OutDir -File -ErrorAction Stop)) {
            $full = [System.IO.Path]::GetFullPath($f.FullName)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($f.Name -match $pattern) { [void]$items.Add($full) } else { [void]$keep.Add($f.Name) }
        }
        $result.items = @($items)
        $result.keep = @($keep)
        foreach ($p in $items) { try { $result.totalBytes += (New-Object System.IO.FileInfo($p)).Length } catch { } }

        if (-not $Execute) { return $result }

        foreach ($p in $items) {
            try {
                $attrs = [System.IO.File]::GetAttributes($p)
                if ($attrs -band [System.IO.FileAttributes]::ReparsePoint) {
                    $result.skipped += [pscustomobject]@{ path = (Split-Path -Leaf $p); reason = 'reparse point (not followed)' }
                    continue
                }
                Remove-Item -LiteralPath $p -ErrorAction Stop
                $result.removed += (Split-Path -Leaf $p)
            }
            catch {
                $result.skipped += [pscustomobject]@{ path = (Split-Path -Leaf $p); reason = "$($_.Exception.Message)" }
            }
        }

        # Audit manifest: its name does not match the deletable pattern, so it
        # survives the next cleanup by construction.
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $manifest = [pscustomobject]@{
            cleanedAt = (Get-Date).ToString('s')
            outDir    = $OutDir
            removed   = @($result.removed)
            skipped   = @($result.skipped)
            keptCount = @($result.keep).Count
        }
        $result.manifestPath = Join-Path $OutDir ("cleanup_$stamp.json")
        Write-JsonFile -InputObject $manifest -Path $result.manifestPath
    }
    catch { $result.error = "$($_.Exception.Message)" }
    return $result
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Extracts the executable path from a service ImagePath and resolves the
# common forms: quotes, arguments, \SystemRoot\, %VAR%, \??\.
function Expand-ImagePath {
    param([string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($ImagePath)) { return $null }
    $s = $ImagePath.Trim()

    $path = $null
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 0) { $path = $s.Substring(1, $end - 1) } else { $path = $s.Substring(1) }
    } else {
        $m = [regex]::Match($s, '^(?<p>\S+?\.(exe|sys|dll|com|ocx))(\s|$)', 'IgnoreCase')
        if ($m.Success) { $path = $m.Groups['p'].Value } else { $path = ($s -split '\s+')[0] }
    }
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }

    $path = $path -replace '^\\\?\?\\', ''
    $path = $path -replace '^\\SystemRoot\\', ($env:SystemRoot + '\')
    $path = [Environment]::ExpandEnvironmentVariables($path)
    $path = $path -replace '^System32\\', ($env:SystemRoot + '\System32\')
    if ($path -notmatch '[\\/]') { return $null }
    return $path
}

Export-ModuleMember -Function New-Finding, Write-JsonFile, Write-ProbeResult, New-ActionResult, Write-ActionResult, Test-IsAdmin, Expand-ImagePath, Get-OxydeVersion, Clear-OxydeOutput, Format-Num, Get-DirSizeCapped
