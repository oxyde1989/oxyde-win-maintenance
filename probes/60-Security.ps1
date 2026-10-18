# oxyde-win-maintenance probe: security posture (Defender, AV residue, firewall).
# Quick-lite (OXYDE_PROFILE=quick): Defender status + Security Center residue.
# Full (standard/deep): adds the firewall profiles.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'Security'
$findings = New-Object System.Collections.ArrayList
$avRows = @()
$fwRows = @()
$light = ($env:OXYDE_PROFILE -eq 'quick')

# --- Defender status ---
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $rtp = [bool]$mp.RealTimeProtectionEnabled
    $avOn = [bool]$mp.AntivirusEnabled
    $amOn = [bool]$mp.AMServiceEnabled
    if (-not $rtp -or -not $avOn) {
        [void]$findings.Add((New-Finding -Id 'sec-defender-off' -Area $Area -Title 'Microsoft Defender real-time protection is OFF' -Status 'CRIT' `
                    -Evidence @(
                        "Real-time protection: $rtp",
                        "Antivirus enabled: $avOn",
                        "Antimalware service: $amOn",
                        'Without active protection the machine is exposed to malware if no other antivirus is installed.'
                    ) `
                    -SuggestedAction 'Turn real-time protection back on (Windows Security > Virus & threat protection)' `
                    -AdminRequired $true -Source 'Get-MpComputerStatus'))
    }
    else {
        [void]$findings.Add((New-Finding -Id 'sec-defender-on' -Area $Area -Title 'Microsoft Defender real-time protection is active' -Status 'OK' `
                    -Source 'Get-MpComputerStatus'))
    }

    if ($mp.AntivirusSignatureLastUpdated) {
        $sigDays = [int]((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays
        if ($sigDays -gt 7) {
            [void]$findings.Add((New-Finding -Id 'sec-signatures' -Area $Area -Title ("Defender signatures are {0} days old" -f $sigDays) -Status 'WARN' `
                        -Evidence @("Last update: $($mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd HH:mm'))", 'Outdated signatures reduce detection of recent threats.') `
                        -SuggestedAction 'Update the signatures (Windows Security or Windows Update)' -Source 'Get-MpComputerStatus'))
        }
        else {
            [void]$findings.Add((New-Finding -Id 'sec-signatures' -Area $Area -Title ("Defender signatures: updated {0} day(s) ago" -f $sigDays) -Status 'INFO' `
                        -Evidence @("Last update: $($mp.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd HH:mm'))") -Source 'Get-MpComputerStatus'))
        }
    }
}
catch {
    [void]$findings.Add((New-Finding -Id 'sec-defender-unknown' -Area $Area -Title 'Defender status unavailable' -Status 'INFO' `
                -Evidence @("$($_.Exception.Message)") -Source 'Get-MpComputerStatus'))
}

# --- registered AV products + residue (Security Center) ---
try {
    $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop)
    $residue = 0
    foreach ($p in $products) {
        $exe = "$($p.pathToSignedProductExe)"
        $state = 'active'
        if ($exe -match '^(https?://|windowsdefender://)') { $state = 'virtual' }
        elseif ($exe -and -not (Test-Path -LiteralPath $exe)) { $state = 'residue (executable missing)'; $residue++ }
        elseif (-not $exe) { $state = 'unknown' }
        $avRows += [pscustomobject]@{ product = "$($p.displayName)"; exe = $exe; state = $state }

        if ($state -like 'residue*') {
            [void]$findings.Add((New-Finding -Id ("sec-residue-" + ("$($p.displayName)" -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Antivirus residue: {0} (registered, executable missing)" -f $p.displayName) -Status 'WARN' `
                        -Evidence @("Executable: $exe (not found)", 'The product is registered in Windows Security but its files are gone: leftover of an incomplete uninstall.') `
                        -SuggestedAction 'Remove the leftover entry/service or reinstall and uninstall the product cleanly' `
                        -Source 'SecurityCenter2 (AntiVirusProduct)'))
        }
        elseif ($state -eq 'active') {
            [void]$findings.Add((New-Finding -Id ("sec-av-" + ("$($p.displayName)" -replace '[^A-Za-z0-9]', '').ToLower()) -Area $Area -Title ("Antivirus registered: {0} (active)" -f $p.displayName) -Status 'INFO' `
                        -Evidence @("Executable: $exe") -Source 'SecurityCenter2 (AntiVirusProduct)'))
        }
    }
    if ($products.Count -eq 0) {
        [void]$findings.Add((New-Finding -Id 'sec-av-none' -Area $Area -Title 'No antivirus registered in Security Center' -Status 'WARN' `
                    -Evidence @('Defender provides protection by default; check why no product is registered.') -Source 'SecurityCenter2 (AntiVirusProduct)'))
    }
}
catch {
    [void]$findings.Add((New-Finding -Id 'sec-av-unknown' -Area $Area -Title 'Antivirus provider list unavailable' -Status 'INFO' `
                -Evidence @("$($_.Exception.Message)") -Source 'SecurityCenter2 (AntiVirusProduct)'))
}

# --- firewall (full profile only: the query costs ~2.7 s cold) ---
if (-not $light) {
    try {
        $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
        foreach ($p in $profiles) {
            $fwRows += [pscustomobject]@{ name = "$($p.Name)"; enabled = "$($p.Enabled)" }
            if ("$($p.Enabled)" -ne 'True') {
                [void]$findings.Add((New-Finding -Id ("sec-fw-" + "$($p.Name)".ToLower()) -Area $Area -Title ("Firewall profile disabled: {0}" -f $p.Name) -Status 'WARN' `
                            -Evidence @("Default inbound: $($p.DefaultInboundAction)", "Default outbound: $($p.DefaultOutboundAction)") `
                            -SuggestedAction 'Re-enable the firewall profile (Windows Security > Firewall & network protection)' `
                            -AdminRequired $true -Source 'Get-NetFirewallProfile'))
            }
        }
        if ($fwRows.Count -gt 0 -and @($fwRows | Where-Object { $_.enabled -ne 'True' }).Count -eq 0) {
            [void]$findings.Add((New-Finding -Id 'sec-fw-ok' -Area $Area -Title 'Firewall: all profiles enabled' -Status 'OK' -Source 'Get-NetFirewallProfile'))
        }
    }
    catch {
        [void]$findings.Add((New-Finding -Id 'sec-fw-unknown' -Area $Area -Title 'Firewall status unavailable' -Status 'INFO' `
                    -Evidence @("$($_.Exception.Message)") -Source 'Get-NetFirewallProfile'))
    }
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{ avProducts = $avRows; firewallProfiles = $fwRows } -OutFile $OutFile
