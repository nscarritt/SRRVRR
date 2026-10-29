# Test copies by folder, each with its own firewall rules and network-trace session (spec section 5, Test builds).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Control.psm1') -Force
}

Describe 'T48-46 which copy this is' {
    It 'T48-46 a folder with TESTBUILD.txt is a test copy, any other is the live copy' {
        $f = New-TestDataPath
        Get-SrrCopyKind -Folder $f | Should -Be 'live'
        Set-Content (Join-Path $f 'TESTBUILD.txt') 'test'
        Get-SrrCopyKind -Folder $f | Should -Be 'test'
    }
    It 'T48-46 the listener uses every address only when elevated' {
        Get-ListenerPrefix -Elevated $true -Port 8099 | Should -Be 'http://+:8099/'
        Get-ListenerPrefix -Elevated $false -Port 8091 | Should -Be 'http://localhost:8091/'
    }
}

Describe 'T48-44 the live copy''s firewall rules' {
    It 'T48-44 LocalSubnet, Allowlist and Blocklist give the same rules as before, now in the SRRVRR group' {
        $p = Get-FirewallRulePlan -Copy live -Scope LocalSubnet -Addresses @() -Port 8099
        @($p.Add | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.DisplayName, $_.Action, ($_.RemoteAddress -join ','), $_.Group }) | Should -Be @('SRRVRR|Allow|LocalSubnet|SRRVRR')
        $p = Get-FirewallRulePlan -Copy live -Scope Allowlist -Addresses @('10.0.0.5') -Port 8099
        $p.Add[0].RemoteAddress | Should -Be @('10.0.0.5')
        $p = Get-FirewallRulePlan -Copy live -Scope Blocklist -Addresses @('10.0.0.9') -Port 8099
        @($p.Add | ForEach-Object { "$($_.DisplayName)|$($_.Action)" }) | Should -Be @('SRRVRR|Allow', 'SRRVRR (blocked)|Block')
        $p.Add | ForEach-Object { $_.LocalPort | Should -Be 8099 }
    }
}

Describe 'T48-45 a test copy''s rules never touch the live copy''s' {
    It 'T48-45 a test copy adds and removes only its own names in its own group, and never the old names' {
        $p = Get-FirewallRulePlan -Copy test -Scope Blocklist -Addresses @('10.0.0.9') -Port 8091
        @($p.Add | ForEach-Object { "$($_.DisplayName)|$($_.Group)" }) | Should -Be @('SRRVRR (test)|SRRVRR (test)', 'SRRVRR (test, blocked)|SRRVRR (test)')
        @($p.Remove | Sort-Object) | Should -Be @('SRRVRR (test)', 'SRRVRR (test, blocked)')
    }
    It 'T48-45 only the live copy removes the rules from SRRVRR''s old name' {
        $live = Get-FirewallRulePlan -Copy live -Scope LocalSubnet -Addresses @() -Port 8099
        @($live.Remove | Sort-Object) | Should -Be @('SRRVRR', 'SRRVRR (blocked)', 'System Monitor', 'System Monitor (blocked)')
    }
}

Describe 'Each copy''s network-trace session' {
    It 'T48-45 the live copy keeps SRRVRRNet; a test copy gets a name of its own per folder' {
        $a = New-TestDataPath; $b = New-TestDataPath
        Get-TraceSessionName -Folder $a -Copy live | Should -Be 'SRRVRRNet'
        Get-TraceSessionName -Folder $a -Copy test | Should -Match '^SRRVRRNet-test-[0-9a-f]{8}$'
        Get-TraceSessionName -Folder $a -Copy test | Should -Not -Be (Get-TraceSessionName -Folder $b -Copy test)
    }
}
