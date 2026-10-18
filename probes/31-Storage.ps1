# oxyde-win-maintenance probe: storage health (deep profile).
# Part A (any elevation): Get-PhysicalDisk health/operational status - the
# usable predict-failure signal unelevated. Part B (elevated): SMART
# predict-failure (root\wmi) and storage reliability counters (wear,
# temperature, error counts). Read-only.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Storage'
$findings = New-Object System.Collections.ArrayList
$rows = @()
$isAdmin = Test-IsAdmin

# --- Part A: physical disks (works unelevated; verified ~2.8 s cold) ---
$disks = @()
try {
    $disks = @(Get-PhysicalDisk -ErrorAction Stop)
}
catch {
    [void]$findings.Add((New-Finding -Id 'storage-query' -Area $Area -Title 'Storage inventory unavailable' -Status 'INFO' `
                -Evidence @("Get-PhysicalDisk failed: $($_.Exception.Message)", 'The Storage module may be unavailable on this system.') `
                -Source 'Get-PhysicalDisk'))
}

$badDisks = @()
foreach ($d in $disks) {
    $op = (@($d.OperationalStatus) | ForEach-Object { "$_" }) -join ', '
    $sizeGB = $null
    if ($d.Size) { $sizeGB = [math]::Round($d.Size / 1GB, 1) }
    $row = [pscustomobject]@{
        name           = "$($d.FriendlyName)".Trim()
        media          = "$($d.MediaType)"
        bus            = "$($d.BusType)"
        sizeGB         = $sizeGB
        health         = "$($d.HealthStatus)"
        operational    = $op
        wear            = $null
        temperature    = $null
        powerOnHours   = $null
        readErrors     = $null
        writeErrors    = $null
        predictFailure = $null
        source         = 'Get-PhysicalDisk'
    }

    # --- Part B: reliability counters (elevated only; verified denied unelevated) ---
    if ($isAdmin) {
        try {
            $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($null -ne $rc.Wear -and $rc.Wear -ge 0) { $row.wear = $rc.Wear }
            if ($null -ne $rc.Temperature -and $rc.Temperature -gt 0) { $row.temperature = $rc.Temperature }
            if ($null -ne $rc.PowerOnHours -and $rc.PowerOnHours -ge 0) { $row.powerOnHours = $rc.PowerOnHours }
            if ($null -ne $rc.ReadErrorsTotal -and $rc.ReadErrorsTotal -gt 0) { $row.readErrors = $rc.ReadErrorsTotal }
            if ($null -ne $rc.WriteErrorsTotal -and $rc.WriteErrorsTotal -gt 0) { $row.writeErrors = $rc.WriteErrorsTotal }
        }
        catch { }
    }

    $rows += $row
    if ($row.health -ne 'Healthy' -or ($op -and $op -notmatch 'OK')) { $badDisks += $row }
}

# --- Part B: SMART predict-failure (root\wmi, elevated only) ---
$predictEntries = @()
if ($isAdmin) {
    try {
        foreach ($pf in @(Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)) {
            $predictEntries += [pscustomobject]@{ instance = "$($pf.InstanceName)"; fail = [bool]$pf.PredictFailure; reason = "$($pf.Reason)" }
        }
    }
    catch { }
    # Attach predict-failure to the matching disk row by model substring.
    foreach ($pe in $predictEntries) {
        foreach ($row in $rows) {
            if ($row.name -and $pe.instance -match [regex]::Escape($row.name)) { $row.predictFailure = $pe.fail; $row.source = 'Get-PhysicalDisk + SMART (root\wmi)' }
        }
    }
}

# --- findings ---
if ($rows.Count -gt 0) {
    if ($badDisks.Count -eq 0) {
        $ev = @()
        foreach ($r in $rows) {
            $sizeTxt = (Format-Num $r.sizeGB) + ' GB'
            $ev += ("{0}: {1} ({2}, {3}) - health {4}, status {5}" -f $r.name, $sizeTxt, $r.media, $r.bus, $r.health, $r.operational)
        }
        [void]$findings.Add((New-Finding -Id 'storage-health' -Area $Area -Title ("Storage: {0} disk(s), all report healthy" -f $rows.Count) -Status 'OK' `
                    -Evidence $ev -Source 'Get-PhysicalDisk'))
    }
    else {
        foreach ($r in $badDisks) {
            [void]$findings.Add((New-Finding -Id ("storage-health-" + ($r.name -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Disk {0}: health {1} (status {2})" -f $r.name, $r.health, $r.operational) -Status 'WARN' `
                        -Evidence @(("Media: {0}, bus: {1}, size: {2} GB" -f $r.media, $r.bus, (Format-Num $r.sizeGB)), 'A non-healthy status can indicate imminent drive failure.') `
                        -SuggestedAction 'Back up important data now and check the drive with the vendor tool' `
                        -Source 'Get-PhysicalDisk'))
        }
    }
}

$smartFailure = @($predictEntries | Where-Object { $_.fail })
$wearHigh = @($rows | Where-Object { $null -ne $_.wear -and $_.wear -gt 80 })

if ($isAdmin) {
    if ($smartFailure.Count -gt 0 -or $wearHigh.Count -gt 0) {
        $ev = @($smartFailure | ForEach-Object { "PredictFailure: $($_.instance) (reason $($_.reason))" }) +
        @($wearHigh | ForEach-Object { "Wear: $($_.name) $(Format-Num $_.wear)%" })
        [void]$findings.Add((New-Finding -Id 'storage-smart' -Area $Area -Title ("SMART predict-failure raised on {0} disk(s); {1} disk(s) over 80% wear" -f $smartFailure.Count, $wearHigh.Count) -Status 'WARN' `
                    -Evidence $ev `
                    -SuggestedAction 'Back up important data and plan a disk replacement' -Source 'SMART (root\wmi) + Get-StorageReliabilityCounter'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'storage-smart' -Area $Area -Title 'SMART: no predict-failure, wear within limits' -Status 'INFO' `
                    -Evidence @(('Disks monitored: {0}' -f $rows.Count), 'Wear threshold: 80%.') -Source 'SMART (root\wmi) + Get-StorageReliabilityCounter'))
    }
}
else {
    [void]$findings.Add((New-Finding -Id 'storage-smart' -Area $Area -Title 'SMART predict-failure and wear data require an elevated deep scan' -Status 'INFO' `
                -Evidence @('The unelevated signal above is the Get-PhysicalDisk health/operational status.', 'Run from an elevated prompt (or the GUI "Deep scan (admin)") for SMART and reliability counters.') `
                -Source 'oxyde-win-maintenance'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ physicalDisks = $rows } -OutFile $OutFile
