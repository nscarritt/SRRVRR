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

#region 92
Describe 'T92-08 region 92 of Workstation.psm1 reads nothing itself' {
    It 'T92-08 region 92 defines its functions and calls no process, CIM, counter, file or clock functions (all come through $Readers)' {
        $path = Join-Path (Get-RepoRoot) 'modules\Workstation.psm1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $lines = [IO.File]::ReadAllLines($path)
        $open = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*#region 92\b' })
        $close = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*#endregion 92\b' })
        $open.Count | Should -Be 1 -Because 'one #region 92 line'
        $close.Count | Should -Be 1 -Because 'one #endregion 92 line'
        $from = $open[0] + 2; $to = $close[0]   # the region's own lines, 1-based
        $inRegion = { param($n) $n.Extent.StartLineNumber -ge $from -and $n.Extent.EndLineNumber -le $to }
        # The check means something only on the region's real code.
        $defined = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { & $inRegion $_ } | ForEach-Object { $_.Name })
        foreach ($f in 'Get-MemoryDetail', 'ConvertFrom-WslConfig', 'Get-WslReading', 'Get-TopPrograms', 'New-WorkstationContext', 'Invoke-WorkstationTick') {
            $defined | Should -Contain $f -Because 'region 92 defines it'
        }
        # Commands, by name and common alias.
        $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { & $inRegion $_ } | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        foreach ($c in 'Get-Process', 'gps', 'ps', 'Get-CimInstance', 'gcim', 'Get-WmiObject', 'gwmi', 'Get-Content', 'gc', 'cat', 'type') {
            $commands | Should -Not -Contain $c -Because 'region 92 gets its readings through $Readers'
        }
        # Types and clock calls, in the region's code with its comments blanked out.
        $chars = [IO.File]::ReadAllText($path).ToCharArray()
        foreach ($t in $tokens) {
            if ($t.Kind -ne 'Comment') { continue }
            for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset; $i++) { if ($chars[$i] -ne "`n" -and $chars[$i] -ne "`r") { $chars[$i] = ' ' } }
        }
        $code = ((New-Object string (, $chars)) -split "`n")[($from - 1)..($to - 1)] -join "`n"
        $code | Should -Not -Match 'PerformanceCounterCategory'
        $code | Should -Not -Match '\[\s*(System\.)?IO\.File\s*\]'
        $code | Should -Not -Match '\[\s*(System\.)?DateTime(Offset)?\s*\]\s*::\s*(UtcNow|Now|Today)\b'
    }
}
#endregion 92
