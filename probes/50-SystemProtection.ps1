# oxyde-win-maintenance probe: System Protection state and restore point history.
# Findings carry actionKind (restorepoint / shadow-resize) so PcPlan can offer
# the actions.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'SystemProtection'
$findings = New-Object System.Collections.ArrayList
$rows = @()

function Convert-RestorePointTime($t) {
    if ($null -eq $t) { return $null }
    if ($t -is [datetime]) { return $t }
    $s = "$t"
    if ($s -match '^\d{14}') {
        try { return [System.Management.ManagementDateTimeConverter]::ToDateTime($s) } catch { }
    }
    try { return [datetime]::Parse($s) } catch { return $null }
}

$payload = @{ description = 'oxyde-win-maintenance: pre-actions checkpoint' }
$points = $null
$readError = $null
try {
    $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
}
catch {
    $readError = $_.Exception.Message
}

# Root-cause context for missing restore points: the shadow-storage limit
# silently evicts the OLDEST snapshot (volsnap id 33) whenever usage hits the
# cap - the classic way restore points disappear without a System Restore event.
# Verified on this host (cap 4.43 GB, five evictions in three days).
$evictions7d = 0
try {
    $evictions7d = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'volsnap'; Id = 33; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
}
catch { }
$evictionNote = ''
if ($evictions7d -gt 0) {
    $evictionNote = ("The shadow-storage limit deleted the oldest snapshot {0} time(s) in the last 7 days: restore points are being silently evicted. Raise the limit with the shadow-resize action (elevated plan/apply), or manually: vssadmin resize shadowstorage /for={1} /on={1} /maxsize=10GB" -f $evictions7d, $env:SystemDrive)
}

# _11 G3 (old F1): the remedy must be reachable without elevation. The
# eviction events are plain System-log reads, so this finding exists in every
# profile and opts into the shadow-resize action even when the limit is
# unknown (the handler re-reads the live values and never shrinks). INFO on
# purpose: the elevated space-shadow-limit finding already grades the same
# root cause, and the 7-day window keeps counting past events after a resize
# has stopped them.
if ($evictions7d -gt 0) {
    [void]$findings.Add((New-Finding -Id 'syspro-evictions' -Area $Area `
                -Title ("Shadow storage evictions: {0} snapshot(s) deleted in 7 days" -f $evictions7d) -Status 'INFO' `
                -Evidence @($evictionNote) `
                -SuggestedAction 'Raise the shadow-storage limit (shadow-resize action, elevated) so restore points survive' `
                -ActionKind 'shadow-resize' -ActionPayload @{ volume = $env:SystemDrive; targetMaxGB = 10 } `
                -AdminRequired $true -Source 'volsnap id 33 (System log)'))
}

if ($null -ne $points) {
    $history = @()
    foreach ($p in $points) {
        $ct = Convert-RestorePointTime $p.CreationTime
        $history += [pscustomobject]@{
            sequence    = $p.SequenceNumber
            description = $p.Description
            creationTime = $(if ($ct) { $ct.ToString('yyyy-MM-dd HH:mm') } else { '' })
            _date       = $ct
        }
    }
    $history = @($history | Sort-Object _date -Descending)
    $rows = @($history | ForEach-Object {
            [pscustomobject]@{ sequence = $_.sequence; description = $_.description; creationTime = $_.creationTime }
        })

    if ($rows.Count -eq 0) {
        $evidence = @('System Protection appears enabled but no restore point exists', 'A restore point is the safety net for any maintenance action')
        if ($evictionNote) { $evidence += $evictionNote }
        [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                    -Title 'No restore points found' -Status 'WARN' `
                    -Evidence $evidence `
                    -SuggestedAction 'Create a restore point before applying changes; if points keep disappearing, raise the shadow-storage limit' `
                    -ActionKind 'restorepoint' -ActionPayload $payload `
                    -Source 'Get-ComputerRestorePoint'))
    }
    else {
        $newest = $history[0]._date
        if ($newest) {
            $days = [int]((Get-Date) - $newest).TotalDays
            if ($days -gt 30) {
                $ev = @("Restore points found: $($rows.Count)", 'A recent restore point protects the machine before maintenance actions')
                if ($evictionNote) { $ev += $evictionNote }
                [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                            -Title ("No recent restore point (last: {0}, {1} days ago)" -f $newest.ToString('yyyy-MM-dd'), $days) -Status 'WARN' `
                            -Evidence $ev `
                            -SuggestedAction 'Create a restore point before applying changes' `
                            -ActionKind 'restorepoint' -ActionPayload $payload `
                            -Source 'Get-ComputerRestorePoint'))
            }
            else {
                $ev = @("Restore points found: $($rows.Count)")
                if ($evictionNote) { $ev += $evictionNote }
                [void]$findings.Add((New-Finding -Id 'syspro-status' -Area $Area `
                            -Title ("System Protection active (last restore point: {0}, {1} days ago)" -f $newest.ToString('yyyy-MM-dd'), $days) -Status 'OK' `
                            -Evidence $ev `
                            -Source 'Get-ComputerRestorePoint'))
            }
        }
    }
}
else {
    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) {
        $ev = @("Get-ComputerRestorePoint failed: $readError", 'Reading restore point state requires an elevated session')
        if ($evictionNote) {
            # C7: the eviction evidence is readable without elevation and must
            # not stay hidden behind the elevation-gated branches.
            $ev += $evictionNote
            $ev += 'An elevated deep scan shows whether restore points currently exist.'
        }
        [void]$findings.Add((New-Finding -Id 'syspro-unknown' -Area $Area `
                    -Title 'System Protection state unknown (requires elevation)' -Status 'INFO' `
                    -Evidence $ev `
                    -SuggestedAction 'Re-run the scan elevated for full coverage' `
                    -AdminRequired $true -Source 'Get-ComputerRestorePoint + volsnap'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                    -Title 'System Protection appears disabled' -Status 'WARN' `
                    -Evidence @("Get-ComputerRestorePoint failed: $readError", 'Without System Protection there is no restore point safety net', 'The restore point action will try to enable System Protection on the system drive') `
                    -SuggestedAction 'Enable System Protection and create a restore point' `
                    -ActionKind 'restorepoint' -ActionPayload $payload `
                    -Source 'Get-ComputerRestorePoint'))
    }
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ restorePoints = $rows } -OutFile $OutFile
