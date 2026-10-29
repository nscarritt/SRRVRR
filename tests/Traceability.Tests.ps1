# T47-33: the test plan's traceability table and the test files agree.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $plan = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'docs\plans\2026-10-29-srrvrr-core-test-plan.md'))
    $section6 = [regex]::Match($plan, '(?s)## 6\..*?(?=\r?\n## 7\.)').Value
    $section7 = [regex]::Match($plan, '(?s)## 7\..*?(?=\r?\n## 8\.)').Value
    $script:Defined = @([regex]::Matches($section6, '(?m)^\| (T\d\d-\d\d) \|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    # The table cites single ids and ranges ("T48-01 to T48-08").
    $traced = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($section7, '(T(\d\d)-(\d\d))(?: to T(\d\d)-(\d\d))?')) {
        if ($m.Groups[4].Success) {
            foreach ($n in [int]$m.Groups[3].Value..[int]$m.Groups[5].Value) { $traced.Add(('T{0}-{1:00}' -f $m.Groups[2].Value, $n)) }
        } else { $traced.Add($m.Groups[1].Value) }
    }
    $script:Traced = @($traced | Sort-Object -Unique)
    $script:ItNames = @(Get-ChildItem -Path $PSScriptRoot -Filter '*.Tests.ps1' -Recurse | ForEach-Object {
        (Get-ScriptAst $_.FullName).FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'It' }, $true) |
            ForEach-Object { $_.CommandElements[1].Extent.Text.Trim("'", '"') }
    })
}

Describe 'T47-33 traceability' {
    It 'T47-33 every id in the traceability table is defined in section 6' {
        @($Traced | Where-Object { $Defined -notcontains $_ }) | Should -BeNullOrEmpty
    }
    It 'T47-33 every id defined in section 6 appears in the traceability table' {
        @($Defined | Where-Object { $Traced -notcontains $_ }) | Should -BeNullOrEmpty
    }
    It 'T47-33 every It starts with a defined test id' {
        $bad = @($ItNames | Where-Object { $_ -notmatch '^(T\d\d-\d\d)\b' -or $Defined -notcontains $Matches[1] })
        $bad | Should -BeNullOrEmpty
    }
}
