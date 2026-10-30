# Exit codes and the new settings (spec sections 5 and 6).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    function New-Config([hashtable]$Values) { $s = Get-SrrDefaultSettings; foreach ($k in $Values.Keys) { $s[$k] = $Values[$k] }; $s }
    # Runs Test-SrrSettings and returns the exception it threw, or $null.
    function Get-SettingsError([hashtable]$Values) { try { $null = Test-SrrSettings (New-Config $Values); $null } catch { $_.Exception } }
}

Describe 'T48-22 LogRetentionDays' {
    It 'T48-22 7, 31 and 366 are accepted, 31 is the default' {
        (Get-SrrDefaultSettings).LogRetentionDays | Should -Be 31
        foreach ($v in 7, 31, 366) { Get-SettingsError @{ LogRetentionDays = $v } | Should -BeNullOrEmpty -Because "$v" }
    }
    It 'T48-22 6, 367, 31.5, text and nothing are settings errors naming the setting and its range' {
        foreach ($v in 6, 367, 31.5, '31', $null) {
            $e = Get-SettingsError @{ LogRetentionDays = $v }
            $e | Should -BeOfType ([SrrSettingsException]) -Because "'$v'"
            $e.Message | Should -Match 'LogRetentionDays.*7.*366'
        }
    }
}

Describe 'T48-23 Maintenance hours' {
    It 'T48-23 the defaults are 2 and 8 hours' {
        (Get-SrrDefaultSettings).MaintenanceHours | Should -Be 2
        (Get-SrrDefaultSettings).MaintenanceMaxHours | Should -Be 8
    }
    It 'T48-23 MaintenanceMaxHours is 1 to 24' {
        foreach ($v in 1, 24, 8.5) { Get-SettingsError @{ MaintenanceMaxHours = $v; MaintenanceHours = 1 } | Should -BeNullOrEmpty -Because "$v" }
        foreach ($v in 0.99, 24.01, 'eight') { Get-SettingsError @{ MaintenanceMaxHours = $v; MaintenanceHours = 0.5 } | Should -BeOfType ([SrrSettingsException]) -Because "$v" }
    }
    It 'T48-23 MaintenanceHours is 0.25 up to MaintenanceMaxHours' {
        Get-SettingsError @{ MaintenanceHours = 0.25 } | Should -BeNullOrEmpty
        Get-SettingsError @{ MaintenanceHours = 8 } | Should -BeNullOrEmpty
        Get-SettingsError @{ MaintenanceHours = 4; MaintenanceMaxHours = 4 } | Should -BeNullOrEmpty
        $e = Get-SettingsError @{ MaintenanceHours = 0.24 }
        $e | Should -BeOfType ([SrrSettingsException]); $e.Message | Should -Match 'MaintenanceHours'
        Get-SettingsError @{ MaintenanceHours = 8.01 } | Should -BeOfType ([SrrSettingsException])
        Get-SettingsError @{ MaintenanceHours = 4.01; MaintenanceMaxHours = 4 } | Should -BeOfType ([SrrSettingsException])
    }
}

Describe 'T48-24 DataPath' {
    It 'T48-24 empty, and full local paths that exist, don''t exist or are read-only, are accepted' {
        $existing = New-TestDataPath
        try {
            foreach ($v in '', $existing, 'Q:\no\such\folder', 'C:\Windows') { Get-SettingsError @{ DataPath = $v } | Should -BeNullOrEmpty -Because "'$v'" }
        } finally { Remove-TestDataPath $existing }
    }
    It 'T48-24 relative, drive-relative, network, \\?\ and letterless paths, and non-text, are settings errors' {
        foreach ($v in 'data', 'X:data', '\\server\share\srrvrr', '\\?\C:\data', '\data', 5) {
            $e = Get-SettingsError @{ DataPath = $v }
            $e | Should -BeOfType ([SrrSettingsException]) -Because "'$v'"
            $e.Message | Should -Match 'DataPath'
        }
    }
}

Describe 'T48-26 the example config' {
    It 'T48-26 every new setting is in the example, with the code''s default and a comment above it' {
        $examplePath = Join-Path (Get-RepoRoot) 'SRRVRR.config.example.psd1'
        $example = Import-PowerShellDataFile $examplePath
        $lines = [IO.File]::ReadAllLines($examplePath)
        $defaults = Get-SrrDefaultSettings
        foreach ($k in 'DataPath', 'LogRetentionDays', 'MaintenanceHours', 'MaintenanceMaxHours') {
            $example.ContainsKey($k) | Should -BeTrue -Because $k
            $example[$k] | Should -Be $defaults[$k] -Because $k
            $i = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match "^\s*$k\s*=" })
            $lines[$i - 1] | Should -Match '^\s*#' -Because "$k has a comment"
        }
        @((Get-SrrRetiredSettings).Keys | Sort-Object) | Should -Be @('GpuFallback', 'ListenAddress', 'OpenFirewall')
    }
}

Describe 'T48-27 exit codes' {
    It 'T48-27 settings errors are 2, refusals 3, anything else 1' {
        Get-SrrExitCode -Exception ([SrrSettingsException]::new('x')) | Should -Be 2
        Get-SrrExitCode -Exception ([SrrRefusalException]::new('x')) | Should -Be 3
        Get-SrrExitCode -Exception ([InvalidOperationException]::new('x')) | Should -Be 1
        Get-SrrExitCode -Exception $null | Should -Be 1
    }
    It 'T48-27 a wrapped settings error or refusal keeps its code' {
        $wrapped = [Management.Automation.RuntimeException]::new('outer', [SrrRefusalException]::new('inner'))
        Get-SrrExitCode -Exception $wrapped | Should -Be 3
        $method = [Management.Automation.MethodInvocationException]::new('call', [SrrSettingsException]::new('inner'))
        Get-SrrExitCode -Exception $method | Should -Be 2
        try { & { function Inner { throw [SrrSettingsException]::new('deep') }; Inner } } catch { $record = $_ }
        Get-SrrExitCode -Exception $record.Exception | Should -Be 2
    }
}

Describe 'T48-28 the last log line' {
    It 'T48-28 says why SRRVRR stopped and its exit code' {
        Format-StopLine -Reason 'requested' -Code 0 | Should -Be 'stopped: requested (exit 0)'
        Format-StopLine -Reason 'Ctrl+C' -Code 0 | Should -Be 'stopped: Ctrl+C (exit 0)'
        Format-StopLine -Reason 'settings error' -Code 2 | Should -Be 'stopped: settings error (exit 2)'
        Format-StopLine -Reason 'refused: the data folder is shared' -Code 3 | Should -Be 'stopped: refused: the data folder is shared (exit 3)'
        Format-StopLine -Reason 'crash: System.InvalidOperationException' -Code 1 | Should -Be 'stopped: crash: System.InvalidOperationException (exit 1)'
    }
    It 'T48-28 Get-SrrStopReason names the kind of stop from the exception' {
        Get-SrrStopReason -Exception ([SrrSettingsException]::new('bad')) | Should -Be 'settings error'
        Get-SrrStopReason -Exception ([SrrRefusalException]::new('the data folder is shared')) | Should -Be 'refused: the data folder is shared'
        Get-SrrStopReason -Exception ([InvalidOperationException]::new('boom')) | Should -Be 'crash: System.InvalidOperationException'
    }
}
