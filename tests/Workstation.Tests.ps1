# modules\Workstation.psm1 (#90 to #93, test plan 6.10 to 6.13). One region per story; add Describe blocks only
# inside your own. Every It starts with its test id.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module "$PSScriptRoot\fakes\FakeCounterReader.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Workstation.psm1') -Force
    $script:Fixtures = Join-Path (Get-RepoRoot) 'tests\fixtures\workstation'
}

#region 90 Roles and the host name (#90)
#endregion 90

#region 91 Video memory and GPU detail (#91)
#endregion 91

#region 92 Memory detail and top programs (#92)
#endregion 92

#region 93 The AI server (#93)
#endregion 93
