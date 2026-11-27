# modules\Settings.psm1: defaults, the config file, validation (spec section 6; existing rules, ST7).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    function New-Config([hashtable]$Values) { $s = Get-SrrDefaultSettings; foreach ($k in $Values.Keys) { $s[$k] = $Values[$k] }; $s }
    function Write-ConfigFile([string]$Folder, [string]$Name, [string]$Text) { [IO.File]::WriteAllText((Join-Path $Folder $Name), $Text) }
}

Describe 'T47-29 existing settings rules' {
    It 'T47-29 ValheimPort accepts 1 and 65534 and rejects 0, 65535 and text' {
        { Test-SrrSettings (New-Config @{ ValheimPort = 1 }) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ ValheimPort = 65534 }) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ ValheimPort = 0 }) } | Should -Throw '*ValheimPort*'
        { Test-SrrSettings (New-Config @{ ValheimPort = 65535 }) } | Should -Throw '*ValheimPort*'
        { Test-SrrSettings (New-Config @{ ValheimPort = '2456' }) } | Should -Throw '*ValheimPort*'
    }
    It 'T47-29 FirewallScope must be a known value, and Allowlist or Blocklist need addresses' {
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Any' }) } | Should -Throw '*FirewallScope must be one of*'
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Allowlist' }) } | Should -Throw '*needs at least one address*'
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Blocklist' }) } | Should -Throw '*needs at least one address*'
    }
    It 'T47-29 private blocks and their edges' {
        Test-PrivateAddress '172.16.0.0/12' | Should -BeTrue
        Test-PrivateAddress '172.15.0.1' | Should -BeFalse   # private-check: allow (edge of a private block)
        Test-PrivateAddress '172.32.0.1' | Should -BeFalse   # private-check: allow (edge of a private block)
        Test-PrivateAddress '10.0.0.0/7' | Should -BeFalse
        Test-PrivateAddress '10.0.0.0/8' | Should -BeTrue
        Test-PrivateAddress 'fe80::/9' | Should -BeFalse
        Test-PrivateAddress 'fe80::/10' | Should -BeTrue
        Test-PrivateAddress 'fc00::/7' | Should -BeTrue
        Test-PrivateAddress '192.168.1.20-192.168.1.30' | Should -BeTrue
    }
    It 'T47-29 public addresses only with Allowlist and AllowPublicAddresses, single IPs only' {
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Allowlist'; FirewallAddresses = @('203.0.113.7') }) } | Should -Throw '*must be private*'
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Blocklist'; FirewallAddresses = @('203.0.113.7'); AllowPublicAddresses = $true }) } | Should -Throw '*must be private*'
        { Test-SrrSettings (New-Config @{ FirewallScope = 'Allowlist'; FirewallAddresses = @('203.0.113.0/24'); AllowPublicAddresses = $true }) } | Should -Throw '*single IPs*'
        $r = Test-SrrSettings (New-Config @{ FirewallScope = 'Allowlist'; FirewallAddresses = @('203.0.113.7'); AllowPublicAddresses = $true })
        @($r.Notes | Where-Object { $_.Level -eq 'Warning' -and $_.Text -match 'SECURITY' }).Count | Should -Be 1
    }
    It 'T47-29 0.0.0.0 and broadcast are never single addresses' {
        Test-SingleAddress '0.0.0.0' | Should -BeFalse
        Test-SingleAddress '255.255.255.255' | Should -BeFalse
        Test-SingleAddress '203.0.113.7' | Should -BeTrue
        Test-SingleAddress '203.0.113.0/24' | Should -BeFalse
    }
    It 'T47-29 retired keys give a note and unknown keys a warning' {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' "@{ OpenFirewall = `$true; Colour = 'red' }"
            $r = Import-SrrSettings -Folder $dir
            @($r.Notes | Where-Object { $_.Level -eq 'Note' -and $_.Text -match "'OpenFirewall' is no longer used" }).Count | Should -Be 1
            @($r.Notes | Where-Object { $_.Level -eq 'Warning' -and $_.Text -match "Unknown setting 'Colour'" }).Count | Should -Be 1
        } finally { Remove-TestDataPath $dir }
    }
    It 'T47-29 the legacy file name is read only when it is the only one' {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SystemMonitor.config.psd1' '@{ ValheimPort = 3000 }'
            $r = Import-SrrSettings -Folder $dir
            $r.Settings.ValheimPort | Should -Be 3000
            @($r.Notes | Where-Object { $_.Text -match 'old settings file name' }).Count | Should -Be 1
            Write-ConfigFile $dir 'SRRVRR.config.psd1' '@{ ValheimPort = 4000 }'
            (Import-SrrSettings -Folder $dir).Settings.ValheimPort | Should -Be 4000
        } finally { Remove-TestDataPath $dir }
    }
    It 'T47-29 no config file means the defaults, with a note saying so' {
        $dir = New-TestDataPath
        try {
            $r = Import-SrrSettings -Folder $dir
            $r.Settings.Port | Should -Be 8099
            @($r.Notes | Where-Object { $_.Text -match 'No SRRVRR.config.psd1 found' }).Count | Should -Be 1
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T47-30 the -Port parameter' {
    It 'T47-30 -Port wins over the config file' {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' '@{ Port = 8099 }'
            (Import-SrrSettings -Folder $dir -Port 8091).Settings.Port | Should -Be 8091
            (Import-SrrSettings -Folder $dir).Settings.Port | Should -Be 8099
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T65-06 the drive space settings' {
    It 'T65-06 the defaults are 85 and 95' {
        $d = Get-SrrDefaultSettings
        $d.DriveWarnPercent | Should -Be 85
        $d.DriveFullPercent | Should -Be 95
        { Test-SrrSettings (Get-SrrDefaultSettings) } | Should -Not -Throw
    }
    It 'T65-06 50 and 99 are accepted at the edges' {
        { Test-SrrSettings (New-Config @{ DriveWarnPercent = 50; DriveFullPercent = 99 }) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ DriveWarnPercent = 98; DriveFullPercent = 99 }) } | Should -Not -Throw
    }
    It 'T65-06 <name> of <value> is refused with one plain message' -ForEach @(
        @{ name = 'DriveWarnPercent'; value = 49 }, @{ name = 'DriveWarnPercent'; value = 100 }, @{ name = 'DriveWarnPercent'; value = 85.5 }, @{ name = 'DriveWarnPercent'; value = '85' }
        @{ name = 'DriveFullPercent'; value = 49 }, @{ name = 'DriveFullPercent'; value = 100 }, @{ name = 'DriveFullPercent'; value = 95.5 }, @{ name = 'DriveFullPercent'; value = '95' }
    ) {
        $message = try { Test-SrrSettings (New-Config @{ $name = $value }) | Out-Null; '' } catch { $_.Exception.Message }
        $message | Should -Match "^$name must be a whole number from 50 to 99"
        $message | Should -Not -Match "`n"
    }
    It 'T65-06 a warning level at or above the full level is refused' {
        $message = try { Test-SrrSettings (New-Config @{ DriveWarnPercent = 95; DriveFullPercent = 90 }) | Out-Null; '' } catch { $_.Exception.Message }
        $message | Should -Match 'DriveWarnPercent \(95\) must be lower than DriveFullPercent \(90\)'
        { Test-SrrSettings (New-Config @{ DriveWarnPercent = 90; DriveFullPercent = 90 }) } | Should -Throw '*lower than*'
    }
}

#region 90 Roles and the host name (#90)
Describe 'T90-03 the Role setting' {
    BeforeAll {
        # The error Test-SrrSettings throws for a settings table, or $null when it loads.
        function Get-SettingsError([hashtable]$Values) { try { Test-SrrSettings (New-Config $Values) | Out-Null; $null } catch { $_ } }
    }
    It 'T90-03 Role is Server by default, and the defaults load' {
        (Get-SrrDefaultSettings).Role | Should -BeExactly 'Server'
        { Test-SrrSettings (Get-SrrDefaultSettings) } | Should -Not -Throw
    }
    It 'T90-03 Role <value> loads from the config file (any case), with no warning' -ForEach @(
        @{ value = 'Server' }, @{ value = 'server' }, @{ value = 'Workstation' }, @{ value = 'WORKSTATION' }
    ) {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' "@{ Role = '$value' }"
            $r = Import-SrrSettings -Folder $dir
            $r.Settings.Role | Should -Be $value
            @($r.Notes | Where-Object { $_.Level -eq 'Warning' }) | Should -BeNullOrEmpty
        } finally { Remove-TestDataPath $dir }
    }
    It 'T90-03 Role <shown> is one settings error naming Server and Workstation, exit code 2' -ForEach @(
        @{ value = 'Desktop'; shown = "'Desktop'" }, @{ value = ''; shown = "''" }, @{ value = 1; shown = '1' }, @{ value = $null; shown = '$null' }
    ) {
        $err = Get-SettingsError @{ Role = $value }
        $err | Should -Not -BeNullOrEmpty -Because "Role $shown must be refused"
        $message = $err.Exception.Message
        $message | Should -Match 'Role'
        $message | Should -Match 'Server'
        $message | Should -Match 'Workstation'
        $message | Should -Not -Match "`n"
        Get-SrrExitCode $err.Exception | Should -Be 2
    }
}

Describe 'T90-05 the DisplayName setting' {
    BeforeAll {
        function Get-SettingsError([hashtable]$Values) { try { Test-SrrSettings (New-Config $Values) | Out-Null; $null } catch { $_ } }
    }
    It 'T90-05 DisplayName is empty by default, and the defaults load' {
        (Get-SrrDefaultSettings).DisplayName | Should -BeExactly ''
        { Test-SrrSettings (Get-SrrDefaultSettings) } | Should -Not -Throw
    }
    It 'T90-05 DisplayName <shown> is one settings error naming "1 to 32 characters", exit code 2' -ForEach @(
        @{ value = 'a' * 33; shown = '33 characters long' }
        @{ value = 'a<b'; shown = "'a<b'" }
        @{ value = "a`tb"; shown = 'with a tab' }
        @{ value = 'Caf' + [char]0xE9; shown = 'with a non-ASCII letter' }
        @{ value = 5; shown = 'the number 5' }
        @{ value = '   '; shown = 'only spaces (a blank header)' }
    ) {
        $err = Get-SettingsError @{ DisplayName = $value }
        $err | Should -Not -BeNullOrEmpty -Because "DisplayName $shown must be refused"
        $message = $err.Exception.Message
        $message | Should -Match 'DisplayName'
        $message | Should -Match '1 to 32 characters'
        $message | Should -Not -Match "`n"
        Get-SrrExitCode $err.Exception | Should -Be 2
    }
    It 'T90-05 DisplayName ''<value>'' loads from the config file as written, with no warning' -ForEach @(
        @{ value = 'DEV-PC' }, @{ value = 'My PC 2' }, @{ value = 'a_b.c' }, @{ value = 'b' * 32 }
    ) {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' "@{ DisplayName = '$value' }"
            $r = Import-SrrSettings -Folder $dir
            $r.Settings.DisplayName | Should -BeExactly $value
            @($r.Notes | Where-Object { $_.Level -eq 'Warning' }) | Should -BeNullOrEmpty
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T90-10 server-only settings on a workstation' {
    It 'T90-10 a Workstation config with every server-only setting valid loads, keeping them as set' {
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' "@{ Role = 'Workstation'; Processes = @{ Valheim = `$true; Plex = `$true }; ValheimPort = 2457 }"
            $r = Import-SrrSettings -Folder $dir
            $r.Settings.Role | Should -Be 'Workstation'
            $r.Settings.ValheimPort | Should -Be 2457
            $r.Settings.Processes.Valheim | Should -BeTrue
            $r.Settings.Processes.Plex | Should -BeTrue
            @($r.Notes | Where-Object { $_.Level -eq 'Warning' }) | Should -BeNullOrEmpty
        } finally { Remove-TestDataPath $dir }
    }
    It 'T90-10 a Workstation config with ValheimPort 0 gets the usual ValheimPort error (validated, then ignored)' {
        # Without a Role setting this file isn't a Workstation config at all, and the error below would prove nothing.
        (Get-SrrDefaultSettings).ContainsKey('Role') | Should -BeTrue -Because 'Role is a setting'
        $dir = New-TestDataPath
        try {
            Write-ConfigFile $dir 'SRRVRR.config.psd1' "@{ Role = 'Workstation'; ValheimPort = 0 }"
            $err = try { Import-SrrSettings -Folder $dir | Out-Null; $null } catch { $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeExactly "ValheimPort must be the Valheim server's game port, a number from 1 to 65534 (default 2456)."
            Get-SrrExitCode $err.Exception | Should -Be 2
        } finally { Remove-TestDataPath $dir }
    }
}
#endregion 90