# modules\Workstation.psm1 (#90 to #93, test plan 6.10 to 6.13). One region per story; add Describe blocks only
# inside your own. Every It starts with its test id.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module "$PSScriptRoot\fakes\FakeCounterReader.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Workstation.psm1') -Force
    $script:Fixtures = Join-Path (Get-RepoRoot) 'tests\fixtures\workstation'
}

#region 90 Roles and the host name (#90)
Describe 'T90-01 and T90-02 the role plan' {
    It 'T90-01 Get-RolePlan <role> is the server plan: Processes and the tracer on, no Workstation part, five history lines' -ForEach @(
        @{ role = 'Server' }, @{ role = 'server' }, @{ role = 'SERVER' }
    ) {
        $plan = Get-RolePlan -Role $role
        $plan | Should -BeOfType [hashtable]
        @($plan.Keys | Sort-Object) | Should -Be @('HistoryLines', 'Processes', 'Role', 'Tracer', 'Workstation')
        $plan.Role | Should -BeExactly 'server'
        $plan.Processes | Should -BeOfType [bool]
        $plan.Processes | Should -BeTrue
        $plan.Tracer | Should -BeOfType [bool]
        $plan.Tracer | Should -BeTrue
        $plan.Workstation | Should -BeOfType [bool]
        $plan.Workstation | Should -BeFalse
        @($plan.HistoryLines) | Should -BeExactly @('cpu', 'mem', 'gpu', 'rx', 'tx')
    }
    It 'T90-02 Get-RolePlan <role> is the workstation plan: no Processes or tracer, the Workstation part, seven history lines' -ForEach @(
        @{ role = 'Workstation' }, @{ role = 'workstation' }, @{ role = 'WORKSTATION' }
    ) {
        $plan = Get-RolePlan -Role $role
        $plan | Should -BeOfType [hashtable]
        @($plan.Keys | Sort-Object) | Should -Be @('HistoryLines', 'Processes', 'Role', 'Tracer', 'Workstation')
        $plan.Role | Should -BeExactly 'workstation'
        $plan.Processes | Should -BeOfType [bool]
        $plan.Processes | Should -BeFalse
        $plan.Tracer | Should -BeOfType [bool]
        $plan.Tracer | Should -BeFalse
        $plan.Workstation | Should -BeOfType [bool]
        $plan.Workstation | Should -BeTrue
        @($plan.HistoryLines) | Should -BeExactly @('cpu', 'mem', 'gpu', 'rx', 'tx', 'vram', 'vramShared')
    }
}

Describe 'T90-04 the name on the page' {
    It 'T90-04 Resolve-DisplayName (''<setting>'', <role>, <computer>) is ''<expected>''' -ForEach @(
        @{ setting = ''; role = 'server'; computer = 'ANYPC'; expected = 'SRRVRR' }
        @{ setting = ''; role = 'workstation'; computer = 'DEV-PC'; expected = 'DEV-PC' }
        @{ setting = 'My PC'; role = 'server'; computer = 'X'; expected = 'My PC' }
        @{ setting = 'My PC'; role = 'workstation'; computer = 'X'; expected = 'My PC' }
    ) {
        $name = Resolve-DisplayName -Setting $setting -Role $role -ComputerName $computer
        $name | Should -BeOfType [string]
        $name | Should -BeExactly $expected
    }
}

Describe 'T90-06 the startup lines for each role' {
    It 'T90-06 Format-RoleLines gives exactly "Role: Server" for the server plan' {
        $lines = @(Format-RoleLines -Plan (Get-RolePlan -Role 'Server'))
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly 'Role: Server'
    }
    It 'T90-06 Format-RoleLines gives exactly the two workstation lines, in order' {
        $lines = @(Format-RoleLines -Plan (Get-RolePlan -Role 'Workstation'))
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'Role: Workstation. Off: Processes. On: video memory, top programs, AI server'
        $lines[1] | Should -BeExactly 'Not used on a workstation: Processes, ValheimPort'
    }
}
#endregion 90

#region 91 Video memory and GPU detail (#91)
#endregion 91

#region 92 Memory detail and top programs (#92)
#endregion 92

#region 93 The AI server (#93)
#endregion 93
