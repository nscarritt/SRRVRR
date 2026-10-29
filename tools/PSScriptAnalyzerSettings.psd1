# PSScriptAnalyzer rules for SRRVRR (Windows PowerShell 5.1).
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The console UI in SRRVRR.ps1 and the tools writes to the host on purpose; modules are checked separately
        # by tests\Static.Tests.ps1, which forbids Write-Host there.
        'PSAvoidUsingWriteHost',
        # Test files assign variables in BeforeAll that Pester reads from other blocks.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
