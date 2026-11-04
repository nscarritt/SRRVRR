# modules\Maintenance.psm1: the Maintenance state, its file, the request guard and the rate limit (spec sections 4
# and 8). The listener tests (T50-34, T50-35, T50-37, T50-38) and the test-build test (T50-52) are in Web.Tests.ps1
# and Smoke.Tests.ps1.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Maintenance.psm1') -Force
    $script:T0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
    $script:T0Ms = $T0.ToUnixTimeMilliseconds()
    $script:HourMs = 3600000L
    # A fake clock: tests move $Fake.Now; the closure keeps the same hashtable.
    $fakeTime = @{ Now = $T0 }
    $script:Fake = $fakeTime
    $script:Clock = { $fakeTime.Now }.GetNewClosure()
    $script:Identity = @{ Names = @('SRRVRR', 'SRRVRR.local'); Addresses = @('203.0.113.10', 'fe80::1') }
    $script:Port = 8091
    function Write-MaintenanceFile([string]$StateDir, [string]$Json) {
        [IO.File]::WriteAllText((Join-Path $StateDir 'maintenance.json'), $Json, (New-Object Text.UTF8Encoding($false)))
    }
    # The headers of a request that passes the guard, with the given names changed (a $null value removes it).
    function Get-GoodHeader([hashtable]$Change = @{}) {
        $h = @{ 'Host' = 'SRRVRR:8091'; 'X-SRRVRR' = '1'; 'Content-Type' = 'application/json'; 'Origin' = 'http://SRRVRR:8091' }
        foreach ($k in $Change.Keys) { if ($null -eq $Change[$k]) { $h.Remove($k) } else { $h[$k] = $Change[$k] } }
        $h
    }
}

Describe 'T50-27 Maintenance lasts MaintenanceHours and switches itself off' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T50-27 on at t, still on at t + 1:59:59, off at t + 2:00:00 with one expired change' {
        $m = New-MaintenanceState -Clock $Clock -Hours 2
        $m.IsOn() | Should -BeFalse
        $on = $m.SetOn('203.0.113.5')
        $on.type | Should -Be 'maintenance-on'
        $on.data.untilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $on.data.address | Should -Be '203.0.113.5'
        $on.data.reason | Should -Be 'requested'
        $m.UntilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $Fake.Now = $T0.AddHours(2).AddSeconds(-1)
        $m.IsOn() | Should -BeTrue
        $m.Poll() | Should -BeNullOrEmpty
        $Fake.Now = $T0.AddHours(2)
        $m.IsOn() | Should -BeFalse
        $off = $m.Poll()
        $off.type | Should -Be 'maintenance-off'
        $off.data.reason | Should -Be 'expired'
        $off.data.untilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $off.data.address | Should -BeNullOrEmpty
        $m.Poll() | Should -BeNullOrEmpty
        $Fake.Now = $T0.AddHours(3)
        $m.Poll() | Should -BeNullOrEmpty
    }
    It 'T50-27 the defaults are 2 hours, and Hours is never more than MaxHours' {
        (New-MaintenanceState -Clock $Clock).SetOn('127.0.0.1').data.untilMs | Should -Be ($T0Ms + 2 * $HourMs)
        (New-MaintenanceState -Clock $Clock -Hours 10 -MaxHours 8).SetOn('127.0.0.1').data.untilMs | Should -Be ($T0Ms + 8 * $HourMs)
        (New-MaintenanceState -Clock $Clock -Hours 0.25).SetOn('127.0.0.1').data.untilMs | Should -Be ($T0Ms + 900000)
    }
    It 'T50-27 turning on again starts the time again from now' {
        $m = New-MaintenanceState -Clock $Clock
        $null = $m.SetOn('127.0.0.1')
        $Fake.Now = $T0.AddHours(1)
        $m.SetOn('127.0.0.1').data.untilMs | Should -Be ($T0Ms + 3 * $HourMs)
    }
    It 'T50-27 turning off by request is a requested change, and no expired change follows' {
        $m = New-MaintenanceState -Clock $Clock
        $null = $m.SetOn('203.0.113.5')
        $Fake.Now = $T0.AddMinutes(30)
        $off = $m.SetOff('203.0.113.6')
        $off.type | Should -Be 'maintenance-off'
        $off.data.reason | Should -Be 'requested'
        $off.data.address | Should -Be '203.0.113.6'
        $off.data.untilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $m.IsOn() | Should -BeFalse
        $m.UntilMs | Should -Be 0
        $Fake.Now = $T0.AddHours(3)
        $m.Poll() | Should -BeNullOrEmpty
    }
    It 'T50-27 a restored end time is kept, and Snapshot gives on and untilMs' {
        $m = New-MaintenanceState -Clock $Clock -UntilMs ($T0Ms + $HourMs)
        $m.IsOn() | Should -BeTrue
        $m.Snapshot().on | Should -BeTrue
        $m.Snapshot().untilMs | Should -Be ($T0Ms + $HourMs)
        $Fake.Now = $T0.AddHours(1)
        $m.Snapshot().on | Should -BeFalse
        $m.Snapshot().untilMs | Should -BeNullOrEmpty
        $m.Poll().data.reason | Should -Be 'expired'
    }
}

Describe 'T50-28 events raised while on' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T50-28 the state says on for the whole time it is on, and off before and after' {
        $m = New-MaintenanceState -Clock $Clock -Hours 1
        $m.IsOn() | Should -BeFalse
        $null = $m.SetOn('127.0.0.1')
        foreach ($s in 0, 1, 1800, 3599) { $Fake.Now = $T0.AddSeconds($s); $m.IsOn() | Should -BeTrue }
        $Fake.Now = $T0.AddSeconds(3600)
        $m.IsOn() | Should -BeFalse
    }
}

Describe 'T50-29 saving and loading maintenance.json' {
    BeforeEach {
        $Fake.Now = $T0
        $script:DataPath = New-TestDataPath
        $script:StateDir = Join-Path $DataPath 'state'
        $script:File = Join-Path $StateDir 'maintenance.json'
    }
    AfterEach { Remove-TestDataPath $DataPath }
    It 'T50-29 on with a future end: saved, then restored with the same untilMs' {
        $m = New-MaintenanceState -Clock $Clock
        $null = $m.SetOn('127.0.0.1')
        $r = Save-Maintenance -State $m -StatePath $StateDir
        $r.Ok | Should -BeTrue
        $r.Error | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($File) | Should -BeExactly ('{"version":1,"on":true,"untilMs":' + ($T0Ms + 2 * $HourMs) + '}')
        $Fake.Now = $T0.AddMinutes(10)
        $i = Import-Maintenance -StatePath $StateDir -Now $Fake.Now -MaxHours 8
        $i.UntilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $i.Change | Should -BeNullOrEmpty
        (New-MaintenanceState -Clock $Clock -UntilMs $i.UntilMs).IsOn() | Should -BeTrue
    }
    It 'T50-29 saving writes a .tmp then swaps it in, replacing the old file, with nothing left over' {
        $m = New-MaintenanceState -Clock $Clock
        $null = $m.SetOn('127.0.0.1')
        (Save-Maintenance -State $m -StatePath $StateDir).Ok | Should -BeTrue
        $null = $m.SetOff('127.0.0.1')
        (Save-Maintenance -State $m -StatePath $StateDir).Ok | Should -BeTrue
        [IO.File]::ReadAllText($File) | Should -BeExactly '{"version":1,"on":false,"untilMs":0}'
        @(Get-ChildItem -LiteralPath $StateDir | ForEach-Object { $_.Name }) | Should -Be @('maintenance.json')
        (Import-Maintenance -StatePath $StateDir -Now $Fake.Now -MaxHours 8).UntilMs | Should -Be 0
    }
    It 'T50-29 a save that fails returns the error and never throws' {
        $m = New-MaintenanceState -Clock $Clock
        $r = Save-Maintenance -State $m -StatePath (Join-Path $DataPath 'no-such-folder')
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'maintenance'
    }
    It 'T50-29 no file: off, nothing to say' {
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Change | Should -BeNullOrEmpty
        $i.Error | Should -BeNullOrEmpty
    }
    It 'T50-29 expired: off, and the file is left as it is' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":true,"untilMs":' + ($T0Ms - 1000) + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Error | Should -BeNullOrEmpty
        [IO.File]::Exists($File) | Should -BeTrue
    }
    It 'T50-29 an end exactly now counts as expired' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":true,"untilMs":' + $T0Ms + '}')
        (Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8).UntilMs | Should -Be 0
    }
    It 'T50-29 saved off: off' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":false,"untilMs":' + ($T0Ms + $HourMs) + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Change | Should -BeNullOrEmpty
    }
    It 'T50-29 damaged (<Name>): off, renamed .bad, one error' -ForEach @(
        @{ Name = 'cut short'; Json = '{"version":1,"on":tru' }
        @{ Name = 'not JSON'; Json = 'hello' }
        @{ Name = 'empty'; Json = '' }
        @{ Name = 'an array'; Json = '[1,2]' }
        @{ Name = 'on is a string'; Json = '{"version":1,"on":"yes","untilMs":1893456000000}' }
        @{ Name = 'untilMs is a string'; Json = '{"version":1,"on":true,"untilMs":"soon"}' }
        @{ Name = 'untilMs is missing'; Json = '{"version":1,"on":true}' }
        @{ Name = 'untilMs has a fraction'; Json = '{"version":1,"on":true,"untilMs":1893456000000.5}' }
    ) {
        Write-MaintenanceFile $StateDir $Json
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Change | Should -BeNullOrEmpty
        $i.Error | Should -Match 'damaged'
        [IO.File]::Exists($File) | Should -BeFalse
        [IO.File]::Exists("$File.bad") | Should -BeTrue
    }
    It 'T50-29 a second damaged file replaces an older .bad' {
        [IO.File]::WriteAllText("$File.bad", 'old')
        Write-MaintenanceFile $StateDir 'new'
        $null = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        [IO.File]::ReadAllText("$File.bad") | Should -Be 'new'
    }
    It 'T50-29 unknown version: off, renamed .bad, with the version in the error' {
        Write-MaintenanceFile $StateDir ('{"version":2,"on":true,"untilMs":' + ($T0Ms + $HourMs) + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Error | Should -Match 'unknown version 2'
        [IO.File]::Exists("$File.bad") | Should -BeTrue
    }
    It 'T50-29 4 KB + 1 byte: off, renamed .bad, and nothing past 4 KB is read' {
        # Valid JSON up to the cap, so only the size can refuse it.
        $json = '{"version":1,"on":true,"untilMs":' + ($T0Ms + $HourMs) + '}'
        Write-MaintenanceFile $StateDir ($json + (' ' * (4KB + 1 - $json.Length)))
        (New-Object IO.FileInfo $File).Length | Should -Be (4KB + 1)
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Error | Should -Match 'too big'
        [IO.File]::Exists("$File.bad") | Should -BeTrue
    }
    It 'T50-29 exactly 4 KB is read' {
        $json = '{"version":1,"on":true,"untilMs":' + ($T0Ms + $HourMs) + '}'
        Write-MaintenanceFile $StateDir ($json + (' ' * (4KB - $json.Length)))
        (Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8).UntilMs | Should -Be ($T0Ms + $HourMs)
    }
    It 'T50-29 a file that grows past the cap after its size was checked is still refused' {
        # The bounded read, not only the size check: a 1 MB file with MaxBytes 4 KB.
        Write-MaintenanceFile $StateDir ('{' + (' ' * 1MB) + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8 -MaxBytes 4KB
        $i.Error | Should -Match 'too big'
    }
}

Describe 'T50-30 the end time read from the file is held to MaintenanceMaxHours' {
    BeforeEach { $script:DataPath = New-TestDataPath; $script:StateDir = Join-Path $DataPath 'state' }
    AfterEach { Remove-TestDataPath $DataPath }
    It 'T50-30 untilMs a year ahead with MaxHours 8: held to now + 8 h' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":true,"untilMs":' + $T0.AddDays(365).ToUnixTimeMilliseconds() + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be ($T0Ms + 8 * $HourMs)
        $i.Change | Should -BeNullOrEmpty
        $i.Error | Should -BeNullOrEmpty
    }
    It 'T50-30 an end inside the limit is kept as it is' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":true,"untilMs":' + ($T0Ms + 8 * $HourMs) + '}')
        (Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8).UntilMs | Should -Be ($T0Ms + 8 * $HourMs)
    }
    It 'T50-30 a restored state is held to MaxHours too' {
        $Fake.Now = $T0
        (New-MaintenanceState -Clock $Clock -MaxHours 8 -UntilMs ($T0Ms + 100 * $HourMs)).UntilMs | Should -Be ($T0Ms + 8 * $HourMs)
    }
}

Describe 'T50-59 Maintenance that ended while SRRVRR was stopped' {
    BeforeEach { $script:DataPath = New-TestDataPath; $script:StateDir = Join-Path $DataPath 'state' }
    AfterEach { Remove-TestDataPath $DataPath }
    It 'T50-59 untilMs in the past at start: off, and one expired change carrying the original end time' {
        $ended = $T0Ms - 5 * 60000
        Write-MaintenanceFile $StateDir ('{"version":1,"on":true,"untilMs":' + $ended + '}')
        $i = Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8
        $i.UntilMs | Should -Be 0
        $i.Change.type | Should -Be 'maintenance-off'
        $i.Change.data.reason | Should -Be 'expired'
        $i.Change.data.untilMs | Should -Be $ended
        $i.Change.data.address | Should -BeNullOrEmpty
        # The state built from it is off and has nothing more to report.
        $Fake.Now = $T0
        $m = New-MaintenanceState -Clock $Clock -UntilMs $i.UntilMs
        $m.IsOn() | Should -BeFalse
        $m.Poll() | Should -BeNullOrEmpty
    }
    It 'T50-59 a file saved off gives no change' {
        Write-MaintenanceFile $StateDir ('{"version":1,"on":false,"untilMs":' + ($T0Ms - 1000) + '}')
        (Import-Maintenance -StatePath $StateDir -Now $T0 -MaxHours 8).Change | Should -BeNullOrEmpty
    }
}

Describe 'T50-31 the request body' {
    It 'T50-31 <Name>' -ForEach @(
        @{ Name = '{"on":true} accepted'; Body = '{"on":true}'; Ok = $true; On = $true }
        @{ Name = '{"on":false} accepted'; Body = '{"on":false}'; Ok = $true; On = $false }
        @{ Name = 'extra fields ignored'; Body = '{"on":true,"hours":24}'; Ok = $true; On = $true }
        @{ Name = 'spaces and newlines allowed'; Body = "{ `"on`" : false }`r`n"; Ok = $true; On = $false }
        @{ Name = '{"on":"yes"} 400'; Body = '{"on":"yes"}'; Ok = $false }
        @{ Name = '{"on":"true"} 400'; Body = '{"on":"true"}'; Ok = $false }
        @{ Name = '{"on":1} 400'; Body = '{"on":1}'; Ok = $false }
        @{ Name = '{"on":0} 400'; Body = '{"on":0}'; Ok = $false }
        @{ Name = '{"on":null} 400'; Body = '{"on":null}'; Ok = $false }
        @{ Name = '{"on":[true]} 400'; Body = '{"on":[true]}'; Ok = $false }
        @{ Name = '{} 400'; Body = '{}'; Ok = $false }
        @{ Name = 'a bare true 400'; Body = 'true'; Ok = $false }
        @{ Name = 'an array 400'; Body = '[{"on":true}]'; Ok = $false }
        @{ Name = 'not JSON 400'; Body = 'on=true'; Ok = $false }
        @{ Name = 'empty 400'; Body = ''; Ok = $false }
        @{ Name = 'over 1 KB 400'; Body = '{"on":true,"x":"' + ('a' * 1100) + '"}'; Ok = $false }
    ) {
        $r = ConvertFrom-MaintenanceBody -Body $Body
        $r.Ok | Should -Be $Ok
        if ($Ok) { $r.On | Should -Be $On; $r.Status | Should -Be 200 } else { $r.Status | Should -Be 400; $r.On | Should -BeNullOrEmpty }
    }
    It 'T50-31 a $null body is 400' {
        (ConvertFrom-MaintenanceBody -Body $null).Status | Should -Be 400
    }
}

Describe 'T50-32 the address recorded is the remote address' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T50-32 the change records the address it was given, with on or off and untilMs' {
        $m = New-MaintenanceState -Clock $Clock
        $on = $m.SetOn('203.0.113.5')
        $on.data.address | Should -Be '203.0.113.5'
        $on.data.untilMs | Should -Be ($T0Ms + 2 * $HourMs)
        $on.type | Should -Be 'maintenance-on'
    }
    It 'T50-32 X-Forwarded-For changes nothing in the guard, and the module never reads it' {
        (Test-MaintenanceRequest -Headers (Get-GoodHeader @{ 'X-Forwarded-For' = '203.0.113.99' }) -Identity $Identity -Port $Port).Ok | Should -BeTrue
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'modules\Maintenance.psm1'))
        $text | Should -Not -Match 'Forwarded'
    }
}

Describe 'T50-33 the rate limit' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T50-33 one address at 0, 5 and 10 s: ok, refused, ok; a second address ok at 5 s' {
        $l = New-RateLimiter -Clock $Clock
        $l.Allow('203.0.113.5') | Should -BeTrue
        $Fake.Now = $T0.AddSeconds(5)
        $l.Allow('203.0.113.5') | Should -BeFalse
        $l.Allow('203.0.113.6') | Should -BeTrue
        $Fake.Now = $T0.AddSeconds(10)
        $l.Allow('203.0.113.5') | Should -BeTrue
        $l.Refused | Should -Be 1
    }
    It 'T50-33 the 61st change in a day is refused; refusals are counted for one log line; the next day is allowed again' {
        $l = New-RateLimiter -Clock $Clock
        for ($i = 0; $i -lt 60; $i++) {
            $Fake.Now = $T0.AddSeconds(10 * $i)
            if (-not $l.Allow('203.0.113.5')) { throw "change $($i + 1) was refused" }
        }
        $Fake.Now = $T0.AddSeconds(600)
        $l.Allow('203.0.113.5') | Should -BeFalse
        $l.Allow('203.0.113.6') | Should -BeTrue -Because 'the day''s limit is per address: one device can''t lock the others out'
        $Fake.Now = $T0.AddSeconds(700)
        $l.Allow('203.0.113.5') | Should -BeFalse
        $l.Refused | Should -Be 2
        $l.TakeRefused() | Should -Be 2
        $l.TakeRefused() | Should -Be 0
        $Fake.Now = [DateTimeOffset]::new(2026, 1, 6, 0, 0, 0, [TimeSpan]::Zero)
        $l.Allow('203.0.113.5') | Should -BeTrue
    }
    It 'T50-33 the day is the clock''s local date: midnight in the clock''s own offset resets the count' {
        $plus2 = [TimeSpan]::FromHours(2)
        $Fake.Now = [DateTimeOffset]::new(2026, 1, 5, 23, 0, 0, $plus2)
        $l = New-RateLimiter -Clock $Clock -PerDay 1
        $l.Allow('127.0.0.1') | Should -BeTrue
        $Fake.Now = [DateTimeOffset]::new(2026, 1, 5, 23, 59, 59, $plus2)
        $l.Allow('127.0.0.1') | Should -BeFalse
        $Fake.Now = [DateTimeOffset]::new(2026, 1, 6, 0, 0, 0, $plus2)
        $l.Allow('127.0.0.1') | Should -BeTrue
    }
    It 'T50-33 a clock that stepped back does not lock an address out' {
        $l = New-RateLimiter -Clock $Clock
        $l.Allow('127.0.0.1') | Should -BeTrue
        $Fake.Now = $T0.AddHours(-1)
        $l.Allow('127.0.0.1') | Should -BeTrue
    }
    It 'T50-33 the limits are parameters' {
        $l = New-RateLimiter -Clock $Clock -PerAddressSeconds 1 -PerDay 2
        $l.Allow('127.0.0.1') | Should -BeTrue
        $Fake.Now = $T0.AddSeconds(1)
        $l.Allow('127.0.0.1') | Should -BeTrue
        $Fake.Now = $T0.AddSeconds(2)
        $l.Allow('127.0.0.1') | Should -BeFalse
    }
}

Describe 'T50-36 the request guard' {
    It 'T50-36 (<Case>) <Name>: <Expect>' -ForEach @(
        @{ Case = 'a'; Name = 'no X-SRRVRR'; Change = @{ 'X-SRRVRR' = $null }; Expect = 403 }
        @{ Case = 'b'; Name = 'X-SRRVRR: 0'; Change = @{ 'X-SRRVRR' = '0' }; Expect = 403 }
        @{ Case = 'b'; Name = 'X-SRRVRR: 2'; Change = @{ 'X-SRRVRR' = '2' }; Expect = 403 }
        @{ Case = 'b'; Name = 'X-SRRVRR: yes'; Change = @{ 'X-SRRVRR' = 'yes' }; Expect = 403 }
        @{ Case = 'b'; Name = 'X-SRRVRR: 1,1'; Change = @{ 'X-SRRVRR' = '1,1' }; Expect = 403 }
        @{ Case = 'c'; Name = 'no Content-Type'; Change = @{ 'Content-Type' = $null }; Expect = 403 }
        @{ Case = 'c'; Name = 'Content-Type text/plain'; Change = @{ 'Content-Type' = 'text/plain' }; Expect = 403 }
        @{ Case = 'c'; Name = 'Content-Type application/jsonx'; Change = @{ 'Content-Type' = 'application/jsonx' }; Expect = 403 }
        @{ Case = 'd'; Name = 'Origin with an allowed name and the port'; Change = @{}; Expect = 200 }
        @{ Case = 'd'; Name = 'Origin with an allowed address'; Change = @{ 'Origin' = 'http://203.0.113.10:8091' }; Expect = 200 }
        @{ Case = 'd'; Name = 'Origin localhost'; Change = @{ 'Origin' = 'http://localhost:8091' }; Expect = 200 }
        @{ Case = 'd'; Name = 'Origin 127.0.0.1'; Change = @{ 'Origin' = 'http://127.0.0.1:8091' }; Expect = 200 }
        @{ Case = 'e'; Name = 'another host'; Change = @{ 'Origin' = 'http://evil.example:8091' }; Expect = 403 }
        @{ Case = 'e'; Name = 'an allowed name as a prefix'; Change = @{ 'Origin' = 'http://SRRVRR.evil.example:8091' }; Expect = 403 }
        @{ Case = 'e'; Name = 'a trailing dot'; Change = @{ 'Origin' = 'http://SRRVRR.:8091' }; Expect = 403 }
        @{ Case = 'f'; Name = 'an allowed host on another port'; Change = @{ 'Origin' = 'http://SRRVRR:8092' }; Expect = 403 }
        @{ Case = 'f'; Name = 'an allowed host with no port'; Change = @{ 'Origin' = 'http://SRRVRR' }; Expect = 403 }
        @{ Case = 'g'; Name = 'https with an allowed host'; Change = @{ 'Origin' = 'https://SRRVRR:8091' }; Expect = 403 }
        @{ Case = 'h'; Name = 'Origin: null'; Change = @{ 'Origin' = 'null' }; Expect = 403 }
        @{ Case = 'h'; Name = 'Origin with a path'; Change = @{ 'Origin' = 'http://SRRVRR:8091/' }; Expect = 403 }
        @{ Case = 'h'; Name = 'Origin with user info'; Change = @{ 'Origin' = 'http://x@SRRVRR:8091' }; Expect = 403 }
        @{ Case = 'i'; Name = 'no Origin but a matching Referer'; Change = @{ 'Origin' = $null; 'Referer' = 'http://SRRVRR:8091/' }; Expect = 403 }
        @{ Case = 'j'; Name = 'neither Origin nor Referer'; Change = @{ 'Origin' = $null }; Expect = 403 }
        @{ Case = 'k'; Name = 'upper-case host'; Change = @{ 'Origin' = 'http://LOCALHOST:8091' }; Expect = 200 }
        @{ Case = 'k'; Name = 'lower-case of an upper-case name'; Change = @{ 'Origin' = 'http://srrvrr.local:8091' }; Expect = 200 }
        @{ Case = 'l'; Name = '[::1]'; Change = @{ 'Origin' = 'http://[::1]:8091' }; Expect = 200 }
        @{ Case = 'l'; Name = 'an allowed IPv6 address'; Change = @{ 'Origin' = 'http://[fe80::1]:8091' }; Expect = 200 }
        @{ Case = 'l'; Name = 'IPv6 without brackets'; Change = @{ 'Origin' = 'http://::1:8091' }; Expect = 403 }
        @{ Case = 'm'; Name = 'application/json; charset=utf-8'; Change = @{ 'Content-Type' = 'application/json; charset=utf-8' }; Expect = 200 }
        @{ Case = 'm'; Name = 'Application/JSON'; Change = @{ 'Content-Type' = 'Application/JSON' }; Expect = 200 }
    ) {
        $r = Test-MaintenanceRequest -Headers (Get-GoodHeader $Change) -Identity $Identity -Port $Port
        $r.Status | Should -Be $Expect
        $r.Ok | Should -Be ($Expect -eq 200)
    }
    It 'T50-36 header names are matched in any case, and a NameValueCollection works like a hashtable' {
        $nv = New-Object System.Collections.Specialized.NameValueCollection
        $nv.Add('x-srrvrr', '1'); $nv.Add('content-type', 'application/json'); $nv.Add('origin', 'http://SRRVRR:8091')
        (Test-MaintenanceRequest -Headers $nv -Identity $Identity -Port $Port).Ok | Should -BeTrue
        $nv.Remove('origin')
        (Test-MaintenanceRequest -Headers $nv -Identity $Identity -Port $Port).Status | Should -Be 403
        $cs = New-Object System.Collections.Hashtable   # case-sensitive keys
        $cs['x-srrvrr'] = '1'; $cs['CONTENT-TYPE'] = 'application/json'; $cs['oRiGiN'] = 'http://SRRVRR:8091'
        (Test-MaintenanceRequest -Headers $cs -Identity $Identity -Port $Port).Ok | Should -BeTrue
    }
    It 'T50-36 on port 80 an Origin without a port is allowed, as the Host check allows it' {
        (Test-MaintenanceRequest -Headers (Get-GoodHeader @{ 'Origin' = 'http://SRRVRR' }) -Identity $Identity -Port 80).Ok | Should -BeTrue
        (Test-MaintenanceRequest -Headers (Get-GoodHeader @{ 'Origin' = 'http://SRRVRR:80' }) -Identity $Identity -Port 80).Ok | Should -BeTrue
    }
    It 'T50-36 the Origin host list agrees with the Host allowlist in Web.psm1 (<Hostname>)' -ForEach @(
        @{ Hostname = 'SRRVRR' }, @{ Hostname = 'srrvrr.LOCAL' }, @{ Hostname = 'localhost' }, @{ Hostname = '127.0.0.1' },
        @{ Hostname = '[::1]' }, @{ Hostname = '203.0.113.10' }, @{ Hostname = '[fe80::1]' }, @{ Hostname = '203.0.113.11' },
        @{ Hostname = 'evil.example' }, @{ Hostname = 'SRRVRR.' }, @{ Hostname = '[::2]' }
    ) {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Web.psm1') -Force
        $hostOk = Test-HostAllowed -HostHeader "${Hostname}:$Port" -Port $Port -Identity $Identity
        $originOk = (Test-MaintenanceRequest -Headers (Get-GoodHeader @{ 'Origin' = "http://${Hostname}:$Port" }) -Identity $Identity -Port $Port).Ok
        $originOk | Should -Be $hostOk
    }
}
