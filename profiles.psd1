# oxyde-win-maintenance scan profiles.
# - areas:     candidate probe areas (explicit -Areas on the CLI overrides this)
# - timeouts:  per-area timeout in seconds (overrides the global -TimeoutSeconds)
# - network:   areas that inherently need the network (labelled in the report)
# - deep:      profile requires elevation and is declared in the report
@{
    quick    = @{
        # Fast health check (<10 s): per-probe child-process startup is ~1.2 s,
        # so quick keeps only the highest-signal, lowest-cost areas.
        areas    = @('WindowsUpdate', 'PendingReboot', 'OrphanServices')
        timeouts = @{
            WindowsUpdate  = 60
            PendingReboot  = 30
            OrphanServices = 60
        }
        network  = @('WindowsUpdate')
        deep     = $false
    }
    standard = @{
        areas    = @('WindowsUpdate', 'Apps', 'Winget', 'Appx', 'Drivers', 'PendingReboot', 'OrphanServices', 'SystemProtection')
        timeouts = @{
            WindowsUpdate    = 120
            Apps             = 60
            Winget           = 180
            Appx             = 60
            Drivers          = 90
            PendingReboot    = 30
            OrphanServices   = 60
            SystemProtection = 30
        }
        network  = @('WindowsUpdate', 'Winget')
        deep     = $false
    }
    deep     = @{
        areas    = @('WindowsUpdate', 'Apps', 'Winget', 'Appx', 'Drivers', 'PendingReboot', 'OrphanServices', 'SystemProtection')
        timeouts = @{
            WindowsUpdate    = 300
            Apps             = 120
            Winget           = 300
            Appx             = 120
            Drivers          = 180
            PendingReboot    = 60
            OrphanServices   = 120
            SystemProtection = 60
        }
        network  = @('WindowsUpdate', 'Winget')
        deep     = $true
    }
}
