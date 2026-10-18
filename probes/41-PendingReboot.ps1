# oxyde-win-maintenance probe: pending reboot / deferred operations.
# Sources: CBS servicing state, Windows Update, Session Manager
# PendingFileRenameOperations, pending computer rename.
param(
    [Parameter(Mandatory)][string]$OutFile
)

Import-Module (Join-Path $PSScriptRoot '..\lib\Common.psm1') -Force

$Area = 'PendingReboot'
$findings = New-Object System.Collections.ArrayList
$pending = @()

if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
    $pending += 'Component Based Servicing: servicing operation pending (reboot to finish)'
}

if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
    $pending += 'Windows Update: reboot required to complete an installed update'
}

try {
    $sm = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
    $pfro = @($sm.PendingFileRenameOperations)
    if ($pfro.Count -gt 0) {
        $ops = [int][math]::Ceiling($pfro.Count / 2)
        $pending += "PendingFileRenameOperations: $ops deferred file operation(s)"
        foreach ($s in @($pfro | Where-Object { $_ } | Select-Object -First 5)) { $pending += "  - $s" }
    }
}
catch { }

try {
    $active = "$((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName)"
    $target = "$((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName)"
    if ($active -and $target -and ($active -ne $target)) {
        $pending += "Computer rename pending: '$active' -> '$target' (reboot required)"
    }
}
catch { }

if ($pending.Count -gt 0) {
    [void]$findings.Add((New-Finding -Id 'reboot-pending' -Area $Area -Title ("Pending reboot: {0} indicator(s)" -f $pending.Count) -Status 'WARN' `
                -Evidence $pending -SuggestedAction 'Restart the PC to complete the pending operations' `
                -Source 'Registry: CBS / Windows Update / Session Manager'))
}
else {
    [void]$findings.Add((New-Finding -Id 'reboot-pending' -Area $Area -Title 'No pending reboot operations' -Status 'OK' `
                -Source 'Registry: CBS / Windows Update / Session Manager'))
}

Write-ProbeResult -Findings $findings.ToArray() -Datasets @{} -OutFile $OutFile
