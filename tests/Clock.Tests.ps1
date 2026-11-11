# Clock changes and midnight (spec 2026-11-06 section 4, test plan 6.6): dated files, retention, the /events window and
# history across a zone's spring-forward (2027-03-14, a 23-hour day) and fall-back (2027-11-07, a 25-hour day).
# Every time is a fixed DateTimeOffset with the offset a US Eastern-style zone has at that moment: -05:00 in winter,
# -04:00 in summer.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\EventLog.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
    $script:Eastern = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    $script:Winter = [TimeSpan]::FromHours(-5)
    $script:Summer = [TimeSpan]::FromHours(-4)
    function New-FakeClock([DateTimeOffset]$Start) {
        $c = @{ Now = $Start }
        $c.Clock = { $c.Now }.GetNewClosure()
        $c
    }
    function Get-Names([string]$Dir) { @([IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) }
    function Get-FileLines([string]$Path) { @([IO.File]::ReadAllLines($Path)) }
    function New-EventLine([long]$Id) {
        ConvertTo-Json -Compress -InputObject ([ordered]@{ id = $Id; time = $Id; type = 'test'; severity = 'warn'; maintenance = $false; data = @{} })
    }
}

Describe 'T66 dated files' {
    It 'T66-01 the spring 23-hour day: each line goes to its own day''s file' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $clock = New-FakeClock ([DateTimeOffset]::new(2027, 3, 13, 23, 59, 0, $Winter))
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $clock.Clock
            $log.Write('before', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 3, 14, 0, 30, 0, $Winter); $log.Write('a-0030', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 3, 14, 1, 59, 0, $Winter); $log.Write('b-0159', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 3, 14, 3, 0, 0, $Summer); $log.Write('c-0300', $false)
            Get-Names $dir | Should -Be @('events-2027-03-13.jsonl', 'events-2027-03-14.jsonl')
            Get-FileLines (Join-Path $dir 'events-2027-03-13.jsonl') | Should -Be @('before')
            Get-FileLines (Join-Path $dir 'events-2027-03-14.jsonl') | Should -Be @('a-0030', 'b-0159', 'c-0300')
            $log.Failed | Should -BeFalse
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T66-02 the fall repeated hour: every line is in the change day''s one file, in the order written' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $clock = New-FakeClock ([DateTimeOffset]::new(2027, 11, 7, 1, 30, 0, $Summer))
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $clock.Clock
            $log.Write('first-0130-summer', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 11, 7, 1, 10, 0, $Winter); $log.Write('second-0110-winter', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 11, 7, 1, 40, 0, $Winter); $log.Write('third-0140-winter', $false)
            Get-Names $dir | Should -Be @('events-2027-11-07.jsonl')
            Get-FileLines (Join-Path $dir 'events-2027-11-07.jsonl') | Should -Be @('first-0130-summer', 'second-0110-winter', 'third-0140-winter')
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T66-03 23:59:59.999 and 00:00:00.000 local are in two files, one line each' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $clock = New-FakeClock ([DateTimeOffset]::new(2027, 11, 6, 23, 59, 59, 999, $Summer))
            $log = New-DailyLog -Folder $dir -Prefix 'srrvrr' -Extension 'log' -Clock $clock.Clock
            $log.Write('last-ms', $false)
            $clock.Now = [DateTimeOffset]::new(2027, 11, 7, 0, 0, 0, 0, $Summer); $log.Write('first-ms', $false)
            Get-Names $dir | Should -Be @('srrvrr-2027-11-06.log', 'srrvrr-2027-11-07.log')
            Get-FileLines (Join-Path $dir 'srrvrr-2027-11-06.log') | Should -Be @('last-ms')
            Get-FileLines (Join-Path $dir 'srrvrr-2027-11-07.log') | Should -Be @('first-ms')
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T66-06 the 25-hour day has one file name every 15 minutes' {
        $log = New-DailyLog -Folder 'C:\unused' -Prefix 'events' -Extension 'jsonl' -Clock { [DateTimeOffset]::new(2027, 11, 7, 0, 0, 0, $Summer) }
        $startUtc = [DateTimeOffset]::new(2027, 11, 7, 4, 0, 0, [TimeSpan]::Zero)   # local midnight, still summer time
        $names = New-Object System.Collections.Generic.HashSet[string]
        $steps = 0
        for ($utc = $startUtc; $utc -lt $startUtc.AddHours(25); $utc = $utc.AddMinutes(15)) {
            $local = [TimeZoneInfo]::ConvertTime($utc, $script:Eastern)
            [void]$names.Add([IO.Path]::GetFileName($log.PathFor($local)))
            $steps++
        }
        $steps | Should -Be 100
        @($names) | Should -Be @('events-2027-11-07.jsonl')
    }
}

Describe 'T66-04 retention across clock changes' {
    # 40 consecutive dates ending on the change day, an event log and a crash log for each.
    It 'T66-04 keeps exactly the 31 newest dates on <Name>' -ForEach @(
        @{ Name = 'the spring change day'; Now = [DateTimeOffset]::new(2027, 3, 14, 3, 30, 0, [TimeSpan]::FromHours(-4)) }
        @{ Name = 'the fall change day, in the repeated hour'; Now = [DateTimeOffset]::new(2027, 11, 7, 1, 30, 0, [TimeSpan]::FromHours(-5)) }
    ) {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $today = $Now.Date
            $dates = @(0..39 | ForEach-Object { $today.AddDays(-$_).ToString('yyyy-MM-dd') })
            foreach ($d in $dates) {
                [IO.File]::WriteAllText([IO.Path]::Combine($dir, "events-$d.jsonl"), "x`r`n")
                [IO.File]::WriteAllText([IO.Path]::Combine($dir, "srrvrr-$d.log"), "x`r`n")
            }
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 31 -Now $Now
            $r.Skipped | Should -BeFalse
            $r.Deleted.Count | Should -Be 18
            $kept = @(Get-Names $dir)
            $kept.Count | Should -Be 62
            $newest31 = @($dates[0..30])
            foreach ($d in $newest31) {
                $kept | Should -Contain "events-$d.jsonl"
                $kept | Should -Contain "srrvrr-$d.log"
            }
            foreach ($d in $dates[31..39]) {
                $kept | Should -Not -Contain "events-$d.jsonl"
                $kept | Should -Not -Contain "srrvrr-$d.log"
            }
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T66 the /events window' {
    It 'T66-05 starts at local midnight of the first day at that day''s own offset: <Name>' -ForEach @(
        # Spring: yesterday (Mar 14) began at -05:00 = 05:00Z, but today's offset is -04:00.
        @{ Name = 'the day after the spring change'; Now = [DateTimeOffset]::new(2027, 3, 15, 10, 0, 0, [TimeSpan]::FromHours(-4)); Midnight = [DateTimeOffset]::new(2027, 3, 14, 0, 0, 0, [TimeSpan]::FromHours(-5)) }
        # Fall: yesterday (Nov 7) began at -04:00 = 04:00Z, but today's offset is -05:00.
        @{ Name = 'the day after the fall change'; Now = [DateTimeOffset]::new(2027, 11, 8, 10, 0, 0, [TimeSpan]::FromHours(-5)); Midnight = [DateTimeOffset]::new(2027, 11, 7, 0, 0, 0, [TimeSpan]::FromHours(-4)) }
    ) {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $index = Initialize-EventIndex -LogDir $dir -Days 2 -Now $Now
            $before = $Midnight.AddMinutes(-30).ToUnixTimeMilliseconds()
            $after = $Midnight.AddMinutes(30).ToUnixTimeMilliseconds()
            [void]$index.Add((ConvertFrom-Json (New-EventLine $before)))
            [void]$index.Add((ConvertFrom-Json (New-EventLine $after)))
            $got = Get-IndexedEvents -Index $index -Days 2 -Now $Now -TimeZone $script:Eastern
            @($got | ForEach-Object { [long]$_.id }) | Should -Be @($after)
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T66-08 loads yesterday''s and today''s files with Days 2, no more and no fewer' -ForEach @(
        @{ Name = 'the day after the spring change'; Now = [DateTimeOffset]::new(2027, 3, 15, 10, 0, 0, [TimeSpan]::FromHours(-4)); Files = @('2027-03-13', '2027-03-14', '2027-03-15', '2027-03-16') ; Loaded = @('2027-03-14', '2027-03-15', '2027-03-16') }
        @{ Name = 'the day after the fall change'; Now = [DateTimeOffset]::new(2027, 11, 8, 10, 0, 0, [TimeSpan]::FromHours(-5)); Files = @('2027-11-06', '2027-11-07', '2027-11-08'); Loaded = @('2027-11-07', '2027-11-08') }
    ) {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $id = 1L
            foreach ($d in $Files) {
                [IO.File]::WriteAllText([IO.Path]::Combine($dir, "events-$d.jsonl"), ((New-EventLine $id) + "`r`n"))
                $id++
            }
            $index = Initialize-EventIndex -LogDir $dir -Days 2 -Now $Now
            # The ids are 1, 2, 3...: the file at position i in Files has id i + 1.
            $want = @($Loaded | ForEach-Object { [long]([array]::IndexOf($Files, $_) + 1) })
            @($index.Events | ForEach-Object { [long]$_.id }) | Should -Be $want
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T66-07 history across the fall repeated hour' {
    It 'T66-07 a reading a second through the repeated hour: strictly increasing UTC times, saved and loaded intact' {
        $state = Join-Path (New-TestDataPath) 'state'
        try {
            $s = New-HistoryStore -Slots 900 -Lines @('cpu')
            # 05:50:00Z to 06:20:00Z: 01:50 summer time, through the change at 06:00Z (01:00 winter time).
            $startMs = [DateTimeOffset]::new(2027, 11, 7, 5, 50, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
            $total = 1800
            for ($i = 0; $i -lt $total; $i++) {
                $local = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($startMs + $i * 1000L), $script:Eastern)
                $s.Append('cpu', $i + 1, $local.ToUnixTimeMilliseconds())
            }
            $c = $s.Copy()
            $lastMs = $startMs + ($total - 1) * 1000L
            $c.NewestMs | Should -Be $lastMs
            $values = $c.Lines['cpu']
            $values.Length | Should -Be 900
            # The newest 900 readings, nothing dropped: 901..1800, each one second after the last.
            $values[0] | Should -Be ($total - 899)
            $values[899] | Should -Be $total
            for ($i = 1; $i -lt 900; $i++) {
                if ($values[$i] -ne $values[$i - 1] + 1) { throw "reading $i is $($values[$i]) after $($values[$i - 1])" }
            }
            (Save-History -Store $s -StatePath $state).Ok | Should -BeTrue
            $fresh = New-HistoryStore -Slots 900 -Lines @('cpu')
            $nowAfter = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($lastMs + 1000L), $script:Eastern)
            $r = Import-History -StatePath $state -Store $fresh -Now $nowAfter
            $r.Loaded | Should -BeTrue
            $c2 = $fresh.Copy()
            $c2.NewestMs | Should -Be ($lastMs + 1000L)
            # The newest saved reading is now one slot back; the second after the save is missing, not kept by local time.
            $c2.Lines['cpu'][898] | Should -Be $total
            [double]::IsNaN($c2.Lines['cpu'][899]) | Should -BeTrue
            # The 15-minute age cut is in UTC time: 14 minutes later still loads, 16 minutes later is stale.
            $ok = Import-History -StatePath $state -Store (New-HistoryStore -Slots 900 -Lines @('cpu')) -Now ([TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($lastMs + 14 * 60000L), $script:Eastern))
            $ok.Loaded | Should -BeTrue
            $stale = Import-History -StatePath $state -Store (New-HistoryStore -Slots 900 -Lines @('cpu')) -Now ([TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($lastMs + 16 * 60000L), $script:Eastern))
            $stale.Loaded | Should -BeFalse
            $stale.Reason | Should -Be 'stale'
        } finally { Remove-TestDataPath (Split-Path -Parent $state) }
    }
}
