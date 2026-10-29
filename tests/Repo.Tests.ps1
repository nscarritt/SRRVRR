# Repo-level checks: encoding, parsing, packaging, ignore rules, analyzer, changelog.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    $script:Tools = Join-Path $script:Root 'tools'
}

Describe 'T47-02 ASCII and line endings' {
    It 'T47-02 the repo has no non-ASCII bytes in code files and .bat files are CRLF' {
        $r = Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-Ascii.ps1') -Arguments @('-Root', $Root)
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'T47-02 a non-ASCII .ps1 and an LF .bat are both reported with file and line' {
        $tmp = New-TestDataPath
        try {
            [IO.File]::WriteAllText((Join-Path $tmp 'bad.ps1'), "'ok'`r`n'caf" + [char]0x00E9 + "'`r`n", (New-Object Text.UTF8Encoding($false)))
            [IO.File]::WriteAllText((Join-Path $tmp 'bad.bat'), "@echo off`necho hi`n")
            $r = Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-Ascii.ps1') -Arguments @('-Root', $tmp)
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'bad\.ps1:2'
            $r.Output | Should -Match 'bad\.bat.*CRLF'
        } finally { Remove-TestDataPath $tmp }
    }
}

Describe 'T47-03 and T47-32 parsing and C# compile' {
    It 'T47-03 every script parses and T47-32 every Add-Type block compiles' {
        $r = Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-Parse.ps1') -Arguments @('-Root', $Root) -TimeoutSeconds 300
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'Add-Type blocks compiled: [1-9]'
    }
    It 'T47-32 a C# 6 block and a PowerShell syntax error are reported with file and line' {
        $tmp = New-TestDataPath
        try {
            $bad = "Add-Type -TypeDefinition @'`r`npublic static class Bad { public static string Hi(int n) { return `$""n={n}""; } }`r`n'@`r`n"
            [IO.File]::WriteAllText((Join-Path $tmp 'csharp6.ps1'), $bad)
            [IO.File]::WriteAllText((Join-Path $tmp 'broken.ps1'), "if (`$true) {`r`n")
            $r = Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-Parse.ps1') -Arguments @('-Root', $tmp)
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'csharp6\.ps1:2: C# '
            $r.Output | Should -Match 'broken\.ps1:\d+'
        } finally { Remove-TestDataPath $tmp }
    }
}

Describe 'T47-04 the command line stays the same' {
    It 'T47-04 SRRVRR.ps1 takes exactly -Port (int) and -Stop (switch)' {
        $ast = Get-ScriptAst (Join-Path $Root 'SRRVRR.ps1')
        $params = @($ast.ParamBlock.Parameters | ForEach-Object { '{0}:{1}' -f $_.Name.VariablePath.UserPath, $_.StaticType.Name })
        $params | Should -Be @('Port:Int32', 'Stop:SwitchParameter')
    }
    It 'T47-04 the .bat files still call SRRVRR.ps1 next to themselves' {
        foreach ($bat in 'Start SRRVRR.bat', 'Stop SRRVRR.bat') {
            [IO.File]::ReadAllText((Join-Path $Root $bat)) | Should -Match '"%~dp0SRRVRR\.ps1"'
        }
    }
}

Describe 'T47-05 releases ship only runtime files' {
    It 'T47-05 git archive leaves out tests, tools, docs, .github and the git dotfiles' {
        $zip = Join-Path $env:TEMP ("srrvrr-archive-" + [guid]::NewGuid().ToString('n') + '.zip')
        try {
            & git -C $Root archive --worktree-attributes --format=zip -o $zip HEAD
            $LASTEXITCODE | Should -Be 0
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($zip)
            try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
            $names | Where-Object { $_ -match '^(tests|tools|docs|\.github)/' } | Should -BeNullOrEmpty
            $names | Should -Not -Contain '.gitattributes'
            $names | Should -Not -Contain '.gitignore'
            foreach ($need in 'SRRVRR.ps1', 'Start SRRVRR.bat', 'Stop SRRVRR.bat', 'SRRVRR.config.example.psd1', 'Install-TemperatureSensors.ps1') {
                $names | Should -Contain $need
            }
        } finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }
    }
}

Describe 'T47-06 data and local config are ignored' {
    It 'T47-06 state, logs and the user config are git-ignored' {
        $out = & git -C $Root check-ignore 'state/history.json' 'logs/srrvrr-2026-01-01.log' 'SRRVRR.config.psd1'
        @($out).Count | Should -Be 3
    }
}

Describe 'T47-24 PSScriptAnalyzer' {
    It 'T47-24 no analyzer errors with the repo settings' {
        $settings = Join-Path $Tools 'PSScriptAnalyzerSettings.psd1'
        Test-Path $settings | Should -BeTrue
        # The settings file names its own severities, so filter here: errors fail, warnings are listed by Invoke-Checks.
        $errors = @(Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings $settings | Where-Object { $_.Severity -eq 'Error' })
        ($errors | ForEach-Object { "$($_.ScriptName):$($_.Line) $($_.RuleName)" }) -join "`n" | Should -BeNullOrEmpty
    }
}

Describe 'T47-34 changelog' {
    It 'T47-34 CHANGELOG.md has an [Unreleased] section with an entry' {
        $text = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
        $text | Should -Match '(?s)## \[Unreleased\]\s+### \w+\s+- '
    }
}
