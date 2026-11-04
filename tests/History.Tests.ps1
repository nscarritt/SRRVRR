# modules\History.psm1: 15 minutes of graph history kept on the server (spec section 2).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
    $script:T0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
    $script:T0Ms = $T0.ToUnixTimeMilliseconds()
    function Get-Values($Copy, [string]$Name) { $Copy.Lines[$Name] }
    # A history file as Save-History writes it, with its newest reading at $Newest.
    function New-HistoryFile([string]$StateDir, [DateTimeOffset]$Newest, [int]$Length = 900, [object]$Version = 1, [string[]]$Names = @('cpu', 'mem', 'gpu', 'rx', 'tx')) {
        $lines = ($Names | ForEach-Object { '"' + $_ + '":[' + ((1..$Length) -join ',') + ']' }) -join ','
        $json = '{"version":' + $Version + ',"newestMs":' + $Newest.ToUnixTimeMilliseconds() + ',"stepMs":1000,"lines":{' + $lines + '}}'
        [IO.File]::WriteAllText((Join-Path $StateDir 'history.json'), $json)
    }
}

Describe 'T49-01 the ring' {
    It 'T49-01 keeps the last readings, oldest first, with the newest reading''s time' {
        $s = New-HistoryStore -Slots 5 -Lines @('cpu')
        for ($i = 1; $i -le 7; $i++) { $s.Append('cpu', $i, $T0Ms + $i * 1000) }
        $c = $s.Copy()
        Get-Values $c 'cpu' | Should -Be @(3, 4, 5, 6, 7)
        $c.NewestMs | Should -Be ($T0Ms + 7000)
        $c.StepMs | Should -Be 1000
    }
    It 'T49-01 defaults to 900 slots and the cpu, mem, gpu, rx and tx lines' {
        $s = New-HistoryStore
        $s.Slots | Should -Be 900
        @($s.Names) | Should -Be @('cpu', 'mem', 'gpu', 'rx', 'tx')
        (Get-Values $s.Copy() 'tx').Count | Should -Be 900
    }
}

Describe 'T49-02 missed and repeated seconds' {
    It 'T49-02 missed seconds are missing; two readings in one second: the later wins' {
        $s = New-HistoryStore -Slots 6 -Lines @('cpu')
        $s.Append('cpu', 1, $T0Ms); $s.Append('cpu', 2, $T0Ms + 1000); $s.Append('cpu', 5, $T0Ms + 4000)
        $s.Append('cpu', 6, $T0Ms + 5000); $s.Append('cpu', 7, $T0Ms + 5400)
        $v = Get-Values $s.Copy() 'cpu'
        $v[0..1] | Should -Be @(1, 2)
        [double]::IsNaN($v[2]) | Should -BeTrue
        [double]::IsNaN($v[3]) | Should -BeTrue
        $v[4..5] | Should -Be @(5, 7)
        (ConvertTo-HistoryJson -Copy $s.Copy()) | Should -Match '"cpu":\[1,2,null,null,5,7\]'
    }
}

Describe 'T49-03 appends and copies from two runspaces' {
    It 'T49-03 never throws, and every copy is full and in time order' {
        $s = New-HistoryStore -Lines @('cpu')
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({ param($s, $t) for ($i = 1; $i -le 10000; $i++) { $s.Append('cpu', $i, $t + $i * 1000) } }).AddArgument($s).AddArgument($T0Ms)
        $h = $ps.BeginInvoke()
        $bad = 0
        while (-not $h.IsCompleted) {
            $v = Get-Values $s.Copy() 'cpu'
            if ($v.Count -ne 900) { $bad++ }
            $nums = @($v | Where-Object { -not [double]::IsNaN($_) })
            for ($i = 1; $i -lt $nums.Count; $i++) { if ($nums[$i] -le $nums[$i - 1]) { $bad++; break } }
        }
        $ps.EndInvoke($h); $ps.HadErrors | Should -BeFalse; $ps.Dispose()
        $bad | Should -Be 0
        (Get-Values $s.Copy() 'cpu')[-1] | Should -Be 10000
    }
}

Describe 'T49-04 numbers only' {
    It 'T49-04 a string, null, a hashtable or infinity is stored as missing' {
        $s = New-HistoryStore -Slots 4 -Lines @('cpu')
        $s.Append('cpu', 'Plex', $T0Ms); $s.Append('cpu', $null, $T0Ms + 1000)
        $s.Append('cpu', @{ a = 1 }, $T0Ms + 2000); $s.Append('cpu', [double]::PositiveInfinity, $T0Ms + 3000)
        (ConvertTo-HistoryJson -Copy $s.Copy()) | Should -Match '"cpu":\[null,null,null,null\]'
    }
}

Describe 'T49-05 lines registered by name' {
    It 'T49-05 a registered line is kept like the built-in ones; registering twice is a no-op; an unknown name throws' {
        $s = New-HistoryStore -Slots 3
        $s.Register('test-line'); $s.Register('test-line')
        @($s.Names | Where-Object { $_ -eq 'test-line' }).Count | Should -Be 1
        $s.Append('test-line', 4, $T0Ms)
        (Get-Values $s.Copy() 'test-line')[-1] | Should -Be 4
        { $s.Append('nope', 1, $T0Ms) } | Should -Throw '*not registered*'
    }
}

Describe 'T49-06 the JSON writer' {
    It 'T49-06 parses, rounds to 3 decimals, writes NaN as null and always uses a decimal point' {
        $s = New-HistoryStore -Slots 6 -Lines @('cpu')
        $vals = @([double]::NaN, -0.0, 0.0000004, 1.23456, 12345678901234.5678, -2.5)
        for ($i = 0; $i -lt 6; $i++) { $s.Append('cpu', $vals[$i], $T0Ms + $i * 1000) }
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'
            $json = ConvertTo-HistoryJson -Copy $s.Copy()
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
        $json | Should -Match '"cpu":\[null,0,0,1\.235,12345678901234\.568,-2\.5\]'
        $o = $json | ConvertFrom-Json
        $o.version | Should -Be 1
        $o.newestMs | Should -Be ($T0Ms + 5000)
        $o.stepMs | Should -Be 1000
    }
}

Describe 'T49-07 the JSON writer''s speed' {
    It 'T49-07 5 lines x 900 values: fast, smaller than 150 KB, and quicker than ConvertTo-Json' {
        $s = New-HistoryStore
        $r = New-Object Random 7
        for ($i = 0; $i -lt 900; $i++) { foreach ($n in $s.Names) { $s.Append($n, $r.NextDouble() * 1e9, $T0Ms + $i * 1000) } }
        $c = $s.Copy()
        $times = foreach ($i in 1..20) { (Measure-Command { $null = ConvertTo-HistoryJson -Copy $c }).TotalMilliseconds }
        $median = ($times | Sort-Object)[10]
        $ctj = (Measure-Command { $null = @{ version = 1; lines = $c.Lines } | ConvertTo-Json -Depth 3 -Compress }).TotalMilliseconds
        Write-Host ("    T49-07: writer median {0:N1} ms, ConvertTo-Json {1:N1} ms" -f $median, $ctj)
        (ConvertTo-HistoryJson -Copy $c).Length | Should -BeLessThan 150KB
        $median | Should -BeLessThan $ctj
    }
}

Describe 'T49-08 to T49-10 saving' {
    BeforeEach { $script:StateDir = Join-Path (New-TestDataPath) 'state' }
    It 'T49-08 writes a .tmp then moves it, and replaces an existing file, with nothing left over' {
        $s = New-HistoryStore -Slots 3 -Lines @('cpu'); $s.Append('cpu', 1, $T0Ms)
        (Save-History -Store $s -StatePath $StateDir).Error | Should -BeNullOrEmpty
        $s.Append('cpu', 2, $T0Ms + 1000)
        (Save-History -Store $s -StatePath $StateDir).Ok | Should -BeTrue
        Test-Path (Join-Path $StateDir 'history.json.tmp') | Should -BeFalse
        $o = [IO.File]::ReadAllText((Join-Path $StateDir 'history.json')) | ConvertFrom-Json
        $o.version | Should -Be 1; $o.stepMs | Should -Be 1000; $o.newestMs | Should -Be ($T0Ms + 1000)
        @($o.lines.cpu)[-2..-1] | Should -Be @(1, 2)
    }
    It 'T49-09 a partial .tmp from a crash: the good file loads and the next save succeeds' {
        New-HistoryFile $StateDir $T0
        [IO.File]::WriteAllText((Join-Path $StateDir 'history.json.tmp'), '{"version":1,"newe')
        $s = New-HistoryStore
        (Import-History -StatePath $StateDir -Store $s -Now $T0.AddMinutes(1)).Loaded | Should -BeTrue
        (Save-History -Store $s -StatePath $StateDir).Ok | Should -BeTrue
        Test-Path (Join-Path $StateDir 'history.json.tmp') | Should -BeFalse
    }
    It 'T49-10 a locked file or a missing folder: a failure result with a reason, no exception' {
        $s = New-HistoryStore -Slots 3 -Lines @('cpu'); $s.Append('cpu', 1, $T0Ms)
        (Save-History -Store $s -StatePath $StateDir).Ok | Should -BeTrue
        $lock = [IO.File]::Open((Join-Path $StateDir 'history.json'), 'Open', 'Read', 'None')
        try {
            $r = Save-History -Store $s -StatePath $StateDir
            $r.Ok | Should -BeFalse
            $r.Error | Should -Not -BeNullOrEmpty
        } finally { $lock.Dispose() }
        (Save-History -Store $s -StatePath (Join-Path $StateDir 'gone')).Ok | Should -BeFalse
        (Save-History -Store $s -StatePath $StateDir).Ok | Should -BeTrue   # tried again on schedule, and works
    }
}

Describe 'T49-11 to T49-16 loading' {
    BeforeEach { $script:StateDir = Join-Path (New-TestDataPath) 'state'; $script:Store = New-HistoryStore }
    It 'T49-11 <Name>' -ForEach @(
        @{ Name = '5 minutes old: loaded, the last 300 seconds missing'; Age = 300; Loaded = $true; Gap = 300 }
        @{ Name = '14 min 59 s old: loaded, all but one missing'; Age = 899; Loaded = $true; Gap = 899 }
        @{ Name = '15 min 1 s old: ignored and left as it is'; Age = 901; Loaded = $false; Gap = 900 }
    ) {
        New-HistoryFile $StateDir $T0
        $r = Import-History -StatePath $StateDir -Store $Store -Now $T0.AddSeconds($Age)
        $r.Loaded | Should -Be $Loaded
        $v = Get-Values $Store.Copy() 'cpu'
        @($v | Where-Object { [double]::IsNaN($_) }).Count | Should -Be $Gap
        if ($Loaded) { $v[899 - $Age] | Should -Be 900 } else { $r.Reason | Should -Be 'stale'; Test-Path (Join-Path $StateDir 'history.json') | Should -BeTrue }
    }
    It 'T49-12 a file from the future (<Ahead> s) is ignored, not renamed' -ForEach @(@{ Ahead = 60 }, @{ Ahead = 3600 }) {
        New-HistoryFile $StateDir $T0.AddSeconds($Ahead)
        $r = Import-History -StatePath $StateDir -Store $Store -Now $T0
        $r.Loaded | Should -BeFalse; $r.Reason | Should -Be 'future'
        Test-Path (Join-Path $StateDir 'history.json') | Should -BeTrue
    }
    It 'T49-13 a <Name> file is renamed .bad (replacing an older one) and history starts empty' -ForEach @(
        @{ Name = 'damaged'; Json = '{"version":1,"newestMs":12' }
        @{ Name = 'wrong-types'; Json = '{"version":1,"newestMs":"soon","stepMs":1000,"lines":{"cpu":"x"}}' }
    ) {
        [IO.File]::WriteAllText((Join-Path $StateDir 'history.json.bad'), 'older')
        [IO.File]::WriteAllText((Join-Path $StateDir 'history.json'), $Json)
        $r = Import-History -StatePath $StateDir -Store $Store -Now $T0
        $r.Loaded | Should -BeFalse; $r.Reason | Should -Match 'damaged'
        Test-Path (Join-Path $StateDir 'history.json') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $StateDir 'history.json.bad')) | Should -Be $Json
        @(Get-Values $Store.Copy() 'cpu' | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
    }
    It 'T49-14 an unknown version is renamed .bad, and the next save writes version 1' {
        New-HistoryFile $StateDir $T0 -Version 99
        $r = Import-History -StatePath $StateDir -Store $Store -Now $T0
        $r.Loaded | Should -BeFalse; $r.Reason | Should -Match 'version'
        Test-Path (Join-Path $StateDir 'history.json.bad') | Should -BeTrue
        (Save-History -Store $Store -StatePath $StateDir).Ok | Should -BeTrue
        ([IO.File]::ReadAllText((Join-Path $StateDir 'history.json')) | ConvertFrom-Json).version | Should -Be 1
    }
    It 'T49-15 over 2 MB: renamed .bad unread; exactly 2 MB and valid: loaded' {
        New-HistoryFile $StateDir $T0
        $path = Join-Path $StateDir 'history.json'
        $pad = 2MB - (Get-Item $path).Length
        [IO.File]::AppendAllText($path, (' ' * $pad))
        (Get-Item $path).Length | Should -Be 2MB
        (Import-History -StatePath $StateDir -Store $Store -Now $T0).Loaded | Should -BeTrue
        [IO.File]::AppendAllText($path, ' ')
        $r = Import-History -StatePath $StateDir -Store (New-HistoryStore) -Now $T0
        $r.Loaded | Should -BeFalse; $r.Reason | Should -Match 'too big'
        Test-Path "$path.bad" | Should -BeTrue
    }
    It 'T49-16 unknown lines dropped, missing lines empty, wrong lengths aligned to the newest reading' {
        $Store.Register('test-line')
        New-HistoryFile $StateDir $T0 -Length 10 -Names @('cpu', 'mem', 'gpu', 'rx', 'extra')
        (Import-History -StatePath $StateDir -Store $Store -Now $T0).Loaded | Should -BeTrue
        $c = $Store.Copy()
        $c.Lines.Keys | Should -Not -Contain 'extra'
        @(Get-Values $c 'tx' | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
        @(Get-Values $c 'test-line' | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
        (Get-Values $c 'cpu')[890..899] | Should -Be (1..10)
        [double]::IsNaN((Get-Values $c 'cpu')[889]) | Should -BeTrue
    }
}

Describe 'T49-17 when to save' {
    It 'T49-17 due at 5, 10 and 15 minutes over 16 minutes' {
        $last = $T0; $due = @()
        for ($m = 1; $m -le 16; $m++) {
            $now = $T0.AddMinutes($m)
            if (Test-HistorySaveDue -LastSave $last -Now $now) { $due += $m; $last = $now }
        }
        $due | Should -Be @(5, 10, 15)
    }
}

Describe 'Review fixes for #49' {
    It 'T49-10 a missing drive: a failure result, never an exception, even with ErrorActionPreference Stop' {
        $s = New-HistoryStore -Slots 3 -Lines @('cpu'); $s.Append('cpu', 1, $T0Ms)
        $ErrorActionPreference = 'Stop'
        $free = [char[]](90..68) | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1
        { $script:Out = @(Save-History -Store $s -StatePath "$($free):\SRRVRR\state" 2>&1) } | Should -Not -Throw
        @($Out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }).Count | Should -Be 0 -Because 'nothing may escape, not even a non-terminating error'
        $script:R = $Out[-1]
        $R.Ok | Should -BeFalse
        $R.Error | Should -Not -BeNullOrEmpty
    }
}