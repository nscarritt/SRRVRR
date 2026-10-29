# tools\SRRVRR.Tools.psm1, tools\Measure-SRRVRR.ps1 and tools\New-TestBuild.ps1.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    Import-Module (Join-Path $Root 'tools\SRRVRR.Tools.psm1') -Force
}

Describe 'T47-26 shared tool code' {
    It 'T47-26 percentiles of known lists' {
        Get-Percentile -Values (1..100) -P 50 | Should -Be 50
        Get-Percentile -Values (1..100) -P 95 | Should -Be 95
        Get-Percentile -Values @(7) -P 95 | Should -Be 7
        Get-Percentile -Values @(30, 10, 20) -P 50 | Should -Be 20
    }
    It 'T47-26 a measurement is under, equal to or over its budget' {
        Compare-Budget -Value 0.4 -Max 1 | Should -Be 'under'
        Compare-Budget -Value 1 -Max 1 | Should -Be 'equal'
        Compare-Budget -Value 1.2 -Max 1 | Should -Be 'over'
    }
    It 'T47-26 of two copies in two folders only the one in -Folder is picked' {
        $procs = @(
            [pscustomobject]@{ ProcessId = 10; CommandLine = 'powershell.exe -NoProfile -File "C:\Live\SRRVRR.ps1"' },
            [pscustomobject]@{ ProcessId = 11; CommandLine = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Test Copy\SRRVRR.ps1" -Port 8091' },
            [pscustomobject]@{ ProcessId = 12; CommandLine = 'powershell.exe -File "C:\Test Copy\SRRVRR.ps1" -Stop' },
            [pscustomobject]@{ ProcessId = 13; CommandLine = $null }
        )
        @(Find-SRRVRRProcess -Folder 'C:\Test Copy' -Processes $procs | ForEach-Object ProcessId) | Should -Be @(11)
        @(Find-SRRVRRProcess -Folder 'c:\live\' -Processes $procs | ForEach-Object ProcessId) | Should -Be @(10)
    }
}

Describe 'T47-27 Measure-SRRVRR.ps1' -Tag 'Integration' {
    BeforeAll {
        $web = Join-Path (New-TestDataPath) 'web'
        Copy-Item -Recurse (Join-Path $Root 'web') $web
        $script:Ctx = @{
            State = @{ ready = $true; cpu = 1; tickMs = 40 }; WebRoot = $web; Identity = @{ Names = @(); Addresses = @() }
            BootTime = [DateTimeOffset]::Now; Clock = { [DateTimeOffset]::Now }; LogError = { }
            Errors = (New-Object System.Collections.Generic.List[string]); Requests = (New-Object System.Collections.Generic.List[string])
        }
        $script:Server = Start-TestServer -Context $Ctx
    }
    AfterAll { Stop-TestServer $Server }

    It 'T47-27 every budget row is in the table, -Informational exits 0, and only GETs are made' {
        $out = Join-Path (New-TestDataPath) 'measure.md'
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\Measure-SRRVRR.ps1') -Arguments @('-BaseUrl', "http://localhost:$($Server.Port)", '-Folder', (Join-Path $env:TEMP 'no-such-copy'), '-Seconds', '3', '-Informational', '-OutFile', $out) -TimeoutSeconds 120
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $table = [IO.File]::ReadAllText($out)
        foreach ($row in 'CPU', 'Memory', '/stats p95', '/stats size', 'Page load', 'Tick median') { $table | Should -Match ([regex]::Escape("| $row")) }
        @($Ctx.Requests | Where-Object { $_ -notmatch '^GET ' }) | Should -BeNullOrEmpty
        $Ctx.Requests.Count | Should -BeGreaterThan 10
    }
    It 'T47-27 a copy that isn''t found fails the run unless -Informational' {
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\Measure-SRRVRR.ps1') -Arguments @('-BaseUrl', "http://localhost:$($Server.Port)", '-Folder', (Join-Path $env:TEMP 'no-such-copy'), '-Seconds', '2') -TimeoutSeconds 120
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'no SRRVRR found'
    }
    It 'T47-27 failed requests are counted as failures, not timed as successes' {
        $port = Get-FreePort
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\Measure-SRRVRR.ps1') -Arguments @('-BaseUrl', "http://localhost:$port", '-Folder', (Join-Path $env:TEMP 'no-such-copy'), '-Seconds', '2', '-Informational') -TimeoutSeconds 120
        $r.Output | Should -Match '\| Failed requests \| [1-9]'
        $r.Output | Should -Not -Match '\| /stats p95 \| [0-9]'
    }
}

Describe 'New-TestBuild.ps1 refusals' -Tag 'Integration' {
    It 'T48-49 refuses a destination inside the live folder and a non-empty folder without -Force' {
        $base = New-TestDataPath
        $live = Join-Path $base 'live'; New-Item -ItemType Directory $live | Out-Null
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', (Join-Path $live 'test'), '-LiveFolder', $live)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'inside the live'
        $busy = Join-Path $base 'busy'; New-Item -ItemType Directory $busy | Out-Null; Set-Content (Join-Path $busy 'x.txt') 'x'
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $busy)
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'not empty'
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $busy, '-Force')
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match 'TESTBUILD\.txt'
        Remove-TestDataPath $base
    }
    It 'T48-50 builds only runtime files, writes TESTBUILD.txt and a test config, never the live config' {
        $dest = Join-Path (New-TestDataPath) 'copy'
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $dest, '-Port', '8093')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path (Join-Path $dest 'SRRVRR.ps1') | Should -BeTrue
        Test-Path (Join-Path $dest 'modules\Counters.psm1') | Should -BeTrue
        Test-Path (Join-Path $dest 'web\index.html') | Should -BeTrue
        Test-Path (Join-Path $dest 'tests') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $dest 'TESTBUILD.txt')) | Should -Match 'commit [0-9a-f]{40}'
        (Import-PowerShellDataFile (Join-Path $dest 'SRRVRR.config.psd1')).Port | Should -Be 8093
    }
}
