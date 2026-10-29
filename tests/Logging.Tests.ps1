# modules\Logging.psm1 and the error hand-offs to it (spec section 4, the crash and error log).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Counters.psm1') -Force
    # A clock the test moves by hand; .Clock is the scriptblock the modules take.
    function New-FakeClock([DateTimeOffset]$Start) {
        $c = @{ Now = $Start }
        $c.Clock = { $c.Now }.GetNewClosure()
        $c
    }
    $script:T0 = [DateTimeOffset]::new(2026, 1, 5, 23, 59, 0, [TimeSpan]::FromHours(-6))
}

Describe 'T48-32 the log line format' {
    It 'T48-32 time, level, source and message on one line, newlines escaped' {
        $line = Format-LogLine -Time $T0 -Level 'ERROR' -Source 'fast-sampler' -Message "first`r`nsecond"
        $line | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d (INFO|WARN|ERROR|FLAG) [a-z-]+: .+$'
        $line | Should -Be '2026-01-05T23:59:00.000-06:00 ERROR fast-sampler: first\nsecond'
    }
}

Describe 'T48-59 exception details' {
    It 'T48-59 type, message, script and line, the script stack and each inner exception' {
        $file = Join-Path (New-TestDataPath) 'thrower.ps1'
        [IO.File]::WriteAllText($file, "function Inner { throw [InvalidOperationException]::new('outer', [IO.IOException]::new('disk said no')) }`r`nInner`r`n")
        try { & $file } catch { $record = $_ }
        $text = Format-SrrException -ErrorRecord $record
        $text | Should -Match 'System\.InvalidOperationException: outer'
        $text | Should -Match 'thrower\.ps1:1'
        $text | Should -Match 'at Inner'
        $text | Should -Match 'inner: System\.IO\.IOException: disk said no'
    }
}

Describe 'T48-60 the error throttle' {
    It 'T48-60 the same error is written once, then once a minute with its repeat count' {
        $c = New-FakeClock $T0
        $t = New-ErrorThrottle -Clock $c.Clock
        $t.ShouldWrite('disk') | Should -Be 0                      # first: written, no repeats
        foreach ($s in 10, 20, 30, 59) { $c.Now = $T0.AddSeconds($s); $t.ShouldWrite('disk') | Should -Be $null }
        $c.Now = $T0.AddSeconds(60)
        $t.ShouldWrite('disk') | Should -Be 4                      # written, "(repeated 4 times)"
    }
    It 'T48-60 two errors throttle separately, and a pending count is handed over on stop' {
        $c = New-FakeClock $T0
        $t = New-ErrorThrottle -Clock $c.Clock
        $t.ShouldWrite('a') | Should -Be 0
        $t.ShouldWrite('b') | Should -Be 0
        $c.Now = $T0.AddSeconds(5)
        $t.ShouldWrite('a') | Should -Be $null
        $t.ShouldWrite('a') | Should -Be $null
        $pending = $t.Flush()
        $pending['a'] | Should -Be 2
        $pending.ContainsKey('b') | Should -BeFalse
    }
}

Describe 'T48-61 the daily file and its cap' {
    It 'T48-61 lines up to the cap, one cap line, flags and the stopped line still written, a new file each day' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        $c = New-FakeClock $T0
        $log = New-DailyLog -Folder $dir -Prefix 'srrvrr' -Extension 'log' -Clock $c.Clock -CapBytes 2048
        $i = 0
        while ((Get-Item (Join-Path $dir 'srrvrr-2026-01-05.log') -ErrorAction SilentlyContinue).Length -lt 2048 -and $i -lt 500) { $log.Write("info line $i " + ('x' * 40), $false); $i++ }
        $log.Write('ERROR after the cap', $false)
        $log.Write('FLAG data drive missing', $true)
        $log.Write('stopped: requested (exit 0)', $true)
        $lines = [IO.File]::ReadAllLines((Join-Path $dir 'srrvrr-2026-01-05.log'))
        @($lines | Where-Object { $_ -match 'daily size cap reached' }).Count | Should -Be 1
        $lines | Should -Not -Contain 'ERROR after the cap'
        $lines[-2] | Should -Be 'FLAG data drive missing'
        $lines[-1] | Should -Be 'stopped: requested (exit 0)'
        $c.Now = $T0.AddMinutes(2)                                  # past local midnight
        $log.Write('a new day', $false)
        [IO.File]::ReadAllLines((Join-Path $dir 'srrvrr-2026-01-06.log')) | Should -Be @('a new day')
    }
    It 'T48-61 the cap counts bytes, not characters, and defaults to 20 MB' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        $c = New-FakeClock $T0
        $log = New-DailyLog -Folder $dir -Prefix 'srrvrr' -Extension 'log' -Clock $c.Clock -CapBytes 64
        $log.Write(([string][char]0x00E9) * 40, $false)              # 40 characters, 80 bytes in UTF-8
        $log.Write('next', $false)
        [IO.File]::ReadAllLines((Join-Path $dir 'srrvrr-2026-01-05.log'))[-1] | Should -Match 'daily size cap reached'
        (New-DailyLog -Folder $dir -Prefix 'x' -Extension 'log' -Clock $c.Clock).CapBytes | Should -Be 20MB
    }
}

Describe 'T48-31 network tracer errors' {
    It 'T48-31 one line per change in the error count or the thread' {
        $ok = @{ ErrorText = ''; ErrorType = ''; ErrorCount = 0; Alive = $true }
        Get-TracerLogEntry -Current $ok -LastLogged $ok | Should -BeNullOrEmpty
        $one = @{ ErrorText = 'bad record'; ErrorType = 'System.ArgumentException'; ErrorCount = 1; Alive = $true }
        $e = Get-TracerLogEntry -Current $one -LastLogged $ok
        $e.Level | Should -Be 'ERROR'
        $e.Message | Should -Match 'System\.ArgumentException: bad record'
        Get-TracerLogEntry -Current $one -LastLogged $one | Should -BeNullOrEmpty
        $four = @{ ErrorText = 'bad record'; ErrorType = 'System.ArgumentException'; ErrorCount = 4; Alive = $true }
        (Get-TracerLogEntry -Current $four -LastLogged $one).Message | Should -Match '3 more'
        $dead = @{ ErrorText = 'bad record'; ErrorType = 'System.ArgumentException'; ErrorCount = 4; Alive = $false }
        (Get-TracerLogEntry -Current $dead -LastLogged $four).Message | Should -Match 'network tracer thread stopped'
        Get-TracerLogEntry -Current $dead -LastLogged $dead | Should -BeNullOrEmpty
    }
}

Describe 'T48-62 the worker watcher' {
    BeforeAll {
        function New-FakeWorker([string]$Name, [string]$State, [string]$Reason) {
            $info = [pscustomobject]@{ State = $State; Reason = $(if ($Reason) { [Exception]::new($Reason) } else { $null }) }
            $streams = [pscustomobject]@{ Error = @($(if ($Reason) { 'the loop threw' })) }
            @{ Name = $Name; PowerShell = [pscustomobject]@{ InvocationStateInfo = $info; Streams = $streams } }
        }
    }
    It 'T48-62 running workers are healthy' {
        (Test-WorkerHealth -Workers @((New-FakeWorker 'fast sampler' 'Running'), (New-FakeWorker 'slow sampler' 'Running'))).Healthy | Should -BeTrue
    }
    It 'T48-62 a failed worker gives its reason and errors, and says to exit with a crash code' {
        $h = Test-WorkerHealth -Workers @((New-FakeWorker 'fast sampler' 'Running'), (New-FakeWorker 'slow sampler' 'Failed' 'counter category vanished'))
        $h.Healthy | Should -BeFalse
        $h.Reason | Should -Match 'slow sampler failed: counter category vanished'
        $h.Errors | Should -Contain 'the loop threw'
        $h.ExitCode | Should -Be 1
    }
    It 'T48-62 a worker that ended is a failure too' {
        $h = Test-WorkerHealth -Workers @((New-FakeWorker 'fast sampler' 'Completed'))
        $h.Healthy | Should -BeFalse
        $h.Reason | Should -Match 'fast sampler ended'
    }
}

Describe 'T48-29 the network tracer without administrator' -Tag 'Integration' {
    It 'T48-29 Start() fails cleanly: "needs administrator", no error counted, the thread not alive, nothing drained' {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) { Set-ItResult -Skipped -Because 'this case needs a process without administrator (the elevated case is T48-30)'; return }
        $probe = Join-Path (New-TestDataPath) 'probe.ps1'
        $script = @'
param($Entry)
$ast = [Management.Automation.Language.Parser]::ParseFile($Entry, [ref]$null, [ref]$null)
$src = ($ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'class ProcessNetTrace' }, $true) | Select-Object -First 1).Value
Add-Type -TypeDefinition $src
$started = [ProcessNetTrace]::Start()
[pscustomobject]@{ Started = $started; Error = [ProcessNetTrace]::Error; Count = [ProcessNetTrace]::ErrorCount; Alive = [ProcessNetTrace]::Alive; Drained = [ProcessNetTrace]::Drain().Count } | ConvertTo-Json -Compress
'@
        [IO.File]::WriteAllText($probe, $script)
        $r = Invoke-InChildPowerShell -File $probe -Arguments @((Join-Path (Get-RepoRoot) 'SRRVRR.ps1'))
        $j = ($r.Output.Trim() -split "`n")[-1] | ConvertFrom-Json
        $j.Started | Should -BeFalse
        # 183 (already exists): a live SRRVRR's trace session has the same name until each copy gets its own (Task 12).
        $j.Error | Should -Match '^(needs administrator|StartTrace error 183)$'
        $j.Count | Should -Be 0
        $j.Alive | Should -BeFalse
        $j.Drained | Should -Be 0
    }
}

Describe 'T48-63 the watcher with a real worker' -Tag 'Integration' {
    It 'T48-63 a runspace whose loop throws is reported within 2 seconds' {
        $ps = [powershell]::Create().AddScript({ $i = 0; while ($true) { $i++; if ($i -gt 2) { throw 'tick 3 broke' }; Start-Sleep -Milliseconds 200 } })
        $null = $ps.BeginInvoke()
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew(); $h = $null
            while ($sw.Elapsed.TotalSeconds -lt 2) { $h = Test-WorkerHealth -Workers @(@{ Name = 'fast sampler'; PowerShell = $ps }); if (-not $h.Healthy) { break }; Start-Sleep -Milliseconds 100 }
            $h.Healthy | Should -BeFalse
            $h.Reason | Should -Match 'tick 3 broke'
            $h.ExitCode | Should -Be 1
        } finally { $ps.Dispose() }
    }
}
