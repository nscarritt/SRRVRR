# README.md and the docs agree with the code: the boot section, the update steps, the settings table, links, the
# changelog (story #51, test plan section 6.5).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    $script:Settings = Import-Module (Join-Path $Root 'modules\Settings.psm1') -Force -PassThru
    $script:Readme = [IO.File]::ReadAllText((Join-Path $Root 'README.md'))
    # The text of one "## Heading" section, up to the next heading of the same or a higher level.
    function Get-Section([string]$Text, [string]$Heading) {
        $m = [regex]::Match($Text, '(?ms)^(#+) ' + [regex]::Escape($Heading) + '\s*$(.*?)(?=^#{1,' + 2 + '} |\z)')
        if (-not $m.Success) { throw "README has no section '$Heading'" }
        $m.Groups[2].Value
    }
    $script:Boot = Get-Section $Readme 'Running SRRVRR at boot'
    # What a release ships: git archive honours export-ignore in .gitattributes.
    $ignored = @(Get-Content (Join-Path $Root '.gitattributes') | Where-Object { $_ -match '^(\S+?)/?\s+export-ignore' } | ForEach-Object { $Matches[1] })
    $script:Shipped = @(& git -C $Root ls-tree --name-only HEAD | Where-Object { $ignored -notcontains $_ })
    # A heading's anchor as GitHub makes it.
    function ConvertTo-Anchor([string]$Heading) { (($Heading.ToLowerInvariant() -replace '[^\w\- ]', '') -replace ' ', '-') }
}

Describe 'T51-01 the exit-code table' {
    It 'T51-01 lists the codes the code produces, restarting only after a crash, up to 3 times in 10 minutes' {
        $rows = @{}
        foreach ($m in [regex]::Matches($Boot, '(?m)^\| *(`?\d+`?|Anything else) *\| *([^|]+)\| *([^|]+)\|')) {
            $rows[$m.Groups[1].Value.Trim('`', ' ')] = $m.Groups[3].Value.Trim()
        }
        @($rows.Keys | Sort-Object) | Should -Be @('0', '2', '3', 'Anything else')
        $settingsError = & $Settings { New-SettingsError 'x' }
        $dataFolder = Import-Module (Join-Path $Root 'modules\DataFolder.psm1') -Force -PassThru
        $refusal = & $dataFolder { New-Refusal 'x' }
        Get-SrrExitCode $settingsError | Should -Be 2
        Get-SrrExitCode $refusal | Should -Be 3
        Get-SrrExitCode ([InvalidOperationException]::new('x')) | Should -Be 1
        foreach ($k in '0', '2', '3') { $rows[$k] | Should -Match '^No' -Because "exit $k must not be restarted" }
        $rows['Anything else'] | Should -Match '^Yes'
        $rows['Anything else'] | Should -Match '3 times in 10 minutes'
    }
}

Describe 'T51-02 the update steps' {
    It 'T51-02 say to replace the code folders and name every shipped file and folder, and nothing else' {
        $para = [regex]::Match($Readme, '(?s)When updating,.*?(?:\r?\n\r?\n)').Value
        $para | Should -Match 'modules'
        $named = @([regex]::Matches($para, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $kept = @('SRRVRR.config.psd1', 'state', 'logs', 'lib')
        @($Shipped | Where-Object { $named -notcontains $_ }) | Should -BeNullOrEmpty -Because 'every shipped file must be named'
        @($named | Where-Object { $Shipped -notcontains $_ -and $kept -notcontains $_ }) | Should -BeNullOrEmpty -Because 'nothing that isn''t shipped may be named'
        foreach ($k in $kept) { $named | Should -Contain $k -Because "the steps must say $k stays" }
    }
}

Describe 'T51-03 stopping SRRVRR from a launcher' {
    It 'T51-03 names -Stop and Stop SRRVRR.bat, the 10-second wait, and state\stop-requested with its 60-second rule' {
        $Boot | Should -Match '-Stop'
        $Boot | Should -Match 'Stop SRRVRR\.bat'
        $Boot | Should -Match '10 seconds'
        $Boot | Should -Match 'state\\stop-requested'
        $Boot | Should -Match '60 seconds'
    }
}

Describe 'T51-04 checking files before they load' {
    It 'T51-04 a hash-checking launcher must cover modules, web and the sensor DLLs; its release first; -ExecutionPolicy Bypass' {
        $Boot | Should -Match '`modules\\?`'
        $Boot | Should -Match '`web\\?`'
        $Boot | Should -Match '\.dll'
        $Boot | Should -Match '`SRRVRR\.ps1`'
        $Boot | Should -Match 'before'
        $Boot | Should -Match '-ExecutionPolicy Bypass'
        $Boot | Should -Match 'downloaded'
    }
}

Describe 'T51-05 permissions on the data folders' {
    It 'T51-05 elevated, only SYSTEM and Administrators can write state and logs; readers keep read' {
        $Readme | Should -Match 'only SYSTEM and Administrators can change `state` and\s+`logs`; everyone who could read them before still can'
    }
}

Describe 'T51-06 the settings table matches the code' {
    It 'T51-06 each new setting is in the table with the code''s default and range' {
        $defaults = Get-SrrDefaultSettings
        $rows = @{}
        foreach ($m in [regex]::Matches($Readme, '(?m)^\| `(\w+)` \| `([^`]*)` \| (.*)\|\s*$')) { $rows[$m.Groups[1].Value] = @{ Default = $m.Groups[2].Value; Text = $m.Groups[3].Value } }
        $rows['DataPath'].Default | Should -Be "'$($defaults.DataPath)'"
        foreach ($k in 'LogRetentionDays', 'MaintenanceHours', 'MaintenanceMaxHours') { $rows[$k].Default | Should -Be ([string]$defaults[$k]) -Because $k }
        # The ranges, as the code's own error messages state them.
        $bad = @{ LogRetentionDays = 6; MaintenanceMaxHours = 25; MaintenanceHours = 0.1 }
        foreach ($k in $bad.Keys) {
            $s = Get-SrrDefaultSettings; $s[$k] = $bad[$k]
            $message = try { Test-SrrSettings $s | Out-Null; '' } catch { $_.Exception.Message }
            $range = [regex]::Match($message, '(\d+(\.\d+)?) (to|up to) (\d+|MaintenanceMaxHours)').Value
            $range | Should -Not -BeNullOrEmpty -Because "$k's error message names its range"
            $rows[$k].Text | Should -Match ([regex]::Escape(($range -replace 'MaintenanceMaxHours', '`MaintenanceMaxHours`'))) -Because $k
        }
    }
}

Describe 'T65-10 the drive space settings are documented' {
    It 'T65-10 the README table, the example config and the defaults agree' {
        $defaults = Get-SrrDefaultSettings
        $rows = @{}
        foreach ($m in [regex]::Matches($Readme, '(?m)^\| `(\w+)` \| `([^`]*)` \| (.*)\|\s*$')) { $rows[$m.Groups[1].Value] = @{ Default = $m.Groups[2].Value; Text = $m.Groups[3].Value } }
        $example = Import-PowerShellDataFile -LiteralPath (Join-Path $Root 'SRRVRR.config.example.psd1')
        foreach ($k in 'DriveWarnPercent', 'DriveFullPercent') {
            $rows[$k].Default | Should -Be ([string]$defaults[$k]) -Because "$k in the README"
            $example[$k] | Should -Be $defaults[$k] -Because "$k in the example config"
            $s = Get-SrrDefaultSettings; $s[$k] = 49
            $message = try { Test-SrrSettings $s | Out-Null; '' } catch { $_.Exception.Message }
            $range = [regex]::Match($message, '(\d+) to (\d+)').Value
            $range | Should -Be '50 to 99' -Because "$k's error message names its range"
            $rows[$k].Text | Should -Match ([regex]::Escape($range)) -Because "$k in the README"
        }
    }
}
Describe 'T51-08 links in the docs' {
    It 'T51-08 every relative link in README.md and docs\*.md reaches a file, and every #anchor a heading' {
        $files = @(Get-Item (Join-Path $Root 'README.md')) + @(Get-ChildItem (Join-Path $Root 'docs') -Filter '*.md' -Recurse)
        $broken = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) {
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, '\]\(([^)\s]+)\)')) {
                $link = $m.Groups[1].Value
                if ($link -match '^(https?|mailto):') { continue }
                $path, $anchor = $link -split '#', 2
                $target = if ($path) { [IO.Path]::GetFullPath([IO.Path]::Combine($f.DirectoryName, $path)) } else { $f.FullName }
                if (-not (Test-Path -LiteralPath $target)) { $broken.Add("$($f.Name): $link (no file)"); continue }
                if ($anchor -and $target -like '*.md') {
                    $anchors = @([regex]::Matches([IO.File]::ReadAllText($target), '(?m)^#+ (.+?)\s*$') | ForEach-Object { ConvertTo-Anchor $_.Groups[1].Value })
                    if ($anchors -notcontains $anchor) { $broken.Add("$($f.Name): $link (no heading)") }
                }
            }
        }
        $broken | Should -BeNullOrEmpty
    }
}

Describe 'T51-09 the changelog' {
    It 'T51-09 #47 to #51 each have an entry, under [Unreleased] or under 0.7.0 once released' {
        $changelog = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
        $section = { param($name) [regex]::Match($changelog, '(?ms)^## \[' + [regex]::Escape($name) + '\][^\n]*\n(.*?)(?=^## \[|\z)').Groups[1].Value }
        $text = (& $section 'Unreleased') + (& $section '0.7.0')
        foreach ($n in 47..51) { $text | Should -Match "issues/$n\)" -Because "#$n needs an entry" }
    }
    It 'T51-09 the README''s version is the newest released section, and it has its compare link' {
        $changelog = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'))
        $version = [regex]::Match($Readme, 'Current version: \*\*([\d.]+)\*\*').Groups[1].Value
        $newest = [regex]::Match($changelog, '(?m)^## \[(\d+\.\d+\.\d+)\]').Groups[1].Value
        $version | Should -Be $newest
        $changelog | Should -Match ('(?m)^\[' + [regex]::Escape($newest) + '\]: https://github\.com/nscarritt/SRRVRR/')
    }
}

#region 90 Roles and the host name (#90)
Describe 'T90-14 Role and DisplayName are documented' {
    BeforeAll {
        $script:Rows = @{}
        foreach ($m in [regex]::Matches($Readme, '(?m)^\| `(\w+)` \| `([^`]*)` \| (.*)\|\s*$')) { $Rows[$m.Groups[1].Value] = @{ Default = $m.Groups[2].Value; Text = $m.Groups[3].Value } }
        $examplePath = Join-Path $Root 'SRRVRR.config.example.psd1'
        $script:Example = Import-PowerShellDataFile -LiteralPath $examplePath
        $script:ExampleLines = @([IO.File]::ReadAllLines($examplePath))
        # The comment lines right above "<Name> =" in the example config (empty when the setting isn't there).
        function Get-ExampleComment([string]$Name) {
            $at = -1
            for ($i = 0; $i -lt $ExampleLines.Count; $i++) { if ($ExampleLines[$i] -match ('^\s*' + $Name + '\s*=')) { $at = $i; break } }
            if ($at -lt 0) { return '' }
            $comment = New-Object System.Collections.Generic.List[string]
            for ($i = $at - 1; $i -ge 0 -and $ExampleLines[$i] -match '^\s*#'; $i--) { $comment.Insert(0, $ExampleLines[$i]) }
            $comment -join "`n"
        }
        # The message Test-SrrSettings throws for one setting's value.
        function Get-SettingError([string]$Name, $Value) {
            $s = Get-SrrDefaultSettings; $s[$Name] = $Value
            try { Test-SrrSettings $s | Out-Null; '' } catch { $_.Exception.Message }
        }
    }
    It 'T90-14 Role: the default Server in the code, the README table and the example config, and the values Server and Workstation in all three' {
        $defaults = Get-SrrDefaultSettings
        $defaults.Role | Should -BeExactly 'Server'
        $Rows.ContainsKey('Role') | Should -BeTrue -Because 'the README settings table has a Role row'
        $Rows['Role'].Default | Should -BeExactly "'$($defaults.Role)'"
        $Example.Role | Should -BeExactly $defaults.Role -Because 'the example config sets Role to its default'
        $comment = Get-ExampleComment 'Role'
        $message = Get-SettingError 'Role' 'Desktop'
        foreach ($v in 'Server', 'Workstation') {
            Get-SettingError 'Role' $v | Should -BeNullOrEmpty -Because "the code accepts $v"
            $message | Should -Match $v -Because "the code's error names $v"
            $Rows['Role'].Text | Should -Match "'$v'" -Because "the README names '$v'"
            $comment | Should -Match "'$v'" -Because "the example config's comment names '$v'"
        }
    }
    It 'T90-14 DisplayName: the default empty in the code, the README table and the example config, and its rule in all three' {
        $defaults = Get-SrrDefaultSettings
        $defaults.DisplayName | Should -BeExactly ''
        $Rows.ContainsKey('DisplayName') | Should -BeTrue -Because 'the README settings table has a DisplayName row'
        $Rows['DisplayName'].Default | Should -BeExactly "'$($defaults.DisplayName)'"
        $Example.ContainsKey('DisplayName') | Should -BeTrue -Because 'the example config has DisplayName'
        $Example.DisplayName | Should -BeExactly $defaults.DisplayName -Because 'the example config sets DisplayName to its default'
        # The rule, as the code's own error message states it.
        $range = [regex]::Match((Get-SettingError 'DisplayName' ('a' * 33)), '\d+ to \d+ characters').Value
        $range | Should -Be '1 to 32 characters' -Because "DisplayName's error message names its length"
        $Rows['DisplayName'].Text | Should -Match ([regex]::Escape($range)) -Because 'the README states the rule'
        Get-ExampleComment 'DisplayName' | Should -Match ([regex]::Escape($range)) -Because "the example config's comment states the rule"
    }
    It 'T90-14 the README has "Running on a workstation", with Role = ''Workstation'' and answering No to the administrator prompt' {
        $section = Get-Section $Readme 'Running on a workstation'
        $section | Should -Match ([regex]::Escape("Role = 'Workstation'"))
        $section | Should -Match '(?i)answer(ing)?\s+(\*\*)?No\b'
        $section | Should -Match '(?i)administrator'
    }
}
#endregion 90
