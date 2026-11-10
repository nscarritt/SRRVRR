# modules\Transfers.psm1 (regions Shared and 76) and the SMB reading in modules\Counters.psm1 (#76, test plan 6.10).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module "$PSScriptRoot\fakes\FakeCounterReader.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Counters.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Transfers.psm1') -Force

    # A counter fixture (tests\fixtures\transfers\counters\<name>.json) as a snapshot: category -> counter -> instance.
    function Read-CounterFixture([string]$Name) {
        $json = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) "tests\fixtures\transfers\counters\$Name.json") -Raw | ConvertFrom-Json
        $data = @{}
        foreach ($cat in $json.PSObject.Properties) {
            if ($cat.Name -eq '_note') { continue }
            $data[$cat.Name] = @{}
            foreach ($counter in $cat.Value.PSObject.Properties) {
                $data[$cat.Name][$counter.Name] = @{}
                foreach ($inst in $counter.Value.PSObject.Properties) { $data[$cat.Name][$counter.Name][$inst.Name] = $inst.Value }
            }
        }
        New-FakeSnapshot $data
    }
}

Describe 'T76-01 SMB reading: shares' {
    BeforeAll { $snap = Read-CounterFixture 'smb-busy'; $script:Reading = Get-SmbCounterReading -Previous $snap -Current $snap }
    It 'T76-01 one row per share by name, IPC$ and _Total dropped, admin shares kept' {
        $script:Reading.available | Should -BeTrue
        $names = @($script:Reading.shares | ForEach-Object { $_.name } | Sort-Object)
        $names | Should -Be @('admin$', 'd$', 'media', 'projects')
    }
    It 'T76-01 each share row has its speeds, open files, seconds per request and queue' {
        $p = @($script:Reading.shares | Where-Object { $_.name -eq 'projects' })[0]
        $p.readBps | Should -Be 3000000
        $p.writeBps | Should -Be 0
        $p.openFiles | Should -Be 4
        $p.secPerRequest | Should -Be 2
        $p.queue | Should -Be 1
        $m = @($script:Reading.shares | Where-Object { $_.name -eq 'media' })[0]
        $m.writeBps | Should -Be 2000000
        $m.queue | Should -Be 3
    }
    It 'T76-01 readBps and writeBps are the share totals' {
        $script:Reading.readBps | Should -Be 3500000
        $script:Reading.writeBps | Should -Be 2000000
    }
}

Describe 'T76-02 SMB reading: sessions' {
    It 'T76-02 one row per session id (a string), _Total dropped, filesOpened rounded' {
        $snap = Read-CounterFixture 'smb-busy'
        $r = Get-SmbCounterReading -Previous $snap -Current $snap
        $rows = @($r.sessions | Sort-Object { $_.id })
        $rows.Count | Should -Be 2
        $rows[0].id | Should -BeOfType [string]
        $rows[0].id | Should -Be '446676598785'
        $rows[0].readBps | Should -Be 3000000
        $rows[0].openFiles | Should -Be 4
        $rows[0].filesOpened | Should -Be 2
        $rows[1].writeBps | Should -Be 2000000
        $rows[1].filesOpened | Should -Be 0
    }
}

Describe 'T76-03 SMB reading: not available' {
    It 'T76-03 without the SMB categories: available false, empty lists, no error' {
        $snap = Read-CounterFixture 'no-smb'
        $r = Get-SmbCounterReading -Previous $snap -Current $snap
        $r.available | Should -BeFalse
        @($r.shares).Count | Should -Be 0
        @($r.sessions).Count | Should -Be 0
        @($r.links).Count | Should -Be 0
        $r.drives.Count | Should -Be 0
    }
    It 'T76-03 a first reading (no previous) is not available either' {
        $r = Get-SmbCounterReading -Previous $null -Current (Read-CounterFixture 'smb-busy')
        $r.available | Should -BeFalse
        @($r.shares).Count | Should -Be 0
    }
    It 'T76-03 the fast tick still sets every other field and calls the hook with the reading and the time' {
        $state = @{}
        $snap = Read-CounterFixture 'no-smb'
        $seen = @{ n = 0 }
        $hook = { param($reading, $now) $seen.n++; $seen.reading = $reading; $seen.now = $now }.GetNewClosure()
        $ctx = New-FastTickContext -Reader (New-FakeCounterReader @($snap, $snap)) -Processes { @() } -Tracer { $null } `
            -Services @() -TotalRam 1000 -GpuLuid $null -Cores 4 -CpuCounter @('Processor', '% Processor Time') `
            -TickStopwatch (New-FakeStopwatch 5) -IntervalStopwatch (New-FakeStopwatch 1000) -Transfers $hook
        $t = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $prev = Invoke-FastTick -State $state -Context $ctx -Previous $null -Now $t
        $null = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now $t.AddSeconds(1)
        $state.ready | Should -BeTrue
        $state.cpu | Should -Be 12
        $state.error | Should -BeNullOrEmpty
        $seen.n | Should -Be 1
        $seen.reading.available | Should -BeFalse
        $seen.now | Should -Be $t.AddSeconds(1)
    }
    It 'T76-03 a hook that throws does not stop the tick: the fields are set and transfersError says why' {
        $state = @{}
        $snap = Read-CounterFixture 'no-smb'
        $ctx = New-FastTickContext -Reader (New-FakeCounterReader @($snap, $snap)) -Processes { @() } -Tracer { $null } `
            -Services @() -TotalRam 1000 -GpuLuid $null -Cores 4 -CpuCounter @('Processor', '% Processor Time') `
            -TickStopwatch (New-FakeStopwatch 5) -IntervalStopwatch (New-FakeStopwatch 1000) -Transfers { throw 'hook broke' }
        $t = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $prev = Invoke-FastTick -State $state -Context $ctx -Previous $null -Now $t
        $null = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now $t.AddSeconds(1)
        $state.ready | Should -BeTrue
        $state.error | Should -BeNullOrEmpty
        $state.transfersError | Should -Match 'hook broke'
    }
}

Describe 'T76-04 SMB reading: links and drives' {
    BeforeAll { $snap = Read-CounterFixture 'smb-busy'; $script:Reading = Get-SmbCounterReading -Previous $snap -Current $snap }
    It 'T76-04 links only for adapters with a Current Bandwidth above zero' {
        @($script:Reading.links).Count | Should -Be 1
        $l = @($script:Reading.links)[0]
        $l.inBps | Should -Be 94000000
        $l.outBps | Should -Be 1000000
        $l.speedBits | Should -Be 1000000000
    }
    It 'T76-04 drives per letter only (volumes and _Total dropped), busy = 100 - idle time, with the queue' {
        $script:Reading.drives.Keys | Sort-Object | Should -Be @('C:', 'D:', 'E:')
        $script:Reading.drives['D:'].busy | Should -Be 98
        $script:Reading.drives['D:'].queue | Should -Be 4
        $script:Reading.drives['E:'].busy | Should -Be 0
    }
}
Describe 'The bottleneck, the share list and the sample (Task 2)' {
    BeforeAll {
        $script:ShareList = @(
            @{ name = 'Projects'; path = 'D:\Projects'; drive = 'D:' }
            @{ name = 'D$'; path = 'D:\'; drive = 'D:' }
            @{ name = 'Library'; path = 'E:\Library'; drive = 'E:' }
        )
        # A reading with one share (drive D:) moving $Traffic bytes a second, the link at $LinkPercent of 1 Gb/s.
        function New-TestReading([double]$LinkPercent = 0, [double]$DriveBusy = 0, [int]$Queue = 0, [double]$Traffic = 2MB, [string]$Share = 'projects') {
            @{
                available = $true; readBps = $Traffic; writeBps = 0
                shares = @(@{ name = $Share; readBps = $Traffic; writeBps = 0; openFiles = 1; secPerRequest = 0; queue = 0 })
                sessions = @(); links = @(@{ inBps = [math]::Round($LinkPercent / 100 * 1e9 / 8); outBps = 0; speedBits = 1e9 })
                drives = @{ 'D:' = @{ busy = $DriveBusy; queue = $Queue }; 'C:' = @{ busy = 99; queue = 9 } }
            }
        }
        function New-TestHold([string]$Shown = 'idle') { @{ Shown = $Shown; Candidate = $Shown; SinceMs = 0L } }
        # The same reading held for four seconds, so the name has passed the 2 s hold.
        function Get-Held($Reading, [double]$Cpu, [int]$Percent = 80, [object[]]$Shares = $script:ShareList) {
            $hold = New-TestHold
            foreach ($t in 0..3) { $b = Get-Bottleneck -Reading $Reading -Shares $Shares -Cpu $Cpu -Percent $Percent -Hold $hold -NowMs ($t * 1000L) }
            $b
        }
    }

    It 'T76-05 names the link, the drive and the CPU in turn, with the other numbers alongside' {
        $b = Get-Held (New-TestReading -LinkPercent 94 -DriveBusy 50 -Queue 1) 60
        $b.name | Should -Be 'link'
        $b.percent | Should -Be 94
        $b.link.percent | Should -Be 94
        $b.link.speedBits | Should -Be 1e9
        $b.link.bytesPerSec | Should -Be 117500000
        $b.drive.percent | Should -Be 50
        $b.cpu.percent | Should -Be 60
        $b = Get-Held (New-TestReading -LinkPercent 30 -DriveBusy 98 -Queue 4) 60
        $b.name | Should -Be 'drive'
        $b.percent | Should -Be 98
        $b.drive.letter | Should -Be 'D:'
        $b.drive.queue | Should -Be 4
        $b.link.percent | Should -Be 30
        $b = Get-Held (New-TestReading -LinkPercent 30 -DriveBusy 50) 91
        $b.name | Should -Be 'cpu'
        $b.percent | Should -Be 91
        $b.cpu.percent | Should -Be 91
    }
    It 'T76-05 the keys are name, percent, link, drive and cpu' {
        (Get-Held (New-TestReading) 10).Keys | Sort-Object | Should -Be @('cpu', 'drive', 'link', 'name', 'percent')
    }
    It 'T76-06 idle below 1 MB/s of share traffic whatever the CPU, named at the floor, none under the threshold' {
        $b = Get-Held (New-TestReading -Traffic 1048575) 100
        $b.name | Should -Be 'idle'
        $b.percent | Should -BeNullOrEmpty
        (Get-Held (New-TestReading -Traffic 1048576) 100).name | Should -Be 'cpu'
        $b = Get-Held (New-TestReading -LinkPercent 79.9 -DriveBusy 10) 20
        $b.name | Should -Be 'none'
        $b.percent | Should -Be 79.9
    }
    It 'T76-06 the threshold is a parameter' {
        (Get-Held (New-TestReading -LinkPercent 60) 10 -Percent 50).name | Should -Be 'link'
        (Get-Held (New-TestReading -LinkPercent 60) 10 -Percent 99).name | Should -Be 'none'
    }
    It 'T76-07 ties go link, drive, CPU' {
        (Get-Held (New-TestReading -LinkPercent 90 -DriveBusy 90) 90).name | Should -Be 'link'
        (Get-Held (New-TestReading -LinkPercent 50 -DriveBusy 90) 90).name | Should -Be 'drive'
    }
    It 'T76-08 the drive is the busiest behind a share with traffic, not a busier one with none' {
        $b = Get-Held (New-TestReading -LinkPercent 10 -DriveBusy 60 -Queue 2) 20
        $b.drive.letter | Should -Be 'D:'
        $b.drive.percent | Should -Be 60
    }
    It 'T76-08 traffic on an admin share counts, and the share list is matched without regard to case' {
        $b = Get-Held (New-TestReading -DriveBusy 70 -Share 'd$') 10
        $b.drive.letter | Should -Be 'D:'
        $b = Get-Held (New-TestReading -DriveBusy 70 -Share 'library') 10
        $b.drive | Should -BeNullOrEmpty -Because 'E: has no reading'
    }
    It 'T76-08 no share list yet: drive is null' {
        $b = Get-Held (New-TestReading -DriveBusy 70) 10 -Shares @()
        $b.drive | Should -BeNullOrEmpty
        $b.cpu.percent | Should -Be 10
    }
    It 'T76-09 a new name is shown only after it has been the raw result for 2 s' {
        $hold = New-TestHold 'none'
        $names = @()
        $calm = New-TestReading -LinkPercent 10
        foreach ($t in 0..3) {
            $r = if ($t -eq 0) { $calm } else { New-TestReading -LinkPercent (90 + $t) }
            $names += (Get-Bottleneck -Reading $r -Shares $script:ShareList -Cpu 10 -Percent 80 -Hold $hold -NowMs ($t * 1000L)).name
        }
        $names | Should -Be @('none', 'none', 'none', 'link')
    }
    It 'T76-09 alternating raw results never change the name, and the numbers change every second' {
        $hold = New-TestHold 'none'
        $seen = @()
        foreach ($t in 0..5) {
            $r = if ($t % 2 -eq 0) { New-TestReading -LinkPercent (85 + $t) } else { New-TestReading -LinkPercent 20 }
            $cpu = if ($t % 2 -eq 0) { 10 } else { 95 }
            $b = Get-Bottleneck -Reading $r -Shares $script:ShareList -Cpu $cpu -Percent 80 -Hold $hold -NowMs ($t * 1000L)
            $b.name | Should -Be 'none'
            $seen += $b.link.percent
        }
        @($seen | Sort-Object -Unique).Count | Should -BeGreaterThan 3
    }
    It 'T76-09 once shown, the old name is left only after the same hold' {
        $hold = New-TestHold 'idle'
        $names = foreach ($t in 0..4) { (Get-Bottleneck -Reading (New-TestReading -Traffic 100) -Shares $script:ShareList -Cpu 10 -Hold $hold -NowMs ($t * 1000L)).name }
        @($names | Sort-Object -Unique) | Should -Be @('idle')
    }

    It 'T76-10 Get-ShareDriveMap: disk and admin shares get their letter, IPC$ and paths without one get null' {
        $win32 = @(
            [pscustomobject]@{ Name = 'Projects'; Path = 'D:\Projects'; Type = [long]0 }
            [pscustomobject]@{ Name = 'Hidden$'; Path = 'e:\hidden'; Type = [long]0 }
            [pscustomobject]@{ Name = 'C$'; Path = 'C:\'; Type = [long]2147483648 }
            [pscustomobject]@{ Name = 'IPC$'; Path = ''; Type = [long]3221225475 }
            [pscustomobject]@{ Name = 'Mounted'; Path = '\\?\Volume{00000000-0000-0000-0000-000000000000}\data'; Type = [long]0 }
        )
        $map = @(Get-ShareDriveMap -Shares $win32)
        $map.Count | Should -Be 5
        @($map | Where-Object { $_.name -eq 'Projects' })[0].drive | Should -Be 'D:'
        @($map | Where-Object { $_.name -eq 'Projects' })[0].path | Should -Be 'D:\Projects'
        @($map | Where-Object { $_.name -eq 'Hidden$' })[0].drive | Should -Be 'E:'
        @($map | Where-Object { $_.name -eq 'C$' })[0].drive | Should -Be 'C:'
        @($map | Where-Object { $_.name -eq 'IPC$' })[0].drive | Should -BeNullOrEmpty
        @($map | Where-Object { $_.name -eq 'Mounted' })[0].drive | Should -BeNullOrEmpty
    }
    It 'T76-10 an empty list gives nothing' {
        @(Get-ShareDriveMap -Shares @()).Count | Should -Be 0
    }

    It 'T76-11 Invoke-TransferSample: the share list at ticks 0 and 12, the CIM lists only elevated and by cadence' {
        $win32 = @([pscustomobject]@{ Name = 'Projects'; Path = 'D:\Projects'; Type = [long]0 })
        foreach ($case in @(@{ Elevated = $true; Busy = $true; Sessions = 14 }, @{ Elevated = $true; Busy = $false; Sessions = 3 }, @{ Elevated = $false; Busy = $true; Sessions = 0 })) {
            $n = @{ shares = 0; sessions = 0; files = 0 }
            $readers = @{
                Shares = { $n.shares++; $win32 }.GetNewClosure()
                Sessions = { $n.sessions++; @() }.GetNewClosure()
                OpenFiles = { $n.files++; @() }.GetNewClosure()
            }
            $m = New-TransferMonitor -Elevated $case.Elevated
            $m.Busy = $case.Busy
            foreach ($tick in 0..13) { Invoke-TransferSample -Monitor $m -Tick $tick -NowMs (1000L * $tick) -Readers $readers }
            $n.shares | Should -Be 2
            $n.sessions | Should -Be $case.Sessions
            $n.files | Should -Be $case.Sessions
            @($m.Shares).Count | Should -Be 1
            $m.Shares[0].drive | Should -Be 'D:'
            if ($case.Elevated) { $m.UpdatedMs | Should -Be $(if ($case.Busy) { 13000 } else { 12000 }) } else { $m.UpdatedMs | Should -BeNullOrEmpty }
        }
    }
    It 'T76-11 a reader that throws reaches the caller and the monitor keeps its last values' {
        $mode = @{ fail = '' }
        $readers = @{
            Shares = { if ($mode.fail -eq 'shares') { throw 'share list failed' }; @([pscustomobject]@{ Name = 'Projects'; Path = 'D:\Projects'; Type = [long]0 }) }.GetNewClosure()
            Sessions = { if ($mode.fail -eq 'sessions') { throw 'session list failed' }; @() }.GetNewClosure()
            OpenFiles = { @() }
        }
        $m = New-TransferMonitor -Elevated $true
        Invoke-TransferSample -Monitor $m -Tick 0 -NowMs 5000 -Readers $readers
        $m.UpdatedMs | Should -Be 5000
        $mode.fail = 'sessions'
        { Invoke-TransferSample -Monitor $m -Tick 6 -NowMs 6000 -Readers $readers } | Should -Throw '*session list failed*'
        $m.UpdatedMs | Should -Be 5000
        @($m.Shares).Count | Should -Be 1
        $mode.fail = 'shares'
        { Invoke-TransferSample -Monitor $m -Tick 12 -NowMs 7000 -Readers $readers } | Should -Throw '*share list failed*'
        $m.UpdatedMs | Should -Be 5000
        @($m.Shares)[0].name | Should -Be 'Projects'
    }

    It 'T76-12 Invoke-TransferTick: exact keys, at most 32 shares busiest first with their drive, unelevated reason' {
        $shares = @()
        foreach ($i in 1..40) {
            $shares += @{ name = "share$i"; readBps = $(if ($i -le 35) { $i * 1000 } else { 0 }); writeBps = 0; openFiles = $(if ($i -gt 35) { 0 } else { 1 }); secPerRequest = 0; queue = 0 }
        }
        $reading = @{ available = $true; readBps = 630000; writeBps = 0; shares = $shares; sessions = @(); links = @(); drives = @{} }
        $m = New-TransferMonitor -Elevated $false
        $m.Shares = @(@{ name = 'Share35'; path = 'D:\s35'; drive = 'D:' })
        $state = @{ cpu = 10 }
        Invoke-TransferTick -State $state -Monitor $m -Reading $reading -NowMs 1000 -History $null
        $t = $state.transfers
        $t.Keys | Sort-Object | Should -Be @('available', 'bottleneck', 'pcs', 'reason', 'shares', 'updatedMs')
        $t.bottleneck.Keys | Sort-Object | Should -Be @('cpu', 'drive', 'link', 'name', 'percent')
        @($t.shares).Count | Should -Be 32
        $t.shares[0].name | Should -Be 'Share35' -Because 'busiest first, spelled as the share list has it'
        $t.shares[0].drive | Should -Be 'D:'
        $t.shares[1].drive | Should -BeNullOrEmpty
        @($t.shares | Where-Object { $_.readBps -eq 0 -and $_.openFiles -eq 0 }).Count | Should -Be 0
        $t.reason | Should -Be 'PCs and folders need administrator'
        $t.available | Should -BeTrue
        @($t.pcs).Count | Should -Be 0
        $m.Busy | Should -BeTrue
    }
    It 'T76-12 without the SMB categories: available false and the reason says so' {
        $m = New-TransferMonitor -Elevated $true
        $state = @{ cpu = 10 }
        $snap = Read-CounterFixture 'no-smb'
        Invoke-TransferTick -State $state -Monitor $m -Reading (Get-SmbCounterReading -Previous $snap -Current $snap) -NowMs 1000 -History $null
        $state.transfers.available | Should -BeFalse
        $state.transfers.reason | Should -Be 'SMB counters are not available'
        @($state.transfers.shares).Count | Should -Be 0
        $state.transfers.bottleneck.name | Should -Be 'idle'
        $m.Busy | Should -BeFalse
    }
    It 'T76-12 elevated and capped: the reason is the open-file cap; elevated and fine: null' {
        $reading = @{ available = $true; readBps = 0; writeBps = 0; shares = @(); sessions = @(); links = @(); drives = @{} }
        $m = New-TransferMonitor -Elevated $true
        $state = @{ cpu = 1 }
        Invoke-TransferTick -State $state -Monitor $m -Reading $reading -NowMs 1000 -History $null
        $state.transfers.reason | Should -BeNullOrEmpty
        $m.OpenFilesCapped = $true; $m.UpdatedMs = 900
        Invoke-TransferTick -State $state -Monitor $m -Reading $reading -NowMs 2000 -History $null
        $state.transfers.reason | Should -Be 'more than 5,000 open files'
        $state.transfers.updatedMs | Should -Be 900
    }
    It 'T76-12 a PC row second: sessions of one address are one PC, a session with no PC is its own row' {
        $sessions = @(
            @{ id = '1'; readBps = 100; writeBps = 0; openFiles = 1; filesOpened = 1 }
            @{ id = '2'; readBps = 50; writeBps = 0; openFiles = 2; filesOpened = 0 }
            @{ id = '3'; readBps = 0; writeBps = 0; openFiles = 0; filesOpened = 0 }
            @{ id = '4'; readBps = 0; writeBps = 10; openFiles = 0; filesOpened = 0 }
        )
        $pcs = @{
            '1' = @{ address = '192.0.2.10'; writingFiles = $false }
            '2' = @{ address = '192.0.2.10'; writingFiles = $true }
            '3' = @{ address = '192.0.2.11'; writingFiles = $false }
        }
        $rows = @(Group-SessionsByPc -Sessions $sessions -SessionPcs $pcs)
        $rows.Count | Should -Be 3
        $a = @($rows | Where-Object { $_.key -eq '192.0.2.10' })[0]
        $a.address | Should -Be '192.0.2.10'
        $a.sessions | Should -Be @('1', '2')
        $a.readBps | Should -Be 150; $a.openFiles | Should -Be 3; $a.filesOpened | Should -Be 1
        $a.writing | Should -BeTrue -Because 'one of its files is open for writing'
        @($rows | Where-Object { $_.key -eq '192.0.2.11' })[0].writing | Should -BeFalse
        $u = @($rows | Where-Object { $_.key -eq 'session:4' })[0]
        $u.address | Should -BeNullOrEmpty
        $u.writing | Should -BeTrue -Because 'its write speed is above zero'
        @(Group-SessionsByPc -Sessions @() -SessionPcs @{}).Count | Should -Be 0
    }
}

Describe 'T76-14 history lines' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
        $script:Dir = New-TestDataPath
    }
    AfterAll { Remove-TestDataPath $script:Dir }
    It 'T76-14 smbRead and smbWrite are registered by default and appended each second from the share totals' {
        $h = New-HistoryStore -Slots 10
        $h.Names | Should -Contain 'smbRead'
        $h.Names | Should -Contain 'smbWrite'
        $m = New-TransferMonitor -Elevated $false
        $reading = @{ available = $true; readBps = 4000; writeBps = 900; shares = @(); sessions = @(); links = @(); drives = @{} }
        $t0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
        Invoke-TransferTick -State @{ cpu = 1 } -Monitor $m -Reading $reading -NowMs $t0 -History $h
        Invoke-TransferTick -State @{ cpu = 1 } -Monitor $m -Reading $reading -NowMs ($t0 + 1000) -History $h
        $c = $h.Copy()
        $c.Lines['smbRead'][-1] | Should -Be 4000
        $c.Lines['smbWrite'][-2] | Should -Be 900
        Invoke-TransferTick -State @{ cpu = 1 } -Monitor $m -Reading @{ available = $false; readBps = 0; writeBps = 0; shares = @(); sessions = @(); links = @(); drives = @{} } -NowMs ($t0 + 2000) -History $h
        [double]::IsNaN($h.Copy().Lines['smbRead'][-1]) | Should -BeTrue -Because 'no SMB counters is a gap, not zero'
    }
    It 'T76-14 a saved file with an unknown extra line loads and the rest is kept' {
        $now = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $future = New-HistoryStore -Slots 5 -Lines @('cpu', 'mem', 'gpu', 'rx', 'tx', 'smbRead', 'smbWrite', 'someLaterLine')
        foreach ($i in 0..4) { foreach ($n in $future.Names) { $future.Append($n, $i + 1, $now.AddSeconds($i).ToUnixTimeMilliseconds()) } }
        (Save-History -Store $future -StatePath (Join-Path $script:Dir 'state')).Ok | Should -BeTrue
        $h = New-HistoryStore -Slots 5
        (Import-History -StatePath (Join-Path $script:Dir 'state') -Store $h -Now $now.AddSeconds(4)).Loaded | Should -BeTrue
        $h.Copy().Lines['cpu'][-1] | Should -Be 5
        $h.Copy().Lines['smbRead'][-1] | Should -Be 5
        $h.Names | Should -Not -Contain 'someLaterLine'
    }
    It 'T76-14 a saved file from before smbRead existed loads, the new lines empty' {
        $now = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $old = New-HistoryStore -Slots 5 -Lines @('cpu', 'mem', 'gpu', 'rx', 'tx')
        foreach ($i in 0..4) { foreach ($n in $old.Names) { $old.Append($n, $i + 1, $now.AddSeconds($i).ToUnixTimeMilliseconds()) } }
        (Save-History -Store $old -StatePath (Join-Path $script:Dir 'state')).Ok | Should -BeTrue
        $h = New-HistoryStore -Slots 5
        (Import-History -StatePath (Join-Path $script:Dir 'state') -Store $h -Now $now.AddSeconds(4)).Loaded | Should -BeTrue
        $h.Copy().Lines['cpu'][-1] | Should -Be 5
        @($h.Copy().Lines['smbRead'] | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
    }
}

Describe 'T76-19 to T76-21 the shared region' {
    It 'T76-19 ConvertTo-PcAddress' {
        ConvertTo-PcAddress '::ffff:192.0.2.10' | Should -Be '192.0.2.10'
        ConvertTo-PcAddress 'fe80::1%12' | Should -Be 'fe80::1'
        ConvertTo-PcAddress '[2001:DB8::A]' | Should -Be '2001:db8::a'
        ConvertTo-PcAddress '192.0.2.10 ' | Should -Be '192.0.2.10'
        ConvertTo-PcAddress 'not-an-ip' | Should -BeNullOrEmpty
        ConvertTo-PcAddress '' | Should -BeNullOrEmpty
    }
    It 'T76-20 Find-NamedPC: listed addresses in any form are known with their name, the server itself is Self' {
        $index = New-NamedPcIndex -NamedPCs @(
            @{ Name = 'Desk PC'; Addresses = @('192.0.2.10', '2001:DB8::A') }
            @{ Name = 'Laptop'; Addresses = @('192.0.2.20') }
        )
        $find = { param($a) Find-NamedPC -Address $a -Index $index -ServerAddresses @('192.0.2.1', '2001:db8::1') }
        foreach ($a in '192.0.2.10', '::FFFF:192.0.2.10', '192.0.2.10 ', '2001:db8::a', '[2001:DB8::A]', 'fe80::1%12') {
            $r = & $find $a
            if ($a -like 'fe80*') { $r.Known | Should -BeFalse; continue }
            $r.Name | Should -Be 'Desk PC' -Because $a
            $r.Known | Should -BeTrue
            $r.Self | Should -BeFalse
        }
        (& $find '192.0.2.20').Name | Should -Be 'Laptop'
        foreach ($a in '127.0.0.1', '::1', '192.0.2.1', '2001:DB8::1', '::ffff:192.0.2.1') {
            $r = & $find $a
            $r.Self | Should -BeTrue -Because $a
            $r.Known | Should -BeTrue
            $r.Name | Should -BeNullOrEmpty
        }
        $r = & $find '192.0.2.99'
        $r.Known | Should -BeFalse; $r.Self | Should -BeFalse; $r.Name | Should -BeNullOrEmpty
        $r = & $find 'garbage'
        $r.Known | Should -BeFalse; $r.Address | Should -BeNullOrEmpty
        (Find-NamedPC -Address '192.0.2.10' -Index @{} -ServerAddresses @('192.0.2.1')).Known | Should -BeFalse
        (Find-NamedPC -Address '192.0.2.1' -Index @{} -ServerAddresses @('192.0.2.1')).Known | Should -BeTrue
    }
    It 'T76-21 New-TransferMonitor: defaults with no v0.9.0 settings' {
        $m = New-TransferMonitor -Elevated $false
        $m.IsSynchronized | Should -BeTrue
        $m.BottleneckPercent | Should -Be 80
        $m.BurstFiles | Should -Be 500
        $m.BurstWindowSeconds | Should -Be 60
        $m.BurstQuietMinutes | Should -Be 5
        $m.TransferFolders | Should -BeTrue
        $m.NamedIndex.Count | Should -Be 0
        $m.Elevated | Should -BeFalse
        $m.Hold.Shown | Should -Be 'idle'
    }
    It 'T76-21 New-TransferMonitor: the given values and the index from NamedPCs' {
        $m = New-TransferMonitor -Elevated $true -ServerAddresses @('192.0.2.1') -Settings @{
            BottleneckPercent = 70; BurstFiles = 100; BurstWindowSeconds = 30; BurstQuietMinutes = 2; TransferFolders = $false
            NamedPCs = @(@{ Name = 'Desk PC'; Addresses = @('192.0.2.10') })
        }
        $m.BottleneckPercent | Should -Be 70
        $m.BurstFiles | Should -Be 100
        $m.BurstWindowSeconds | Should -Be 30
        $m.BurstQuietMinutes | Should -Be 2
        $m.TransferFolders | Should -BeFalse
        $m.NamedIndex['192.0.2.10'] | Should -Be 'Desk PC'
        $m.Elevated | Should -BeTrue
        $m.ServerAddresses | Should -Be @('192.0.2.1')
    }
}
Describe 'T76-13 /stats carries transfers' {
    BeforeAll {
        # The router with a state that holds a transfers value as Invoke-TransferTick builds it.
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Web.psm1') -Force
        $script:Identity = @{ Names = @('localhost'); Addresses = @('127.0.0.1') }
    }
    It 'T76-13 the v0.6.0 shape still holds, and transfers is the new value, at most 6 KB with 4 PCs of 10 folders and 8 shares' {
        $old = @((Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures\stats\v0.6.0-shape.json') | ConvertFrom-Json).paths)
        $state = New-StateFromPaths $old
        $state.tickMs = 37
        $shares = @(foreach ($i in 1..8) { @{ name = "share$i"; readBps = 1000 * $i; writeBps = 500; openFiles = $i; secPerRequest = 0.0042; queue = 1; drive = 'D:' } })
        $pcs = @(foreach ($i in 1..4) {
            @{
                name = "Desk PC $i"; address = "192.0.2.$i"; known = $true; account = "owner$i"; smb = '3.1.1'; signed = $true; encrypted = $false
                readBps = 1000; writeBps = 2000; openFiles = 12; writing = $true; burst = $false
                folders = @(foreach ($f in 1..10) { @{ share = "share$i"; path = "Projects\Client $f\Drafts"; files = 3; writing = $true } })
            }
        })
        $reading = @{ available = $true; readBps = 0; writeBps = 0; shares = @(); sessions = @(); links = @(); drives = @{} }
        $m = New-TransferMonitor -Elevated $true
        $s2 = @{ cpu = 10 }
        Invoke-TransferTick -State $s2 -Monitor $m -Reading $reading -NowMs 1000 -History $null
        $t = $s2.transfers
        $t.shares = $shares; $t.pcs = $pcs
        $state.transfers = $t
        $ctx = @{
            State = $state; WebRoot = (Join-Path (New-TestDataPath) 'web'); Identity = $Identity; Port = 8091
            BootTime = [DateTimeOffset]::new(2026, 1, 5, 11, 0, 0, [TimeSpan]::Zero)
            Clock = { [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero) }
            LogError = { param($message) }
        }
        $r = Invoke-SrrRoute -Method GET -Path '/stats' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $ctx
        $r.Status | Should -Be 200
        $doc = $r.Body | ConvertFrom-Json
        $new = @(Get-JsonPaths $doc)
        @($old | Where-Object { $new -notcontains $_ }) | Should -BeNullOrEmpty
        @($new | Where-Object { $old -notcontains $_ -and $_ -notmatch '^transfers\.' } | Sort-Object -Unique) | Should -Be @('tickMs', 'transfers')
        @($doc.transfers.PSObject.Properties.Name | Sort-Object) | Should -Be @('available', 'bottleneck', 'pcs', 'reason', 'shares', 'updatedMs')
        $json = ConvertTo-Json $t -Depth 8 -Compress
        [Text.Encoding]::UTF8.GetByteCount($json) | Should -BeLessOrEqual 6144
    }
}

Describe 'T76-15 BottleneckPercent' -Tag 'Unit' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
        function New-Config([hashtable]$Values) { $s = Get-SrrDefaultSettings; foreach ($k in $Values.Keys) { $s[$k] = $Values[$k] }; $s }
    }
    It 'T76-15 80 by default; 50 and 99 are accepted' {
        (Get-SrrDefaultSettings).BottleneckPercent | Should -Be 80
        { Test-SrrSettings (New-Config @{}) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ BottleneckPercent = 50 }) } | Should -Not -Throw
        { Test-SrrSettings (New-Config @{ BottleneckPercent = 99 }) } | Should -Not -Throw
    }
    It 'T76-15 49, 100, 80.5 and the text ''80'' are each one plain error naming 50 to 99' {
        foreach ($v in 49, 100, 80.5, '80') {
            { Test-SrrSettings (New-Config @{ BottleneckPercent = $v }) } | Should -Throw '*BottleneckPercent must be a whole number from 50 to 99*' -Because "$v"
        }
    }
    It 'T76-15 an invalid value exits with 2 through Import-SrrSettings' {
        $dir = New-TestDataPath
        try {
            [IO.File]::WriteAllText((Join-Path $dir 'SRRVRR.config.psd1'), '@{ BottleneckPercent = 49 }')
            $e = $null
            try { Import-SrrSettings -Folder $dir | Out-Null } catch { $e = $_.Exception }
            $e | Should -Not -BeNullOrEmpty
            Get-SrrExitCode $e | Should -Be 2
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T76-16 the docs name BottleneckPercent and the SMB counters' {
    BeforeAll { $script:Readme = Get-Content -Raw (Join-Path (Get-RepoRoot) 'README.md') }
    It 'T76-16 the README settings table, the example config and the defaults agree on BottleneckPercent' {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
        $default = (Get-SrrDefaultSettings).BottleneckPercent
        $row = @($Readme -split "`r?`n" | Where-Object { $_ -match '^\| `BottleneckPercent` \|' })
        $row.Count | Should -Be 1
        $row[0] | Should -Match "\| ``$default`` \|"
        $row[0] | Should -Match '50 to 99'
        $example = Import-PowerShellDataFile (Join-Path (Get-RepoRoot) 'SRRVRR.config.example.psd1')
        $example.BottleneckPercent | Should -Be $default
        (Get-Content -Raw (Join-Path (Get-RepoRoot) 'SRRVRR.config.example.psd1')) | Should -Match '50 to 99'
    }
    It 'T76-16 How it works names both SMB categories, transfers, smbRead and smbWrite' {
        $how = $Readme.Substring($Readme.IndexOf('## How it works'))
        foreach ($w in 'SMB Server Shares', 'SMB Server Sessions', '`transfers`', '`smbRead`', '`smbWrite`') { $how.Contains($w) | Should -BeTrue -Because $w }
    }
}

Describe 'T76-22 the wiring' {
    BeforeAll {
        $script:Script = Get-Content -Raw (Join-Path (Get-RepoRoot) 'SRRVRR.ps1')
        $script:Module = Get-Content -Raw (Join-Path (Get-RepoRoot) 'modules\Transfers.psm1')
    }
    It 'T76-22 the module has the regions Shared, 76, 77, 78 and 79 in order' {
        $names = @([regex]::Matches($Module, '(?m)^#region (\S+)') | ForEach-Object { $_.Groups[1].Value })
        $names | Should -Be @('Shared', '76', '77', '78', '79')
    }
    It 'T76-22 no Get-SmbShare, Get-SmbSession or Get-SmbOpenFile anywhere in the code' {
        $files = @('SRRVRR.ps1') + @(Get-ChildItem (Join-Path (Get-RepoRoot) 'modules') -Filter *.psm1 | ForEach-Object { "modules\$($_.Name)" })
        foreach ($f in $files) {
            $text = Get-Content -Raw (Join-Path (Get-RepoRoot) $f)
            $text | Should -Not -Match '\bGet-Smb(Share|Session|OpenFile)\b' -Because $f
        }
    }
    It 'T76-22 SRRVRR.ps1 passes the monitor to both runspaces, imports the module there by full path, and watches transfersError' {
        ([regex]::Matches($Script, "AddArgument\(\`$transferMonitor\)")).Count | Should -Be 2
        ([regex]::Matches($Script, "Import-Module -Name \`$transfersModulePath")).Count | Should -Be 2
        ([regex]::Matches($Script, "AddArgument\(\(Join-Path \`$PSScriptRoot 'modules\\Transfers.psm1'\)\)")).Count | Should -Be 2
        $Script | Should -Match "'tempError', 'transfersError'"
        $Script | Should -Match "-Transfers \`$transfers"
        $Script | Should -Match 'Invoke-TransferTick -State \$state -Monitor \$transferMonitor'
        $Script | Should -Match 'Invoke-TransferSample -Monitor \$transferMonitor'
    }
    It 'T76-22 Invoke-Watch calls Get-BurstEvents and Get-UnknownPcEvents, and a stop saver calls Get-BurstEvents with -StopMs' {
        $ast = Get-ScriptAst (Join-Path (Get-RepoRoot) 'SRRVRR.ps1')
        $watch = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Watch' }, $true)
        $watch.Extent.Text | Should -Match 'Get-BurstEvents'
        $watch.Extent.Text | Should -Match 'Get-UnknownPcEvents'
        $watch.Extent.Text | Should -Not -Match '-StopMs'
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-BurstEvents' }, $true))
        @($calls | Where-Object { $_.Extent.Text -match '-StopMs' }).Count | Should -Be 1
    }
    It 'T76-22 the monitor is made with the server''s addresses and refreshed with the identity' {
        $Script | Should -Match 'New-TransferMonitor -Settings \$settings -Elevated \(Test-Elevated\) -ServerAddresses'
        $Script | Should -Match 'Identity = Get-HostIdentity; \$transferMonitor.ServerAddresses = @\(\$webContext.Identity.Addresses\)'
    }
}
Describe 'T76-11 readers that hand their list back wrapped' {
    It 'T76-11 a share list returned as Get-ShareList does (, @(...)) still maps every share' {
        $readers = @{
            Shares = { , @([pscustomobject]@{ Name = 'Code'; Path = 'H:\Code'; Type = [long]0 }, [pscustomobject]@{ Name = 'Other'; Path = 'E:\x'; Type = [long]0 }) }
            Sessions = { @() }; OpenFiles = { @() }
        }
        $m = New-TransferMonitor -Elevated $false
        Invoke-TransferSample -Monitor $m -Tick 0 -NowMs 1000 -Readers $readers
        @($m.Shares).Count | Should -Be 2
        @($m.Shares | Where-Object { $_.name -eq 'Code' })[0].drive | Should -Be 'H:'
    }
}