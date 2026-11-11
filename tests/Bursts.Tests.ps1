# modules\Transfers.psm1, region 77: the write-burst detector and its events (v0.9.0 design, sections 4 and 7).
# Readings are built directly as PC seconds, so no server or counter is needed.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Transfers.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    $script:T0 = 1000000000L   # a whole second, in ms
    # One PC's second, as Group-SessionsByPc makes it.
    function New-PcSecond([string]$Address = '192.0.2.10', [int]$Opened = 0, [long]$WriteBps = 1MB, [bool]$Writing = $true, [string]$Key) {
        if (-not $Key) { $Key = $Address }
        @{ key = $Key; address = $Address; sessions = @('1'); readBps = 0; writeBps = $WriteBps; openFiles = 3; filesOpened = $Opened; writing = $Writing }
    }
    # One call of the detector at second N (from T0), with these PC seconds.
    function Step([hashtable]$State, [long]$Second, [object[]]$Pcs, [object[]]$Shares = @(), [int]$Files = 500, [int]$Window = 60, [long]$QuietMs = 300000) {
        , @(Update-WriteBursts -State $State -Pcs $Pcs -Shares $Shares -NowMs ($script:T0 + $Second * 1000) -Files $Files -WindowSeconds $Window -QuietMs $QuietMs)
    }
    function Get-Active($List) { @($List | Where-Object { $null -eq $_.endedMs }) }
    function Get-Ended($List) { @($List | Where-Object { $null -ne $_.endedMs }) }
}

Describe 'T77-01 the threshold' {
    It 'T77-01 499 files in 60 s of writing is no burst; the 500th starts one at that second' {
        $st = @{}
        foreach ($s in 0..8) { $list = Step $st $s @(New-PcSecond -Opened 50) }
        $list = Step $st 9 @(New-PcSecond -Opened 49)
        $list.Count | Should -Be 0
        $list = Step $st 10 @(New-PcSecond -Opened 1)
        $list.Count | Should -Be 1
        $list[0].key | Should -Be '192.0.2.10'
        $list[0].address | Should -Be '192.0.2.10'
        $list[0].startMs | Should -Be ($T0 + 10000)
        $list[0].endedMs | Should -BeNullOrEmpty
        $list[0].files | Should -Be 500
    }
    It 'T77-01 the state is the monitor: the list lands in BurstList too' {
        $monitor = New-TransferMonitor -Settings @{} -Elevated $true
        foreach ($s in 0..9) { Update-WriteBursts -State $monitor -Pcs @((New-PcSecond -Opened 50)) -Shares @() -NowMs ($T0 + $s * 1000) -Files 500 -WindowSeconds 60 -QuietMs 300000 | Out-Null }
        @($monitor.BurstList).Count | Should -Be 1
        $monitor.BurstList[0].startMs | Should -Be ($T0 + 9000)
    }
}

Describe 'T77-02 only writing seconds, only the window' {
    It 'T77-02 files opened in seconds without writing do not count' {
        $st = @{}
        foreach ($s in 0..19) { $list = Step $st $s @(New-PcSecond -Opened 50 -WriteBps 0 -Writing $false) }
        $list.Count | Should -Be 0
        $list = Step $st 20 @(New-PcSecond -Opened 49)
        $list.Count | Should -Be 0
    }
    It 'T77-02 files opened 61 s ago have left the ring; 59 s ago they are still in it' {
        $st = @{}
        $null = Step $st 0 @(New-PcSecond -Opened 450)
        $list = Step $st 59 @(New-PcSecond -Opened 50)
        $list.Count | Should -Be 1
        $st2 = @{}
        $null = Step $st2 0 @(New-PcSecond -Opened 450)
        $list = Step $st2 60 @(New-PcSecond -Opened 50)   # the first slot is the 61st second back: gone
        $list.Count | Should -Be 0
    }
    It 'T77-02 a gap in readings longer than the window empties the ring' {
        $st = @{}
        $null = Step $st 0 @(New-PcSecond -Opened 450)
        (Step $st 500 @(New-PcSecond -Opened 100)).Count | Should -Be 0
    }
}

Describe 'T77-03 the end' {
    It 'T77-03 still active after 4:59 below the threshold, ended with reason quiet at 5:00; files and bytes count from the start' {
        $st = @{}
        foreach ($s in 0..9) { $null = Step $st $s @(New-PcSecond -Opened 50 -WriteBps 2MB) }
        # Writing stops at second 10; the first slot leaves the ring at second 60, so the sum is below 500 from then on.
        foreach ($s in 10..59) { $null = Step $st $s @() }
        $list = Step $st 60 @()
        @(Get-Active $list).Count | Should -Be 1
        $list = Step $st (60 + 299) @()
        @(Get-Active $list).Count | Should -Be 1
        $list = Step $st (60 + 300) @()
        @(Get-Active $list).Count | Should -Be 0
        $e = @(Get-Ended $list)
        $e.Count | Should -Be 1
        $e[0].reason | Should -Be 'quiet'
        $e[0].endedMs | Should -Be ($T0 + 360000)
        $e[0].startMs | Should -Be ($T0 + 9000)
        $e[0].files | Should -Be 500
        $e[0].bytes | Should -Be (10 * 2MB)
    }
    It 'T77-03 files and bytes keep growing while the burst is active' {
        $st = @{}
        foreach ($s in 0..9) { $null = Step $st $s @(New-PcSecond -Opened 50 -WriteBps 1MB) }
        foreach ($s in 10..14) { $list = Step $st $s @(New-PcSecond -Opened 20 -WriteBps 1MB) }
        $list[0].files | Should -Be 600
        $list[0].bytes | Should -Be (15 * 1MB)
    }
}

Describe 'T77-04 one burst or two' {
    It 'T77-04 a rise 3 min after the sum fell below is the same burst; one 6 min after it ended is a new one' {
        $st = @{}
        foreach ($s in 0..9) { $null = Step $st $s @(New-PcSecond -Opened 50) }
        $firstStart = $T0 + 9000
        # The sum is below 500 from second 60; a rise 3 minutes later, at second 240, is the same burst.
        $null = Step $st 60 @()
        $null = Step $st 240 @(New-PcSecond -Opened 500)
        $list = Step $st 241 @()
        @(Get-Active $list).Count | Should -Be 1
        $list[0].startMs | Should -Be $firstStart
        @(Get-Ended $list).Count | Should -Be 0
        # It falls below again at second 300; quiet 5 minutes later, at 600, it ends.
        $null = Step $st 300 @()
        $list = Step $st 600 @()
        $ended = @(Get-Ended $list)
        $ended.Count | Should -Be 1
        $ended[0].startMs | Should -Be $firstStart
        # 6 minutes after it ended: a new burst, with a new start.
        $list = Step $st (600 + 360) @(New-PcSecond -Opened 500)
        @(Get-Active $list).Count | Should -Be 1
        @(Get-Active $list)[0].startMs | Should -Be ($T0 + 960000)
        @(Get-Active $list)[0].startMs | Should -Not -Be $firstStart
    }
}

Describe 'T77-05 independent PCs' {
    It 'T77-05 two PCs burst at once; one that disconnects counts as quiet and ends after the quiet time' {
        $st = @{}
        foreach ($s in 0..9) { $list = Step $st $s @((New-PcSecond '192.0.2.10' -Opened 50), (New-PcSecond '192.0.2.11' -Opened 60)) }
        @(Get-Active $list).Count | Should -Be 2
        @($list | ForEach-Object { $_.key } | Sort-Object) | Should -Be @('192.0.2.10', '192.0.2.11')
        # .11 keeps going; .10 is gone from the readings.
        foreach ($s in 10..69) { $list = Step $st $s @((New-PcSecond '192.0.2.11' -Opened 60)) }
        @(Get-Active $list).Count | Should -Be 2   # .10's files left the ring at second 60: quiet time not yet over
        $list = Step $st (60 + 299) @((New-PcSecond '192.0.2.11' -Opened 60))
        @(Get-Ended $list).Count | Should -Be 0
        $list = Step $st (60 + 300) @((New-PcSecond '192.0.2.11' -Opened 60))
        @(Get-Ended $list).Count | Should -Be 1
        @(Get-Ended $list)[0].key | Should -Be '192.0.2.10'
        @(Get-Active $list).Count | Should -Be 1
        @(Get-Active $list)[0].key | Should -Be '192.0.2.11'
    }
}

Describe 'T77-12 bounds' {
    It 'T77-12 a PC writing nonstop for an hour is one burst, ended once, the quiet time after the ring drains' {
        $st = @{}
        $events = @()
        $old = @()
        $list = @()
        foreach ($s in 0..3599) { $list = Step $st $s @(New-PcSecond -Opened 100); $events += @(Get-BurstEvents -Old $old -New $list); $old = $list }
        @($list).Count | Should -Be 1
        # It stops at second 3600; the ring (100 a second) is below 500 once only 4 writing seconds are left in it.
        foreach ($s in 3600..(3600 + 56 + 300)) { $list = Step $st $s @(); $events += @(Get-BurstEvents -Old $old -New $list); $old = $list }
        @($events | Where-Object { $_.Type -eq 'write-burst' }).Count | Should -Be 1
        @($events | Where-Object { $_.Type -eq 'write-burst-ended' }).Count | Should -Be 1
    }
    It 'T77-12 an ended burst leaves the list 120 s after it ended' {
        $st = @{}
        foreach ($s in 0..9) { $null = Step $st $s @(New-PcSecond -Opened 50) }
        $null = Step $st 60 @()
        $null = Step $st 370 @()   # below since second 60, so it ended at 360; seen at 370
        @(Get-Ended (Step $st 489 @())).Count | Should -Be 1
        (Step $st 490 @()).Count | Should -Be 0
    }
    It 'T77-12 70 PCs bursting: at most 64 are tracked' {
        $st = @{}
        $pcs = @(foreach ($i in 1..70) { New-PcSecond "192.0.2.$i" -Opened 100 })
        foreach ($s in 0..5) { $list = Step $st $s $pcs }
        $list.Count | Should -Be 64
    }
    It 'T77-12 the same address sets one burst per PC key, and an unelevated PC is keyed by its session' {
        $st = @{}
        $pc = New-PcSecond -Address $null -Key 'session:42' -Opened 100
        $pc.address = $null; $pc.sessions = @('42')
        foreach ($s in 0..5) { $list = Step $st $s @($pc) }
        $list.Count | Should -Be 1
        $list[0].key | Should -Be 'session:42'
        $list[0].address | Should -BeNullOrEmpty
        @($list[0].sessions) | Should -Be @('42')
    }
    It 'T77-12 shares are the shares with write traffic while the PC bursts' {
        $st = @{}
        $shares = @(@{ name = 'Photos'; writeBps = 5MB }, @{ name = 'Media'; writeBps = 0 }, @{ name = 'Code'; writeBps = 100 })
        foreach ($s in 0..9) { $list = Step $st $s @(New-PcSecond -Opened 50) $shares }
        @($list[0].shares) | Should -Be @('Code', 'Photos')
    }
}

Describe 'T77-06 the events, one per change' {
    It 'T77-06 none to one burst, the same, then ended: one write-burst, nothing, one write-burst-ended, with the keys' {
        $st = @{}
        foreach ($s in 0..9) { $b1 = Step $st $s @(New-PcSecond -Opened 50) }
        $e = @(Get-BurstEvents -Old @() -New $b1 -PcRows @() -PcFolders @{} -IncludeFolders $true)
        $e.Count | Should -Be 1
        $e[0].Type | Should -Be 'write-burst'
        $e[0].Key | Should -Be ('write-burst|192.0.2.10|' + ($T0 + 9000))
        @(Get-BurstEvents -Old $b1 -New $b1 -PcRows @() -PcFolders @{} -IncludeFolders $true).Count | Should -Be 0
        $null = Step $st 60 @()
        $b2 = Step $st 370 @()
        $e = @(Get-BurstEvents -Old $b1 -New $b2 -PcRows @() -PcFolders @{} -IncludeFolders $true)
        $e.Count | Should -Be 1
        $e[0].Type | Should -Be 'write-burst-ended'
        $e[0].Key | Should -Be ('write-burst-ended|192.0.2.10|' + ($T0 + 9000))
        @(Get-BurstEvents -Old $b2 -New $b2 -PcRows @() -PcFolders @{} -IncludeFolders $true).Count | Should -Be 0
        @(Get-BurstEvents -Old $b2 -New @() -PcRows @() -PcFolders @{} -IncludeFolders $true).Count | Should -Be 0
    }
}

Describe 'T77-07 the event data' {
    BeforeAll {
        $script:Burst = @{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1'); startMs = 5000L; endedMs = $null; files = 612L; bytes = 7340032L; shares = @('Fallback'); reason = $null }
        $script:Folders = @{ '192.0.2.10' = @(
            @{ share = 'Photos'; path = 'Trips\2026'; files = 300; writing = $true; name = 'CanaryFileQx.jpg' }
            @{ share = 'Photos'; path = 'Trips'; files = 200; writing = $true }
            @{ share = 'Code'; path = 'a'; files = 50; writing = $true }
            @{ share = 'Code'; path = 'b'; files = 40; writing = $false }
            @{ share = 'Code'; path = 'c'; files = 30; writing = $false }
            @{ share = 'Code'; path = 'd'; files = 20; writing = $false }
            @{ share = 'Code'; path = 'e'; files = 10; writing = $false }
        ) }
        $script:Rows = @(@{ name = 'Desk PC'; address = '192.0.2.10'; account = 'EXAMPLE\maria'; known = $true }, @{ name = $null; address = '192.0.2.77'; account = 'EXAMPLE\guest'; known = $false })
    }
    It 'T77-07 a named PC: its name, address, account, files, bytes, start, shares from its folders and at most 5 folders with counts' {
        $e = @(Get-BurstEvents -Old @() -New @($Burst) -PcRows $Rows -PcFolders $Folders -IncludeFolders $true)
        $d = $e[0].Data
        $d.pc | Should -Be 'Desk PC'
        $d.address | Should -Be '192.0.2.10'
        $d.account | Should -Be 'EXAMPLE\maria'
        $d.files | Should -Be 612
        $d.bytes | Should -Be 7340032
        $d.startMs | Should -Be 5000
        @($d.shares) | Should -Be @('Code', 'Photos')
        @($d.folders).Count | Should -Be 5
        $d.folders[0].share | Should -Be 'Photos'
        $d.folders[0].path | Should -Be 'Trips\2026'
        $d.folders[0].files | Should -Be 300
        @($d.folders[0].Keys | Sort-Object) | Should -Be @('files', 'path', 'share')
        ($d | ConvertTo-Json -Depth 5 -Compress) | Should -Not -Match 'Canary'
    }
    It 'T77-07 an unknown PC is named "unknown", with its account' {
        $b = $Burst.Clone(); $b.key = '192.0.2.77'; $b.address = '192.0.2.77'
        $d = @(Get-BurstEvents -Old @() -New @($b) -PcRows $Rows -PcFolders @{} -IncludeFolders $true)[0].Data
        $d.pc | Should -Be 'unknown'
        $d.account | Should -Be 'EXAMPLE\guest'
        @($d.shares) | Should -Be @('Fallback')
    }
    It 'T77-07 with folders off there are none, but the counts stay' {
        $d = @(Get-BurstEvents -Old @() -New @($Burst) -PcRows $Rows -PcFolders $Folders -IncludeFolders $false)[0].Data
        @($d.folders).Count | Should -Be 0
        $d.files | Should -Be 612
        $d.pc | Should -Be 'Desk PC'
    }
    It 'T77-07 the ended event adds durationSeconds and reason' {
        $ended = $Burst.Clone(); $ended.endedMs = 125000L; $ended.reason = 'quiet'
        $e = @(Get-BurstEvents -Old @($Burst) -New @($ended) -PcRows $Rows -PcFolders $Folders -IncludeFolders $true)
        $e.Count | Should -Be 1
        $e[0].Data.durationSeconds | Should -Be 120
        $e[0].Data.reason | Should -Be 'quiet'
        $e[0].Data.pc | Should -Be 'Desk PC'
        $e[0].Data.startMs | Should -Be 5000
    }
}

Describe 'T77-08 unelevated' {
    It 'T77-08 no PC rows: "a PC (needs administrator)" with its session, no address, account or folders; shares from the counters' {
        $b = @{ key = 'session:42'; address = $null; sessions = @('42'); startMs = 5000L; endedMs = $null; files = 700L; bytes = 1000L; shares = @('Code'); reason = $null }
        $d = @(Get-BurstEvents -Old @() -New @($b) -PcRows @() -PcFolders @{} -IncludeFolders $true)[0].Data
        $d.pc | Should -Be 'a PC (needs administrator)'
        $d.session | Should -Be '42'
        $d.ContainsKey('address') | Should -BeFalse
        $d.ContainsKey('account') | Should -BeFalse
        $d.ContainsKey('folders') | Should -BeFalse
        @($d.shares) | Should -Be @('Code')
    }
}

Describe 'T77-09 a stop mid-burst' {
    It 'T77-09 -StopMs ends the active burst with reason stopped and leaves the ended one alone' {
        $active = @{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1'); startMs = 5000L; endedMs = $null; files = 600L; bytes = 1L; shares = @('Code'); reason = $null }
        $done = @{ key = '192.0.2.11'; address = '192.0.2.11'; sessions = @('2'); startMs = 1000L; endedMs = 2000L; files = 600L; bytes = 1L; shares = @('Code'); reason = 'quiet' }
        $e = @(Get-BurstEvents -Old @($active, $done) -New @($active, $done) -PcRows @() -PcFolders @{} -IncludeFolders $true -StopMs 65000)
        $e.Count | Should -Be 1
        $e[0].Type | Should -Be 'write-burst-ended'
        $e[0].Key | Should -Be 'write-burst-ended|192.0.2.10|5000'
        $e[0].Data.reason | Should -Be 'stopped'
        $e[0].Data.durationSeconds | Should -Be 60
    }
}

Describe 'T77-10 the event table and the drain' {
    It 'T77-10 both types are flag, banner yes / no, logged' {
        $t = Get-EventTypes
        $t['write-burst'].Severity | Should -Be 'flag'; $t['write-burst'].Banner | Should -BeTrue; $t['write-burst'].Logged | Should -BeTrue
        $t['write-burst-ended'].Severity | Should -Be 'flag'; $t['write-burst-ended'].Banner | Should -BeFalse; $t['write-burst-ended'].Logged | Should -BeTrue
    }
    It 'T77-10 two bursts from one PC 20 minutes apart keep all four events, the second pair marked maintenance' {
        $script:Now = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $clock = { $script:Now }
        $script:Maint = $false
        $store = New-EventStore -Clock $clock
        $q = New-SrrQueue
        $kept = @()
        $record = {
            param($start, $end)
            $b = @{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1'); startMs = $start; endedMs = $null; files = 600L; bytes = 1L; shares = @('Code'); reason = $null }
            $b2 = $b.Clone(); $b2.endedMs = $end; $b2.reason = 'quiet'
            foreach ($r in @((Get-BurstEvents -Old @() -New @($b) -PcRows @() -PcFolders @{} -IncludeFolders $true), (Get-BurstEvents -Old @($b) -New @($b2) -PcRows @() -PcFolders @{} -IncludeFolders $true))) {
                Add-SrrQueueItem -Queue $q -Item (New-TypedEvent -Type $r.Type -Data $r.Data -Key $r.Key)
            }
        }
        & $record 1000L 2000L
        $kept += Invoke-QueueDrain -Queue $q -Store $store -Clock $clock -Maintenance { $script:Maint }
        $script:Now = $script:Now.AddMinutes(20); $script:Maint = $true
        & $record 1200000L 1300000L
        $kept += Invoke-QueueDrain -Queue $q -Store $store -Clock $clock -Maintenance { $script:Maint }
        $store.Published.Count | Should -Be 4
        @($store.Published | ForEach-Object { $_.type }) | Should -Be @('write-burst', 'write-burst-ended', 'write-burst', 'write-burst-ended')
        @($store.Published | ForEach-Object { $_.banner }) | Should -Be @($true, $false, $true, $false)
        @($store.Published | ForEach-Object { $_.logged }) | Should -Be @($true, $true, $true, $true)
        @($store.Published | ForEach-Object { $_.maintenance }) | Should -Be @($false, $false, $true, $true)
    }
}

Describe 'T77-11 the log' {
    It 'T77-11 both flags are written past a full daily cap, keep the account and never a file name' {
        $dir = New-TestDataPath
        try {
            $realClock = { [DateTimeOffset]::Now }
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $realClock -CapBytes 2048
            foreach ($i in 1..40) { $log.Write(('x' * 100), $false) }
            $before = @(Get-ChildItem $dir -Filter 'events-*.jsonl' | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) }).Count
            $store = New-EventStore -Clock $realClock; $q = New-SrrQueue
            $writers = @{ Event = (New-EventLogWriter -Log $log) }
            $b = @{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1'); startMs = 1000L; endedMs = $null; files = 600L; bytes = 1L; shares = @('Code'); reason = $null }
            $b2 = $b.Clone(); $b2.endedMs = 9000L; $b2.reason = 'quiet'
            $folders = @{ '192.0.2.10' = @(@{ share = 'Code'; path = 'src'; files = 600; writing = $true; file = 'CanaryDocQz.docx'; name = 'CanaryDocQz.docx' }) }
            $rows = @(@{ name = 'Desk PC'; address = '192.0.2.10'; account = 'EXAMPLE\maria'; known = $true })
            foreach ($r in @((Get-BurstEvents -Old @() -New @($b) -PcRows $rows -PcFolders $folders -IncludeFolders $true), (Get-BurstEvents -Old @($b) -New @($b2) -PcRows $rows -PcFolders $folders -IncludeFolders $true))) {
                Add-SrrQueueItem -Queue $q -Item (New-TypedEvent -Type $r.Type -Data $r.Data -Key $r.Key)
            }
            Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $realClock | Should -Be 2
            $lines = @(Get-ChildItem $dir -Filter 'events-*.jsonl' | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
            $lines.Count | Should -Be ($before + 2)
            $burstLines = @($lines | Where-Object { $_ -match 'write-burst' })
            $burstLines.Count | Should -Be 2
            foreach ($l in $burstLines) { $l | Should -Match 'EXAMPLE\\\\maria'; $l | Should -Not -Match 'Canary' }
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T77-13 the settings' {
    BeforeAll {
        function New-Config([hashtable]$Values) { $s = Get-SrrDefaultSettings; foreach ($k in $Values.Keys) { $s[$k] = $Values[$k] }; $s }
    }
    It 'T77-13 the defaults are 500, 60 and 5, and the edges are accepted' {
        $d = Get-SrrDefaultSettings
        $d.BurstFiles | Should -Be 500; $d.BurstWindowSeconds | Should -Be 60; $d.BurstQuietMinutes | Should -Be 5
        { Test-SrrSettings (New-Config @{ BurstFiles = 50; BurstWindowSeconds = 10; BurstQuietMinutes = 1 }) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ BurstFiles = 100000; BurstWindowSeconds = 600; BurstQuietMinutes = 60 }) } | Should -Not -Throw
    }
    It 'T77-13 <name> of <value> is refused with one plain message naming its range and default' -ForEach @(
        @{ name = 'BurstFiles'; value = 49; range = '50 to 100000'; default = 500 }, @{ name = 'BurstFiles'; value = 100001; range = '50 to 100000'; default = 500 }
        @{ name = 'BurstFiles'; value = '500'; range = '50 to 100000'; default = 500 }, @{ name = 'BurstFiles'; value = 500.5; range = '50 to 100000'; default = 500 }
        @{ name = 'BurstWindowSeconds'; value = 9; range = '10 to 600'; default = 60 }, @{ name = 'BurstWindowSeconds'; value = 601; range = '10 to 600'; default = 60 }
        @{ name = 'BurstQuietMinutes'; value = 0; range = '1 to 60'; default = 5 }, @{ name = 'BurstQuietMinutes'; value = 61; range = '1 to 60'; default = 5 }
    ) {
        $message = try { Test-SrrSettings (New-Config @{ $name = $value }) | Out-Null; '' } catch { $_.Exception.Message }
        $message | Should -Match "^$name must be a whole number from $range,"
        $message | Should -Match "\(default $default\)\.$"
        $message | Should -Not -Match "`n"
    }
}

Describe 'T77-14 the settings are documented' {
    It 'T77-14 the README table, Alerts and the example config agree with the defaults' {
        $root = Get-RepoRoot
        $readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
        $defaults = Get-SrrDefaultSettings
        $example = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'SRRVRR.config.example.psd1')
        $rows = @{}
        foreach ($m in [regex]::Matches($readme, '(?m)^\| `(\w+)` \| `([^`]*)` \| (.*)\|\s*$')) { $rows[$m.Groups[1].Value] = @{ Default = $m.Groups[2].Value; Text = $m.Groups[3].Value } }
        $ranges = @{ BurstFiles = '50 to 100000'; BurstWindowSeconds = '10 to 600'; BurstQuietMinutes = '1 to 60' }
        foreach ($k in $ranges.Keys) {
            $rows.ContainsKey($k) | Should -BeTrue -Because "$k in the README table"
            $rows[$k].Default | Should -Be ([string]$defaults[$k]) -Because "$k in the README"
            $rows[$k].Text | Should -Match ([regex]::Escape($ranges[$k])) -Because "$k's range in the README"
            $example[$k] | Should -Be $defaults[$k] -Because "$k in the example config"
        }
        $readme | Should -Match 'write-burst-ended'
        $readme | Should -Match '(?i)write burst'
    }
}

Describe 'T77-18 readings every 5 seconds (design Q1)' {
    It 'T77-18 a 5-second reading counts 5 times its per-second files and bytes' {
        $st = @{}
        # 20 files opened a second for 25 s, read every 5 s: 100 per reading, 500 by the fifth.
        foreach ($i in 1..4) { $list = @(Update-WriteBursts -State $st -Pcs @((New-PcSecond -Opened 20 -WriteBps 1000)) -Shares @() -NowMs ($T0 + $i * 5000) -Files 500 -WindowSeconds 60 -QuietMs 300000 -Seconds 5) }
        $list.Count | Should -Be 0
        $list = @(Update-WriteBursts -State $st -Pcs @((New-PcSecond -Opened 20 -WriteBps 1000)) -Shares @() -NowMs ($T0 + 25000) -Files 500 -WindowSeconds 60 -QuietMs 300000 -Seconds 5)
        $list.Count | Should -Be 1
        $list[0].files | Should -Be 500
        $list[0].bytes | Should -Be 25000
    }
    It 'T77-18 the same rate read every second needs no -Seconds and gives the same burst' {
        $st = @{}
        foreach ($s in 1..25) { $list = Step $st $s @(New-PcSecond -Opened 20 -WriteBps 1000) }
        $list.Count | Should -Be 1
        $list[0].files | Should -Be 500
    }
    It 'T77-18 Invoke-TransferTick passes the seconds since its last call' {
        $m = New-TransferMonitor -Settings @{} -Elevated $true
        $m.SessionPcs = @{ '1' = @{ address = '192.0.2.10'; writingFiles = $true } }
        $reading = @{ available = $true; readBps = 0; writeBps = 1000; shares = @(); links = @(); drives = @{}
            sessions = @(@{ id = '1'; readBps = 0; writeBps = 1000; openFiles = 3; filesOpened = 20 }) }
        foreach ($i in 0..5) { Invoke-TransferTick -State @{ cpu = 1 } -Monitor $m -Reading $reading -NowMs ($T0 + $i * 5000) -History $null }
        # 20 a second: the first call counts 1 s (20), the next five 5 s each (100): 520.
        @($m.BurstList).Count | Should -Be 1
        $m.BurstList[0].files | Should -Be 520
    }
}