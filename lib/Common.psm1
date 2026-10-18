# oxyde-win-maintenance - functions shared by the engine, the probes and the action handlers.

$script:OxydeVersion = '0.6.0'

function Get-OxydeVersion {
    return $script:OxydeVersion
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

Export-ModuleMember -Function New-Finding, Write-JsonFile, Write-ProbeResult, New-ActionResult, Write-ActionResult, Test-IsAdmin, Expand-ImagePath, Get-OxydeVersion
