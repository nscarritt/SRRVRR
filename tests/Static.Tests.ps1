# Static checks of the design-for-testability rules (test plan section 3.2, rules marked S).
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:ModuleFiles = @(Get-ChildItem -Path (Join-Path $root 'modules') -Filter '*.psm1' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    function Get-CommandNames($ast) {
        @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    }
    function Get-Imports($ast) {
        @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
    }
    $script:EntryPath = Join-Path (Get-RepoRoot) 'SRRVRR.ps1'
}

Describe 'T47-09 module rules' -ForEach $ModuleFiles -AllowNullOrEmptyForEach {
    BeforeAll {
        $script:Ast = Get-ScriptAst $Path
        $script:Text = [IO.File]::ReadAllText($Path)
    }
    It 'T47-09 <Name> never reads the clock directly' {
        Get-CommandNames $Ast | Should -Not -Contain 'Get-Date'
        $Text | Should -Not -Match '\[(DateTime|DateTimeOffset)\]::(Utc)?Now'
    }
    It 'T47-09 <Name> has no Write-Host, Read-Host, exit, $global: or [Console]' {
        $names = Get-CommandNames $Ast
        $names | Should -Not -Contain 'Write-Host'
        $names | Should -Not -Contain 'Read-Host'
        @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true)).Count | Should -Be 0
        $Text | Should -Not -Match '\$global:'
        $Text | Should -Not -Match '\[Console\]'
    }
    It 'T47-08 <Name> imports only sibling modules by full path' {
        foreach ($i in Get-Imports $Ast) { $i.Extent.Text | Should -Match '\$PSScriptRoot' }
        $Text | Should -Not -Match '#Requires\s+-Modules'
        $Text | Should -Not -Match 'PSModulePath'
    }
}

Describe 'T47-08 and T47-07 entry script rules' {
    It 'T47-08 SRRVRR.ps1 imports modules by full path and never touches PSModulePath' {
        $text = [IO.File]::ReadAllText($EntryPath)
        $text | Should -Not -Match 'PSModulePath'
        $text | Should -Not -Match '#Requires\s+-Modules'
        # A literal path under modules\, or a module-path variable the script builds from $PSScriptRoot\modules.
        foreach ($i in Get-Imports (Get-ScriptAst $EntryPath)) { $i.Extent.Text | Should -Match 'modules|\$\w*[Mm]odule\w*Path' }
    }
    It 'T47-07 the Steps count matches the Set-Step calls and the last step is Reticulating Splines' {
        $ast = Get-ScriptAst $EntryPath
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Step' }, $true))
        $steps = [regex]::Match([IO.File]::ReadAllText($EntryPath), 'Steps\s*=\s*(\d+)').Groups[1].Value
        $calls.Count | Should -Be ([int]$steps)
        $calls[-1].CommandElements[1].Value | Should -Be 'Reticulating Splines...'
    }
}
