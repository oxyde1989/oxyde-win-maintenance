# oxyde-win-maintenance probe: device-centric driver view (consultative, read-only).
# Detects missing/problem drivers (Device Manager style) and shows the currently
# installed driver version; also builds the installed-driver inventory.
# Driver *updates* published on Windows Update remain in the WindowsUpdate area.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Drivers'
$findings = New-Object System.Collections.ArrayList
$problemRows = @()
$driverRows = @()

# Device Manager does not flag these as problems (phantom/benign states).
$benignProblems = @(
    'CM_PROB_DEVICE_NOT_THERE',   # phantom entry (e.g. PS/2 placeholders on systems without the port)
    'CM_PROB_PHANTOM',
    'CM_PROB_DISABLED',           # intentionally disabled by the user
    'CM_PROB_LEGACY_DEVICE'
)

$devices = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
$problems = @($devices | Where-Object { $_.Status -ne 'OK' })
$benignCount = 0
$realCount = 0
$missingCount = 0

foreach ($dev in $problems) {
    $problem = "$($dev.Problem)"
    if ($benignProblems -contains $problem) { $benignCount++; continue }

    $name = "$($dev.FriendlyName)"
    if (-not $name) { $name = "$($dev.InstanceId)" }

    # Currently installed driver for this device (if any).
    $ver = ''; $provider = ''; $driverDate = ''
    try {
        foreach ($p in @(Get-PnpDeviceProperty -InstanceId $dev.InstanceId -ErrorAction SilentlyContinue)) {
            switch ("$($p.KeyName)") {
                'DEVPKEY_Device_DriverVersion' { $ver = "$($p.Data)" }
                'DEVPKEY_Device_DriverProvider' { $provider = "$($p.Data)" }
                'DEVPKEY_Device_DriverDate' {
                    if ($p.Data -is [datetime]) { $driverDate = $p.Data.ToString('yyyy-MM-dd') } else { $driverDate = "$($p.Data)" }
                }
            }
        }
    }
    catch { }

    $isMissing = ($problem -eq 'CM_PROB_FAILED_INSTALL')
    $pretty = ($problem -replace '^CM_PROB_', '') -replace '_', ' '
    if (-not $pretty) { $pretty = 'Unknown problem' }

    $realCount++
    if ($isMissing) { $missingCount++ }

    $ev = @()
    $ev += "Problem: $pretty ($problem)"
    if ("$($dev.Class)") { $ev += "Device class: $($dev.Class)" }
    if ($ver) { $ev += "Installed driver: $ver" } else { $ev += 'Installed driver: none' }
    if ($provider) { $ev += "Provider: $provider" }
    if ($driverDate) { $ev += "Driver date: $driverDate" }
    $ev += "Instance: $($dev.InstanceId)"

    $title = if ($isMissing) { "Missing driver: $name" } else { "Device problem: $name" }
    [void]$findings.Add((New-Finding -Id ("dev-" + ($dev.InstanceId -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area `
                -Title $title -Status 'WARN' -Evidence $ev `
                -SuggestedAction 'Install or reinstall the device driver (Windows Update, device vendor tool, or the manufacturer support site).' `
                -Source 'Get-PnpDevice + Get-PnpDeviceProperty'))

    $problemRows += [pscustomobject]@{
        device        = $name
        class         = "$($dev.Class)"
        problem       = "$pretty ($problem)"
        driverVersion = $ver
        provider      = $provider
        driverDate    = $driverDate
        instanceId    = "$($dev.InstanceId)"
    }
}

# --- installed driver inventory (consultative) ---
try {
    $seen = @{}
    foreach ($d in @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue)) {
        $devName = "$($d.DeviceName)"
        if (-not $devName) { continue }
        $date = ''
        if ($d.DriverDate -is [datetime]) { $date = $d.DriverDate.ToString('yyyy-MM-dd') }
        $key = ("{0}|{1}" -f $devName, "$($d.DriverVersion)")
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $driverRows += [pscustomobject]@{
            device   = $devName
            class    = "$($d.DeviceClass)"
            provider = "$($d.DriverProviderName)"
            version  = "$($d.DriverVersion)"
            date     = $date
        }
    }
}
catch { }
$driverRows = @($driverRows | Sort-Object device)

# --- summary ---
$ev = @(
    ("Devices present: {0}" -f $devices.Count),
    ("Problem devices needing attention: {0}" -f $realCount),
    ("Of which missing drivers: {0}" -f $missingCount),
    ("Benign/phantom entries excluded: {0}" -f $benignCount),
    ("Drivers inventoried: {0}" -f $driverRows.Count),
    'Driver updates published on Windows Update appear under the WindowsUpdate area.'
)
$st = 'INFO'
if ($realCount -gt 0) { $st = 'WARN' }
[void]$findings.Add((New-Finding -Id 'drv-summary' -Area $Area -Title ("Driver scan: {0} problem device(s), {1} driver(s) inventoried" -f $realCount, $driverRows.Count) -Status $st `
            -Evidence $ev -SuggestedAction $(if ($realCount -gt 0) { 'Review the problem devices above.' } else { '' }) `
            -Category 'summary' -Source 'Get-PnpDevice + Win32_PnPSignedDriver'))

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ problemDevices = $problemRows; drivers = $driverRows } -OutFile $OutFile
