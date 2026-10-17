# oxyde-win-maintenance probe: System Protection state and restore point history.
# Findings carry actionKind=create-restorepoint so PcPlan can offer the action.
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
        [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                    -Title 'No restore points found' -Status 'WARN' `
                    -Evidence @('System Protection appears enabled but no restore point exists', 'A restore point is the safety net for any maintenance action') `
                    -SuggestedAction 'Create a restore point before applying changes' `
                    -ActionKind 'create-restorepoint' -ActionPayload $payload `
                    -Source 'Get-ComputerRestorePoint'))
    }
    else {
        $newest = $history[0]._date
        if ($newest) {
            $days = [int]((Get-Date) - $newest).TotalDays
            if ($days -gt 30) {
                [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                            -Title ("No recent restore point (last: {0}, {1} days ago)" -f $newest.ToString('yyyy-MM-dd'), $days) -Status 'WARN' `
                            -Evidence @("Restore points found: $($rows.Count)", 'A recent restore point protects the machine before maintenance actions') `
                            -SuggestedAction 'Create a restore point before applying changes' `
                            -ActionKind 'create-restorepoint' -ActionPayload $payload `
                            -Source 'Get-ComputerRestorePoint'))
            }
            else {
                [void]$findings.Add((New-Finding -Id 'syspro-status' -Area $Area `
                            -Title ("System Protection active (last restore point: {0}, {1} days ago)" -f $newest.ToString('yyyy-MM-dd'), $days) -Status 'OK' `
                            -Evidence @("Restore points found: $($rows.Count)") `
                            -Source 'Get-ComputerRestorePoint'))
            }
        }
    }
}
else {
    $isAdmin = Test-IsAdmin
    if (-not $isAdmin) {
        [void]$findings.Add((New-Finding -Id 'syspro-unknown' -Area $Area `
                    -Title 'System Protection state unknown (requires elevation)' -Status 'INFO' `
                    -Evidence @("Get-ComputerRestorePoint failed: $readError", 'Reading restore point state requires an elevated session') `
                    -SuggestedAction 'Re-run the scan elevated for full coverage' `
                    -AdminRequired $true -Source 'Get-ComputerRestorePoint'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'syspro-restorepoint' -Area $Area `
                    -Title 'System Protection appears disabled' -Status 'WARN' `
                    -Evidence @("Get-ComputerRestorePoint failed: $readError", 'Without System Protection there is no restore point safety net', 'The restore point action will try to enable System Protection on the system drive') `
                    -SuggestedAction 'Enable System Protection and create a restore point' `
                    -ActionKind 'create-restorepoint' -ActionPayload $payload `
                    -Source 'Get-ComputerRestorePoint'))
    }
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ restorePoints = $rows } -OutFile $OutFile
