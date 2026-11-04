# modules\EventLog.psm1: the event log files, the in-memory index behind /events and cleanup of both logs
# (spec section 4). Fixtures are built here in temp folders, not checked in.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\EventLog.psm1') -Force
    $script:Central = [TimeZoneInfo]::FindSystemTimeZoneById('Central Standard Time')
    # A UTC instant as a Chicago-style local time with the offset that applied then.
    function Get-Central([DateTimeOffset]$Utc) { [TimeZoneInfo]::ConvertTime($Utc, $script:Central) }
    $script:T0 = [DateTimeOffset]::new(2026, 3, 1, 12, 0, 0, [TimeSpan]::FromHours(-6))
    $script:Box = @{ Now = $T0 }
    $script:Clock = { $script:Box.Now }
    function Set-Now([DateTimeOffset]$Time) { $script:Box.Now = $Time }
    # A logged event line as New-EventLogWriter writes it.
    function New-EventLine([long]$Id, [string]$Severity = 'warn', [bool]$Maintenance = $false, [string]$Type = 'service-offline') {
        ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{ id = $Id; time = $Id; type = $Type; severity = $Severity; maintenance = $Maintenance; data = [ordered]@{ name = 'Plex' } })
    }
    function Write-Lines([string]$Path, [string[]]$Lines, [switch]$NoFinalNewline) {
        $text = ($Lines -join "`r`n")
        if (-not $NoFinalNewline) { $text += "`r`n" }
        [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
    }
    # A file in Dir for each name, each with a little text.
    function New-Files([string]$Dir, [string[]]$Names) {
        foreach ($n in $Names) { [IO.File]::WriteAllText([IO.Path]::Combine($Dir, $n), "x`r`n") }
    }
    function Get-Names([string]$Dir) { @([IO.Directory]::GetFileSystemEntries($Dir) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) }
    # Events through the real path: queue, drain, the event log writer, and the index's Add.
    function New-Pipeline([string]$Dir, [long]$CapBytes = 20MB) {
        $log = New-DailyLog -Folder $Dir -Prefix 'events' -Extension 'jsonl' -Clock $script:Clock -CapBytes $CapBytes
        $index = Initialize-EventIndex -LogDir $Dir -Days 31 -Now (& $script:Clock)
        $write = New-EventLogWriter -Log $log
        $writers = @{ Event = { param($e) & $write $e; [void]$index.Add((ConvertTo-LoggedEvent $e)) }.GetNewClosure() }
        @{ Log = $log; Index = $index; Writers = $writers; Queue = (New-SrrQueue); Store = (New-EventStore -Clock $script:Clock -Size 1000) }
    }
    function Send-Event($Pipe, [string]$Key, [string]$Severity = 'warn') {
        Add-SrrQueueItem -Queue $Pipe.Queue -Item (New-SrrEvent -Type 'test' -Severity $Severity -Key $Key -Data @{ n = 1 } -Logged $true)
        Invoke-QueueDrain -Queue $Pipe.Queue -Store $Pipe.Store -Writers $Pipe.Writers -Clock $script:Clock | Out-Null
    }
}

Describe 'T50-18 event log files by local date' {
    It 'T50-18 events either side of local midnight and across a daylight-saving change go to their local date''s file' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $pipe = New-Pipeline $dir
            $times = @(
                (Get-Central ([DateTimeOffset]::new(2026, 3, 8, 5, 59, 59, [TimeSpan]::Zero))),   # 23:59:59 CST, Mar 7
                (Get-Central ([DateTimeOffset]::new(2026, 3, 8, 6, 0, 1, [TimeSpan]::Zero))),     # 00:00:01 CST, Mar 8
                (Get-Central ([DateTimeOffset]::new(2026, 3, 8, 8, 30, 0, [TimeSpan]::Zero))),    # 03:30 CDT, after the change
                (Get-Central ([DateTimeOffset]::new(2026, 3, 9, 4, 59, 59, [TimeSpan]::Zero))),   # 23:59:59 CDT, Mar 8
                (Get-Central ([DateTimeOffset]::new(2026, 3, 9, 5, 0, 1, [TimeSpan]::Zero)))      # 00:00:01 CDT, Mar 9
            )
            $i = 0
            foreach ($t in $times) { Set-Now $t; $i++; Send-Event $pipe "k$i" }
            Get-Names $dir | Should -Be @('events-2026-03-07.jsonl', 'events-2026-03-08.jsonl', 'events-2026-03-09.jsonl')
            $counts = @{ 'events-2026-03-07.jsonl' = 1; 'events-2026-03-08.jsonl' = 3; 'events-2026-03-09.jsonl' = 1 }
            foreach ($name in $counts.Keys) {
                $path = [IO.Path]::Combine($dir, $name)
                $bytes = [IO.File]::ReadAllBytes($path)
                ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse -Because "$name has no BOM"
                $text = [Text.Encoding]::UTF8.GetString($bytes)
                $text | Should -Match "\r\n$"
                ($text -replace "\r\n", '') | Should -Not -Match "[\r\n]" -Because 'every line ends with CRLF'
                $rows = @(Read-JsonLines -Path $path)
                $rows.Count | Should -Be $counts[$name]
                foreach ($r in $rows) {
                    $r | Should -BeOfType [pscustomobject]
                    foreach ($f in 'id', 'time', 'type', 'severity', 'maintenance', 'data') { @($r.PSObject.Properties.Name) | Should -Contain $f }
                }
            }
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T50-18 Read-JsonLines reports bad lines instead of throwing' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $path = [IO.Path]::Combine($dir, 'events-2026-03-01.jsonl')
            Write-Lines $path @((New-EventLine 1), '', 'not json', '{"id":3,"ti') -NoFinalNewline
            $rows = @(Read-JsonLines -Path $path)
            $rows.Count | Should -Be 4
            $rows[0].id | Should -Be 1
            foreach ($r in $rows[1..3]) { $r | Should -BeOfType [hashtable]; $r['Error'] | Should -Not -BeNullOrEmpty }
            $rows[3]['Line'] | Should -Be '{"id":3,"ti'
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T50-20 the event index' {
    BeforeAll {
        # Three days of files: events-good (20 events across severities, one in Maintenance), events-bad-lines (good
        # lines plus an empty line, a non-JSON line and a cut-off last line), and today; plus one file too old to load.
        $script:Dir = Join-Path (New-TestDataPath) 'logs'
        $id = 1000L
        $good = foreach ($i in 1..20) { $id++; New-EventLine -Id $id -Severity (@('info', 'warn', 'flag')[$i % 3]) -Maintenance ($i -eq 7) }
        Write-Lines ([IO.Path]::Combine($Dir, 'events-2026-02-27.jsonl')) $good
        $bad = @((New-EventLine 2001), '', 'this is not json', (New-EventLine 2002), '{"id":2003,"time":2003,"ty')
        Write-Lines ([IO.Path]::Combine($Dir, 'events-2026-02-28.jsonl')) $bad -NoFinalNewline
        Write-Lines ([IO.Path]::Combine($Dir, 'events-2026-03-01.jsonl')) @((New-EventLine 3001 'flag'), (New-EventLine 3002 'info'))
        Write-Lines ([IO.Path]::Combine($Dir, 'events-2026-01-01.jsonl')) @((New-EventLine 1))
        New-Files $Dir @('srrvrr-2026-03-01.log', 'events-2026-03-01.jsonl.bak')
    }
    AfterAll { Remove-TestDataPath (Split-Path -Parent $Dir) }

    It 'T50-20 holds every good logged event of the last Days days, oldest first' {
        $index = Initialize-EventIndex -LogDir $Dir -Days 31 -Now $T0
        $index.Events.Count | Should -Be 24
        @($index.Events | ForEach-Object { [long]$_.id }) | Should -Be @(@(1001..1020) + @(2001, 2002, 3001, 3002))
        @($index.Events | Where-Object { $_.maintenance }).Count | Should -Be 1
        $index.LastId | Should -Be 3002
    }
    It 'T50-20 bad and cut-off lines are skipped and counted in one log line' {
        $index = Initialize-EventIndex -LogDir $Dir -Days 31 -Now $T0
        $index.BadLines | Should -Be 3
        $index.BadLineMessage | Should -Match '3 bad'
        $index.BadLineMessage | Should -Match 'events-2026-02-28\.jsonl'
        $index.BadLineMessage | Should -Not -Match "[\r\n]"
    }
    It 'T50-20 no bad lines means no log line' {
        $index = Initialize-EventIndex -LogDir $Dir -Days 1 -Now $T0
        $index.Events.Count | Should -Be 2
        $index.BadLines | Should -Be 0
        $index.BadLineMessage | Should -BeNullOrEmpty
    }
    It 'T50-20 a missing log folder gives an empty index' {
        $index = Initialize-EventIndex -LogDir ([IO.Path]::Combine($Dir, 'nope')) -Days 31 -Now $T0
        $index.Events.Count | Should -Be 0
        $index.BadLines | Should -Be 0
    }
    It 'T50-20 new events are appended to the index as they are written' {
        $dir2 = Join-Path (New-TestDataPath) 'logs'
        try {
            Set-Now $T0
            $pipe = New-Pipeline $dir2
            Send-Event $pipe 'a' 'warn'
            Set-Now ($T0.AddSeconds(5)); Send-Event $pipe 'b' 'flag'
            $pipe.Index.Events.Count | Should -Be 2
            $got = Get-IndexedEvents -Index $pipe.Index -Days 31 -Now $T0.AddSeconds(5)
            @($got | ForEach-Object severity) | Should -Be @('flag', 'warn')
            # A reload from the files finds the same events.
            $again = Initialize-EventIndex -LogDir $dir2 -Days 31 -Now $T0.AddSeconds(5)
            @($again.Events | ForEach-Object { [long]$_.id }) | Should -Be @($pipe.Index.Events | ForEach-Object { [long]$_.id })
        } finally { Remove-TestDataPath (Split-Path -Parent $dir2) }
    }
    It 'T50-20 an id already in the index is not added twice' {
        $index = Initialize-EventIndex -LogDir $Dir -Days 31 -Now $T0
        $index.Add([ordered]@{ id = 3002; time = 3002; type = 'x'; severity = 'info'; maintenance = $false; data = @{} }) | Should -BeFalse
        $index.Add([ordered]@{ id = 3003; time = 3003; type = 'x'; severity = 'info'; maintenance = $false; data = @{} }) | Should -BeTrue
        $index.Events.Count | Should -Be 25
    }
}

Describe 'T50-21 /events from memory' {
    It 'T50-21 Get-IndexedEvents answers from memory: the file reader is called 0 times per request' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            $day = 86400000L
            $nowMs = $T0.ToUnixTimeMilliseconds()
            $lines = foreach ($i in 0..9) { New-EventLine -Id ($nowMs - (9 - $i) * $day) }
            Write-Lines ([IO.Path]::Combine($dir, 'events-2026-03-01.jsonl')) $lines
            $index = Initialize-EventIndex -LogDir $dir -Days 31 -Now $T0
            Mock -ModuleName EventLog Read-JsonLines { throw 'read a file per request' }
            foreach ($n in 1..5) { $got = Get-IndexedEvents -Index $index -Days 31 -Now $T0 }
            Should -Invoke -ModuleName EventLog Read-JsonLines -Times 0 -Exactly
            $got.Count | Should -Be 10
            [long]$got[0].id | Should -Be $nowMs
            # Days counts today as day 1, from local midnight.
            (Get-IndexedEvents -Index $index -Days 3 -Now $T0).Count | Should -Be 3
            (Get-IndexedEvents -Index $index -Days 1 -Now $T0).Count | Should -Be 1
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T50-21 returns the newest 1000, newest first, and an empty array when there are none' {
        $index = Initialize-EventIndex -LogDir ([IO.Path]::Combine($env:TEMP, 'srrvrr-tests', 'none')) -Days 31 -Now $T0
        $none = Get-IndexedEvents -Index $index -Days 31 -Now $T0
        , $none | Should -BeOfType [object[]]
        $none.Count | Should -Be 0
        $nowMs = $T0.ToUnixTimeMilliseconds()
        foreach ($i in 1..1500) { [void]$index.Add([ordered]@{ id = $nowMs - 1500 + $i; time = $nowMs - 1500 + $i; type = 't'; severity = 'info'; maintenance = $false; data = @{} }) }
        $got = Get-IndexedEvents -Index $index -Days 31 -Now $T0
        $got.Count | Should -Be 1000
        [long]$got[0].id | Should -Be $nowMs
        [long]$got[999].id | Should -Be ($nowMs - 999)
        (Get-IndexedEvents -Index $index -Days 31 -Now $T0 -Limit 10).Count | Should -Be 10
    }
}

Describe 'T50-22 cleanup deletes only matching regular files' {
    BeforeAll {
        # Now is 2026-03-01; with 31 days kept, 2026-01-29 and older go.
        $script:Root = New-TestDataPath
        $script:Logs = Join-Path $Root 'logs'
        $script:Outside = Join-Path $Root 'outside'
        New-Item -ItemType Directory -Path $Outside | Out-Null
        $script:OldMatching = @('events-2026-01-10.jsonl', 'srrvrr-2026-01-10.log', 'events-2026-01-02.log', 'srrvrr-2026-01-29.log')
        $script:NewMatching = @('events-2026-03-01.jsonl', 'srrvrr-2026-03-01.log', 'events-2026-02-28.jsonl', 'srrvrr-2026-01-30.log')
        $script:LookAlikes = @('events-2026-01-01.jsonl.bak', 'events-2026-1-1.jsonl', 'Events-2026-01-01.jsonl', 'srrvrr-2026-13-40.log',
            'notes.txt', 'history.json', 'events-2026-01-03.txt', 'xevents-2026-01-03.jsonl')
        New-Files $Logs ($OldMatching + $NewMatching + $LookAlikes)
        # Age comes from the name: an old name with a new file time goes, a new name with an old file time stays.
        New-Files $Logs @('events-2026-01-11.jsonl', 'events-2026-02-27.jsonl')
        [IO.File]::SetLastWriteTime([IO.Path]::Combine($Logs, 'events-2026-01-11.jsonl'), $T0.LocalDateTime)
        [IO.File]::SetLastWriteTime([IO.Path]::Combine($Logs, 'events-2026-02-27.jsonl'), [DateTime]::new(2020, 1, 1))
        # A subfolder with an old matching file inside, and a folder with a matching name.
        New-Item -ItemType Directory -Path (Join-Path $Logs 'old') | Out-Null
        New-Files (Join-Path $Logs 'old') @('events-2026-01-03.jsonl')
        New-Item -ItemType Directory -Path (Join-Path $Logs 'events-2026-01-04.jsonl') | Out-Null
        # A junction with a matching old name, its target outside logs.
        $script:JunctionTarget = Join-Path $Outside 'junction-target'
        New-Item -ItemType Directory -Path $JunctionTarget | Out-Null
        New-Files $JunctionTarget @('events-2026-01-05.jsonl')
        $script:Junction = Join-Path $Logs 'events-2026-01-05.jsonl'
        cmd /c mklink /J $Junction $JunctionTarget | Out-Null
        # A symbolic link with a matching old name needs admin or developer mode.
        $script:LinkTarget = Join-Path $Outside 'link-target.log'
        [IO.File]::WriteAllText($LinkTarget, "target`r`n")
        $script:Link = Join-Path $Logs 'srrvrr-2026-01-06.log'
        $script:LinkMade = $false
        try { New-Item -ItemType SymbolicLink -Path $Link -Value $LinkTarget -ErrorAction Stop | Out-Null; $script:LinkMade = $true } catch { $script:LinkError = $_.Exception.Message }
        $script:Result = Remove-OldLogs -LogDir $Logs -RetentionDays 31 -Now $T0
    }
    AfterAll {
        if ([IO.Directory]::Exists($Junction)) { [IO.Directory]::Delete($Junction) }   # the link only, not its target
        if ($LinkMade -and [IO.File]::Exists($Link)) { [IO.File]::Delete($Link) }
        Remove-TestDataPath $Root
    }

    It 'T50-22 deletes the matching files older than retention, by the date in the name' {
        @($Result.Deleted | Sort-Object) | Should -Be @(@($OldMatching + 'events-2026-01-11.jsonl') | Sort-Object)
        $Result.Errors.Count | Should -Be 0
        $Result.Skipped | Should -BeFalse
        $left = Get-Names $Logs
        foreach ($n in $OldMatching + 'events-2026-01-11.jsonl') { $left | Should -Not -Contain $n }
    }
    It 'T50-22 keeps new matching files, look-alikes, other files and subfolders' {
        $left = Get-Names $Logs
        foreach ($n in $NewMatching + $LookAlikes + @('events-2026-02-27.jsonl', 'old', 'events-2026-01-04.jsonl')) { $left | Should -Contain $n }
        [IO.File]::Exists([IO.Path]::Combine($Logs, 'old', 'events-2026-01-03.jsonl')) | Should -BeTrue
    }
    It 'T50-22 keeps a junction with a matching old name, its target untouched' {
        [IO.Directory]::Exists($Junction) | Should -BeTrue
        ([IO.File]::GetAttributes($Junction) -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        [IO.File]::Exists([IO.Path]::Combine($JunctionTarget, 'events-2026-01-05.jsonl')) | Should -BeTrue
    }
    It 'T50-22 keeps a symbolic link with a matching old name, its target untouched' {
        if (-not $LinkMade) { Set-ItResult -Skipped -Because "a symbolic link needs admin or developer mode here ($LinkError)"; return }
        [IO.File]::Exists($Link) | Should -BeTrue
        [IO.File]::ReadAllText($LinkTarget) | Should -Be "target`r`n"
    }
}

Describe 'T50-23 the 7-day floor and the boundary' {
    It 'T50-23 with 7 days kept and files for the last 10 days, the newest 7 stay and the one dated exactly 7 days ago goes' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            New-Files $dir @(0..9 | ForEach-Object { 'events-{0}.jsonl' -f $T0.Date.AddDays(-$_).ToString('yyyy-MM-dd') })
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 7 -Now $T0
            @($r.Deleted | Sort-Object) | Should -Be @('events-2026-02-20.jsonl', 'events-2026-02-21.jsonl', 'events-2026-02-22.jsonl')
            (Get-Names $dir).Count | Should -Be 7
            Get-Names $dir | Should -Contain 'events-2026-02-23.jsonl'
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T50-23 fewer days kept than the floor still keeps the newest 7 days' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            New-Files $dir @(0..9 | ForEach-Object { 'srrvrr-{0}.log' -f $T0.Date.AddDays(-$_).ToString('yyyy-MM-dd') })
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 3 -Now $T0
            $r.Deleted.Count | Should -Be 3
            (Get-Names $dir).Count | Should -Be 7
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T50-23 at its edge (newest file exactly 7 days old, 7 kept) the newest 7 days of files are still kept' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            New-Files $dir @(7..16 | ForEach-Object { 'events-{0}.jsonl' -f $T0.Date.AddDays(-$_).ToString('yyyy-MM-dd') })
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 7 -Now $T0
            $r.Skipped | Should -BeFalse
            @($r.Deleted | Sort-Object) | Should -Be @('events-2026-02-13.jsonl', 'events-2026-02-14.jsonl', 'events-2026-02-15.jsonl')
            (Get-Names $dir).Count | Should -Be 7
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T50-24 a wrong clock skips cleanup' {
    It 'T50-24 a clock earlier than the newest file''s date: skipped with one error line, nothing deleted' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            New-Files $dir @('events-2026-03-02.jsonl', 'events-2025-01-01.jsonl', 'srrvrr-2025-01-01.log')
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 31 -Now $T0
            $r.Skipped | Should -BeTrue
            $r.Deleted.Count | Should -Be 0
            $r.Errors.Count | Should -Be 1
            $r.Errors[0] | Should -Match 'earlier'
            (Get-Names $dir).Count | Should -Be 3
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
    It 'T50-24 a clock more than the days kept past the newest file''s date: skipped with one error line, nothing deleted' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            New-Files $dir @('events-2026-01-28.jsonl', 'events-2025-01-01.jsonl')
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 31 -Now $T0
            $r.Skipped | Should -BeTrue
            $r.Deleted.Count | Should -Be 0
            $r.Errors.Count | Should -Be 1
            (Get-Names $dir).Count | Should -Be 2
            # Exactly 31 days past still runs.
            [IO.File]::Delete([IO.Path]::Combine($dir, 'events-2026-01-28.jsonl'))
            New-Files $dir @('events-2026-01-29.jsonl')
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 31 -Now $T0
            $r.Skipped | Should -BeFalse
            $r.Deleted | Should -Be @('events-2025-01-01.jsonl')
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T50-25 when cleanup runs, and a file it cannot delete' {
    It 'T50-25 due right after startup, not 23 h later, due 24 h later' {
        Test-CleanupDue -LastRun $null -Now $T0 | Should -BeTrue
        Test-CleanupDue -LastRun $T0 -Now $T0.AddHours(23) | Should -BeFalse
        Test-CleanupDue -LastRun $T0 -Now $T0.AddHours(24) | Should -BeTrue
    }
    It 'T50-25 a read-only old file is logged and skipped, and cleanup goes on' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        $ro = [IO.Path]::Combine($dir, 'events-2025-01-01.jsonl')
        try {
            New-Files $dir @('events-2025-01-01.jsonl', 'events-2025-01-02.jsonl', 'srrvrr-2025-01-03.log', 'events-2026-03-01.jsonl')
            [IO.File]::SetAttributes($ro, [IO.FileAttributes]::ReadOnly)
            $r = Remove-OldLogs -LogDir $dir -RetentionDays 31 -Now $T0
            @($r.Deleted | Sort-Object) | Should -Be @('events-2025-01-02.jsonl', 'srrvrr-2025-01-03.log')
            $r.Errors.Count | Should -Be 1
            $r.Errors[0] | Should -Match 'events-2025-01-01\.jsonl'
            [IO.File]::Exists($ro) | Should -BeTrue
        } finally {
            if ([IO.File]::Exists($ro)) { [IO.File]::SetAttributes($ro, [IO.FileAttributes]::Normal) }
            Remove-TestDataPath (Split-Path -Parent $dir)
        }
    }
}

Describe 'T50-26 the daily cap on the event log' {
    It 'T50-26 info and warn past 2048 bytes are dropped from the file but kept in memory; a flag is still written' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            Set-Now $T0
            $pipe = New-Pipeline $dir -CapBytes 2048
            $n = 0
            foreach ($i in 1..40) { $n++; Set-Now ($T0.AddSeconds($n)); Send-Event $pipe "e$n" (@('info', 'warn')[$i % 2]) }
            Set-Now ($T0.AddSeconds(100)); Send-Event $pipe 'the-flag' 'flag'
            $lines = [IO.File]::ReadAllLines([IO.Path]::Combine($dir, 'events-2026-03-01.jsonl'))
            @($lines | Where-Object { $_ -match 'daily size cap reached' }).Count | Should -Be 1
            $written = @($lines | Where-Object { $_.StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json })
            $written.Count | Should -BeLessThan 40
            $written[-1].severity | Should -Be 'flag'
            $lines[-1] | Should -Match '"severity":"flag"'
            # Everything is still in memory: the index behind /events and the store behind /stats.
            $pipe.Index.Events.Count | Should -Be 41
            $pipe.Store.Published.Count | Should -Be 41
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}

Describe 'T50-57 a daylight-saving change' {
    It 'T50-57 a 23- and a 25-hour day write to that local date''s file, through the missing and the repeated hour, with ids strictly increasing' {
        $dir = Join-Path (New-TestDataPath) 'logs'
        try {
            Set-Now (Get-Central ([DateTimeOffset]::new(2026, 3, 8, 6, 0, 0, [TimeSpan]::Zero)))
            $pipe = New-Pipeline $dir
            $n = 0
            # Every 30 minutes from local midnight to local midnight on 2026-03-08 (spring forward, 23 h) and
            # 2026-11-01 (fall back, 25 h, 01:00 to 02:00 twice).
            foreach ($start in [DateTimeOffset]::new(2026, 3, 8, 6, 0, 0, [TimeSpan]::Zero), [DateTimeOffset]::new(2026, 11, 1, 5, 0, 0, [TimeSpan]::Zero)) {
                $t = $start
                $day = (Get-Central $start).Date
                while ((Get-Central $t).Date -eq $day) { $n++; Set-Now (Get-Central $t); Send-Event $pipe "k$n"; $t = $t.AddMinutes(30) }
            }
            $n | Should -Be 96
            Get-Names $dir | Should -Be @('events-2026-03-08.jsonl', 'events-2026-11-01.jsonl')
            $spring = @(Read-JsonLines -Path ([IO.Path]::Combine($dir, 'events-2026-03-08.jsonl')))
            $fall = @(Read-JsonLines -Path ([IO.Path]::Combine($dir, 'events-2026-11-01.jsonl')))
            $spring.Count | Should -Be 46
            $fall.Count | Should -Be 50
            # The repeated hour: two events at 01:30 local, an hour apart, both in the 2026-11-01 file.
            $repeated = @($fall | Where-Object { (Get-Central ([DateTimeOffset]::FromUnixTimeMilliseconds($_.time))).ToString('HH:mm') -eq '01:30' })
            $repeated.Count | Should -Be 2
            ([long]$repeated[1].time - [long]$repeated[0].time) | Should -Be 3600000
            # Just before and just after the missing hour, both in the 2026-03-08 file.
            $local = @($spring | ForEach-Object { (Get-Central ([DateTimeOffset]::FromUnixTimeMilliseconds($_.time))).ToString('HH:mm') })
            $local | Should -Contain '01:30'
            $local | Should -Contain '03:00'
            $local | Should -Not -Contain '02:00'
            $ids = @(@($spring) + @($fall) | ForEach-Object { [long]$_.id })
            for ($i = 1; $i -lt $ids.Count; $i++) { $ids[$i] | Should -BeGreaterThan $ids[$i - 1] }
            $indexIds = @($pipe.Index.Events | ForEach-Object { [long]$_.id })
            $indexIds | Should -Be $ids
        } finally { Remove-TestDataPath (Split-Path -Parent $dir) }
    }
}
