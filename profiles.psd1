# oxyde-win-maintenance scan profiles.
# - areas:     candidate probe areas (explicit -Areas on the CLI overrides this)
# - timeouts:  per-area timeout in seconds (overrides the global -TimeoutSeconds)
# - network:   areas that inherently need the network (labelled in the report)
# - deep:      profile requires elevation and is declared in the report
@{
    quick    = @{
        # Fast health check (<10 s): per-probe child-process startup is ~0.25 s
        # warm; quick keeps the highest-signal, lowest-cost areas only.
        areas    = @('WindowsUpdate', 'Integrity', 'EventLog', 'Space', 'Security', 'PendingReboot', 'OrphanServices')
        timeouts = @{
            WindowsUpdate  = 60
            Integrity      = 60
            EventLog       = 60
            Space          = 60
            Security       = 60
            PendingReboot  = 30
            OrphanServices = 60
        }
        network  = @('WindowsUpdate')
        deep     = $false
    }
    standard = @{
        areas    = @('WindowsUpdate', 'Apps', 'Winget', 'Appx', 'Drivers', 'Integrity', 'EventLog', 'Space', 'Security', 'PendingReboot', 'OrphanServices', 'SystemProtection')
        timeouts = @{
            WindowsUpdate    = 120
            Apps             = 60
            Winget           = 180
            Appx             = 60
            Drivers          = 90
            Integrity        = 120
            EventLog         = 60
            Space            = 60
            Security         = 60
            PendingReboot    = 30
            OrphanServices   = 60
            SystemProtection = 30
        }
        network  = @('WindowsUpdate', 'Winget')
        deep     = $false
    }
    deep     = @{
        areas    = @('WindowsUpdate', 'Apps', 'Winget', 'Appx', 'Drivers', 'Integrity', 'EventLog', 'Space', 'Security', 'PendingReboot', 'OrphanServices', 'SystemProtection', 'Storage')
        timeouts = @{
            WindowsUpdate    = 300
            Apps             = 120
            Winget           = 300
            Appx             = 120
            Drivers          = 180
            Integrity        = 900
            EventLog         = 120
            Space            = 300
            Security         = 300
            PendingReboot    = 60
            OrphanServices   = 120
            SystemProtection = 60
            Storage          = 120
        }
        network  = @('WindowsUpdate', 'Winget')
        deep     = $true
    }
}
