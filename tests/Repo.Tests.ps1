# Repo-level checks: encoding, parsing, packaging, ignore rules, analyzer, changelog.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    $script:Tools = Join-Path $script:Root 'tools'
}

Describe 'T47-01 the files the spec names exist' {
    It 'T47-01 modules, web, tests, the measuring tool and the workflow are in the repo' {
        foreach ($p in 'modules\Counters.psm1', 'web\index.html', 'web\app.js', 'web\style.css', 'web\img', 'tests', 'tools\Measure-SRRVRR.ps1', '.github\workflows\checks.yml') {
            Test-Path (Join-Path $Root $p) | Should -BeTrue -Because $p
        }
    }
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
    It 'T47-32 a compiler warning is an error, as Add-Type treats it on Windows PowerShell 5.1' {
        $tmp = New-TestDataPath
        try {
            $warn = "Add-Type -TypeDefinition @'`r`npublic static class Warn { public static int F() { int unused = 1; return 2; } }`r`n'@`r`n"
            [IO.File]::WriteAllText((Join-Path $tmp 'warning.ps1'), $warn)
            $r = Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-Parse.ps1') -Arguments @('-Root', $tmp)
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'warning\.ps1:2: C# CS0219'
        } finally { Remove-TestDataPath $tmp }
    }
}

Describe 'Q4 the private-details scan' {
    BeforeAll {
        $script:Scan = { param($folder, $files) Invoke-InChildPowerShell -File (Join-Path $Tools 'Test-NoPrivateInfo.ps1') -Arguments (@('-Root', $folder, '-Path') + @($files -join ',')) }
    }
    It 'T51-07 a global IPv6 address, a user profile path and a deny-list word in a file name are found' {
        $tmp = New-TestDataPath
        try {
            [IO.File]::WriteAllText((Join-Path $tmp 'a.md'), "server at 2a01:4f8:1:2::5`r`n")   # private-check: allow (a deliberate public test address)
            [IO.File]::WriteAllText((Join-Path $tmp 'b.md'), ('copy to C:\Users\' + "somebody\Desktop`r`n"))
            [IO.File]::WriteAllText((Join-Path $tmp 'notes-forbiddenword.md'), "nothing here`r`n")
            $env:SRRVRR_DENYLIST = 'forbiddenword'
            try { $r = & $Scan $tmp @('a.md', 'b.md', 'notes-forbiddenword.md') } finally { $env:SRRVRR_DENYLIST = $null }
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'a\.md:1: public IPv6'
            $r.Output | Should -Match 'b\.md:1: user profile path'
            $r.Output | Should -Match 'notes-.*: a word from the private deny list in the file name'
        } finally { Remove-TestDataPath $tmp }
    }
    It 'T51-07 documentation and private IPv6 examples and a placeholder profile path pass' {
        $tmp = New-TestDataPath
        try {
            [IO.File]::WriteAllText((Join-Path $tmp 'ok.md'), "fd00::5 fe80::1 2001:db8::7 ::1`r`nC:\Users\<name>\Documents and %USERPROFILE%`r`n")
            $r = & $Scan $tmp @('ok.md')
            $r.ExitCode | Should -Be 0 -Because $r.Output
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

Describe 'T47-25 CI workflow' {
    BeforeAll {
        $script:WorkflowPath = Join-Path $Root '.github\workflows\checks.yml'
        $script:Workflow = if (Test-Path $WorkflowPath) { [IO.File]::ReadAllText($WorkflowPath) } else { '' }
    }
    It 'T47-25 the workflow exists and every step runs in Windows PowerShell 5.1' {
        $Workflow | Should -Not -BeNullOrEmpty
        $Workflow | Should -Match '(?m)^defaults:\s*\r?\n\s+run:\s*\r?\n\s+shell: powershell\s*$'
        $Workflow | Should -Not -Match 'shell:\s*pwsh'
    }
    It 'T47-25 the runner image is pinned and permissions are read-only' {
        $Workflow | Should -Match 'runs-on: windows-2022'
        $Workflow | Should -Not -Match 'windows-latest'
        $Workflow | Should -Match '(?m)^permissions:\s*\r?\n\s+contents: read\s*$'
    }
    It 'T47-25 every action is pinned to a full commit SHA' {
        $uses = @([regex]::Matches($Workflow, 'uses:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
        $uses.Count | Should -BeGreaterThan 0
        $uses | Where-Object { $_ -notmatch '@[0-9a-f]{40}$' } | Should -BeNullOrEmpty
    }
    It 'T47-25 the test job runs tools\Invoke-Checks.ps1 with -CI and runs on pull requests' {
        $Workflow | Should -Match 'tools\\Invoke-Checks\.ps1 -CI'
        $Workflow | Should -Match '(?m)^\s+pull_request:'
    }
}

Describe 'T47-34 changelog' {
    It 'T47-34 CHANGELOG.md has an [Unreleased] section with an entry' {
        $text = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
        $text | Should -Match '(?s)## \[Unreleased\]\s+### \w+\s+- '
    }
}
