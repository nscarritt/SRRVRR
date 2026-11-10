# modules\Transfers.psm1 region 78 (PCs and folders), the CIM readers in modules\DataFolder.psm1, the NamedPCs and
# TransferFolders settings and tools\Export-TransferSample.ps1 (design docs/specs/2026-11-07-srrvrr-v0.9.0-design.md
# sections 3, 4, 6, 7; test plan 6.12). The fixtures in tests\fixtures\transfers\cim\ are made up, with canary file names.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\DataFolder.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Web.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Transfers.psm1') -Force
    $script:Fixtures = Join-Path (Get-RepoRoot) 'tests\fixtures\transfers\cim'
    # ConvertFrom-Json hands a whole array over as one object in 5.1: assign it first, then unroll it.
    function Read-Fixture([string]$Name) { $list = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $script:Fixtures $Name))); @($list) }
    $script:Sessions = @(Read-Fixture 'sessions.json')
    $script:OpenFiles = @(Read-Fixture 'openfiles.json')
    $script:ShareFixture = @(Read-Fixture 'shares.json')
    # The canary file names: the last part of every open file's path.
    $script:Canaries = @($script:OpenFiles | ForEach-Object { ($_.Path -split '\\')[-1] })
    $script:Index = @{ '192.0.2.10' = 'Desk PC' }
    function New-Pcs([hashtable]$Index = $script:Index, [string[]]$Server = @('192.0.2.5'), [bool]$Folders = $true, [object[]]$Files = $script:OpenFiles, [int]$Max = 5000) {
        Get-SessionPcs -Sessions $script:Sessions -OpenFiles $Files -Shares $script:ShareFixture -Index $Index -ServerAddresses $Server -Folders $Folders -MaxOpenFiles $Max
    }
    function New-OpenFile([string]$Session, [string]$Path, [long]$Permissions = 1179785, [bool]$Signed = $true, [bool]$Encrypted = $false) {
        [pscustomobject]@{ SessionId = $Session; Path = $Path; ShareRelativePath = ''; Permissions = $Permissions; Signed = $Signed; Encrypted = $Encrypted }
    }
    function New-Row([string]$Address, [bool]$Known = $false, [bool]$Writing = $false, [string]$Account = 'TESTLAB\user-1') {
        @{ name = $null; address = $Address; known = $Known; account = $Account; smb = '3.1.1'; signed = $true; encrypted = $false; readBps = 0; writeBps = 0; openFiles = 1; writing = $Writing; burst = $false; folders = @() }
    }
    function Get-Json($Value) { ConvertTo-Json -InputObject $Value -Depth 8 -Compress }
}

Describe 'T78-01 sessions to PCs' {
    It 'T78-01 one session PC per session, two sessions from one address share it, addresses are normalized' {
        $r = New-Pcs
        $r.SessionPcs.Count | Should -Be 6
        $r.SessionPcs['1001'].address | Should -Be '192.0.2.10'
        $r.SessionPcs['1002'].address | Should -Be '192.0.2.10'
        $r.SessionPcs['1003'].address | Should -Be 'fe80::5'
        $r.SessionPcs['1004'].address | Should -Be '192.0.2.20'
        $r.SessionPcs['1001'].account | Should -Be 'TESTLAB\desk-user'
        $r.SessionPcs['1004'].smb | Should -Be '3.0.2'
        $r.SessionPcs['1005'].smb | Should -Be '3.1.1'
        @($r.SessionPcs.Values | ForEach-Object { $_.address } | Sort-Object -Unique).Count | Should -Be 5
    }
    It 'T78-01 a session PC has exactly the documented keys' {
        $r = New-Pcs
        (@($r.SessionPcs['1001'].Keys) | Sort-Object) -join ',' | Should -Be 'account,address,encrypted,known,name,signed,smb,writingFiles'
        (@($r.Keys) | Sort-Object) -join ',' | Should -Be 'Capped,PcFolders,SessionPcs'
    }
    It 'T78-01 a session whose client is not an address has no PC address, and no name is looked up' {
        $s = @([pscustomobject]@{ SessionId = '9'; ClientComputerName = 'desk-pc-name'; ClientUserName = 'TESTLAB\x'; Dialect = '3.1.1' })
        $r = Get-SessionPcs -Sessions $s -OpenFiles @() -Shares @() -Index @{} -ServerAddresses @() -Folders $true
        $r.SessionPcs['9'].address | Should -BeNullOrEmpty
        $r.SessionPcs['9'].known | Should -BeFalse
    }
}

Describe 'T78-02 named, server and unknown PCs' {
    It 'T78-02 the named PC has its name and is known; the server itself is known with no name; the others are unknown' {
        $r = New-Pcs
        $r.SessionPcs['1001'].name | Should -Be 'Desk PC'
        $r.SessionPcs['1001'].known | Should -BeTrue
        $r.SessionPcs['1006'].known | Should -BeTrue
        $r.SessionPcs['1006'].name | Should -BeNullOrEmpty
        foreach ($id in '1003', '1004', '1005') { $r.SessionPcs[$id].known | Should -BeFalse -Because $id; $r.SessionPcs[$id].name | Should -BeNullOrEmpty }
    }
}

Describe 'T78-03 signing, encryption and writing from the open files' {
    It 'T78-03 signed, encrypted and writingFiles come from a PC''s open files, $null with none' {
        $r = New-Pcs
        $r.SessionPcs['1001'].signed | Should -BeTrue
        $r.SessionPcs['1001'].encrypted | Should -BeFalse
        $r.SessionPcs['1001'].writingFiles | Should -BeTrue    # one of the PC's files is open for writing (session 1001)
        $r.SessionPcs['1002'].writingFiles | Should -BeTrue    # the same PC: its second session reports the PC's files
        $r.SessionPcs['1003'].encrypted | Should -BeTrue
        $r.SessionPcs['1004'].writingFiles | Should -BeFalse
        $r.SessionPcs['1005'].signed | Should -BeFalse
        $r.SessionPcs['1006'].signed | Should -BeNullOrEmpty    # no open files
        $r.SessionPcs['1006'].encrypted | Should -BeNullOrEmpty
        $r.SessionPcs['1006'].writingFiles | Should -BeFalse
    }
    It 'T78-03 write bits: 0x50000006 in any of its parts counts, a read-only file does not' {
        $s = @([pscustomobject]@{ SessionId = '1'; ClientComputerName = '192.0.2.50'; ClientUserName = 'a'; Dialect = '3.1.1' })
        $shares = @(@{ name = 'S'; path = 'D:\S' })
        foreach ($case in @(@(0x00120089, $false), @(0x00000002, $true), @(0x00000004, $true), @(0x10000000, $true), @(0x40000000, $true), @(0x00000001, $false))) {
            $f = @(New-OpenFile '1' 'D:\S\a\f.bin' ([long]$case[0]))
            $r = Get-SessionPcs -Sessions $s -OpenFiles $f -Shares $shares -Index @{} -ServerAddresses @() -Folders $true
            $r.SessionPcs['1'].writingFiles | Should -Be $case[1] -Because ('{0:X}' -f $case[0])
        }
    }
}

Describe 'T78-04 folders' {
    BeforeAll {
        $script:Sh = @(
            @{ name = 'Media'; path = 'D:\Lab\Media' }, @{ name = 'Archive'; path = 'D:\Lab\Media\Archive' }
            @{ name = 'D$'; path = 'D:\' }, @{ name = 'Docs$'; path = 'D:\Lab\Docs' }, @{ name = 'Docs'; path = 'D:\Lab\Docs' }
        )
        function Get-Folders([object[]]$Files) {
            $s = @([pscustomobject]@{ SessionId = '1'; ClientComputerName = '192.0.2.60'; ClientUserName = 'a'; Dialect = '3.1.1' })
            $r = Get-SessionPcs -Sessions $s -OpenFiles $Files -Shares $script:Sh -Index @{} -ServerAddresses @() -Folders $true
            @($r.PcFolders['192.0.2.60'])
        }
    }
    It 'T78-04 depth 1 to 6: the folder is below the share without the last part, 3 levels at most' {
        $expected = @('', 'a', 'a\b', 'a\b\c', 'a\b\c', 'a\b\c')
        for ($depth = 1; $depth -le 6; $depth++) {
            $parts = @('a', 'b', 'c', 'd', 'e', 'f')[0..($depth - 2)]
            $path = 'D:\Lab\Media\' + $(if ($depth -gt 1) { ($parts -join '\') + '\' } else { '' }) + 'file.bin'
            $rows = @(Get-Folders @(New-OpenFile '1' $path))
            $rows.Count | Should -Be 1
            $rows[0].share | Should -Be 'Media'
            $rows[0].path | Should -Be $expected[$depth - 1] -Because "depth $depth"
        }
    }
    It 'T78-04 a path of 300 characters is cut to 120' {
        $long = 'x' * 100
        $rows = @(Get-Folders @(New-OpenFile '1' "D:\Lab\Media\$long\$long\$long\$('y' * 90).bin"))
        $rows[0].path.Length | Should -Be 120
    }
    It 'T78-04 a file in a share''s root shows as the share, with no path' {
        $rows = @(Get-Folders @(New-OpenFile '1' 'D:\Lab\Media\file.bin'))
        $rows[0].share | Should -Be 'Media'
        $rows[0].path | Should -Be ''
    }
    It 'T78-04 the longest matching share wins (nested shares, an admin share over the same folder), and a share not ending in $ wins a tie' {
        @(Get-Folders @(New-OpenFile '1' 'D:\Lab\Media\Archive\Old\f.bin'))[0].share | Should -Be 'Archive'
        @(Get-Folders @(New-OpenFile '1' 'D:\Other\sub\f.bin'))[0].share | Should -Be 'D$'
        $tie = @(Get-Folders @(New-OpenFile '1' 'D:\Lab\Docs\r\f.bin'))
        $tie.Count | Should -Be 1
        $tie[0].share | Should -Be 'Docs'
    }
    It 'T78-04 a share name does not match a longer folder name (Media vs Media2)' {
        @(Get-Folders @(New-OpenFile '1' 'D:\Lab\Media2\f.bin'))[0].share | Should -Be 'D$'
    }
    It 'T78-04 15 folders for one PC: 10 kept, busiest first, writing marked' {
        $files = @()
        foreach ($i in 1..15) { foreach ($n in 1..$i) { $files += New-OpenFile '1' "D:\Lab\Media\f$i\file$n.bin" } }
        $files += New-OpenFile '1' 'D:\Lab\Media\f3\w.bin' 0x50000006
        $rows = @(Get-Folders $files)
        $rows.Count | Should -Be 10
        $rows[0].path | Should -Be 'f15'
        $rows[0].files | Should -Be 15
        @($rows | ForEach-Object { $_.files }) | Should -Be @($rows | ForEach-Object { $_.files } | Sort-Object -Descending)
        @($rows | Where-Object { $_.writing }).Count | Should -Be 0   # f3 has 4 files: it is not in the top 10
        $again = @(Get-Folders @($files | Where-Object { $_.Path -match '\\f(3|4|5)\\' }))
        @($again | Where-Object { $_.writing }).path | Should -Be 'f3'
        (@($rows[0].Keys) | Sort-Object) -join ',' | Should -Be 'files,path,share,writing'
    }
}

Describe 'T78-05 file names are never kept' {
    It 'T78-05 no canary file name in the session PCs, the folders, the rows, /stats, the monitor or a logged event' {
        $r = New-Pcs
        $pcs = @(@{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1001', '1002'); readBps = 100; writeBps = 5; openFiles = 3; filesOpened = 0; writing = $true },
                 @{ key = '192.0.2.99'; address = '192.0.2.99'; sessions = @('1005'); readBps = 0; writeBps = 9; openFiles = 1; filesOpened = 1; writing = $true })
        $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs $r.SessionPcs -PcFolders $r.PcFolders -Bursts @())
        $monitor = New-TransferMonitor -Elevated $true
        $monitor.SessionPcs = $r.SessionPcs; $monitor.PcFolders = $r.PcFolders
        $seen = @{}
        $events = @(Get-UnknownPcEvents -Seen $seen -PcRows $rows -Elevated $true)
        $logged = @($events | ForEach-Object { Get-Json (ConvertTo-LoggedEvent (New-TypedEvent -Type $_.Type -Data $_.Data -Key $_.Key)) })
        $stats = Get-Json @{ transfers = @{ pcs = $rows; available = $true } }
        $everything = (@(Get-Json $r) + $stats + (Get-Json $monitor) + $logged) -join "`n"
        $events.Count | Should -BeGreaterThan 0
        $script:Canaries.Count | Should -BeGreaterThan 3
        foreach ($c in $script:Canaries) { $everything | Should -Not -Match ([regex]::Escape($c)) -Because $c }
        $everything | Should -Match 'Reports'   # the folders are there
    }
    It 'T78-05 the folder rows hold only the share, the folder, a count and a mark' {
        $r = New-Pcs
        foreach ($rows in $r.PcFolders.Values) { foreach ($row in $rows) { (@($row.Keys) | Sort-Object) -join ',' | Should -Be 'files,path,share,writing' } }
    }
}

Describe 'T78-06 counts only' {
    It 'T78-06 -Folders $false keeps no folders: not in the monitor, not in the rows, not in event data' {
        $r = New-Pcs -Folders $false
        $r.PcFolders.Count | Should -Be 0
        $pcs = @(@{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1001'); readBps = 1; writeBps = 1; openFiles = 2; filesOpened = 0; writing = $true })
        $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs $r.SessionPcs -PcFolders $r.PcFolders -Bursts @())
        @($rows[0].folders).Count | Should -Be 0
        $rows[0].openFiles | Should -Be 2
        $r.SessionPcs['1001'].signed | Should -BeTrue   # the other facts from the files are still kept
    }
}

Describe 'T78-07 bounds' {
    It 'T78-07 5,001 open files: 5,000 used and Capped; 5,000 are not capped' {
        $files = @(1..5001 | ForEach-Object { New-OpenFile '1001' "D:\Lab\Docs\d$($_ % 7)\f$_.bin" })
        $r = New-Pcs -Files $files
        $r.Capped | Should -BeTrue
        (@($r.PcFolders['192.0.2.10'] | ForEach-Object { $_.files } | Measure-Object -Sum).Sum) | Should -Be 5000
        (New-Pcs -Files @($files[0..4999])).Capped | Should -BeFalse
    }
    It 'T78-07 70 PCs: 64 rows, busiest first' {
        $pcs = @(1..70 | ForEach-Object { @{ key = "192.0.2.$_"; address = "192.0.2.$_"; sessions = @("s$_"); readBps = $_ * 10; writeBps = 0; openFiles = 1; filesOpened = 0; writing = $false } })
        $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs @{} -PcFolders @{} -Bursts @())
        $rows.Count | Should -Be 64
        $rows[0].address | Should -Be '192.0.2.70'
        $rows[63].address | Should -Be '192.0.2.7'
        @(Get-TransferPcRows -Pcs $pcs -SessionPcs @{} -PcFolders @{} -Bursts @() -MaxPcs 3).Count | Should -Be 3
    }
}

Describe 'T78-08 the pcs rows' {
    It 'T78-08 the row keys are exactly the documented ones; speeds come from the second; burst is true for that PC only' {
        $r = New-Pcs
        $pcs = @(@{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1001', '1002'); readBps = 1000; writeBps = 20; openFiles = 3; filesOpened = 1; writing = $true },
                 @{ key = '192.0.2.20'; address = '192.0.2.20'; sessions = @('1004'); readBps = 5; writeBps = 0; openFiles = 1; filesOpened = 0; writing = $false })
        $bursts = @(@{ key = '192.0.2.10'; address = '192.0.2.10'; sessions = @('1001'); startMs = 1L; endedMs = $null; files = 600; bytes = 1; shares = @('Docs'); reason = $null },
                    @{ key = '192.0.2.20'; address = '192.0.2.20'; sessions = @('1004'); startMs = 1L; endedMs = 5L; files = 600; bytes = 1; shares = @('Docs'); reason = 'quiet' })
        $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs $r.SessionPcs -PcFolders $r.PcFolders -Bursts $bursts)
        $rows.Count | Should -Be 2
        (@($rows[0].Keys) | Sort-Object) -join ',' | Should -Be 'account,address,burst,encrypted,folders,known,name,openFiles,readBps,signed,smb,writeBps,writing'
        $rows[0].address | Should -Be '192.0.2.10'
        $rows[0].name | Should -Be 'Desk PC'
        $rows[0].account | Should -Be 'TESTLAB\desk-user'
        $rows[0].readBps | Should -Be 1000
        $rows[0].writeBps | Should -Be 20
        $rows[0].openFiles | Should -Be 3
        $rows[0].writing | Should -BeTrue
        $rows[0].burst | Should -BeTrue
        $rows[1].burst | Should -BeFalse   # its burst has ended
        @($rows[0].folders).Count | Should -BeGreaterThan 0
    }
    It 'T78-08 a PC with no session PC (unelevated) still has a row, with no name or account' {
        $pcs = @(@{ key = 'session:7'; address = $null; sessions = @('7'); readBps = 9; writeBps = 0; openFiles = 0; filesOpened = 0; writing = $false })
        $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs @{} -PcFolders @{} -Bursts @())
        $rows.Count | Should -Be 1
        $rows[0].name | Should -BeNullOrEmpty
        $rows[0].known | Should -BeFalse
        @($rows[0].folders).Count | Should -Be 0
    }
}

Describe 'T78-09 unknown PC events' {
    It 'T78-09 unknown-pc once on appearing, unknown-pc-write once on the first write, both again after a reconnect' {
        $seen = @{}
        $out = New-Object System.Collections.Generic.List[object]
        $tick = { param($rows) foreach ($e in @(Get-UnknownPcEvents -Seen $seen -PcRows $rows -Elevated $true)) { $out.Add($e) } }
        & $tick @(New-Row '192.0.2.99')                       # appears
        $out.Count | Should -Be 1
        $out[0].Type | Should -Be 'unknown-pc'
        $out[0].Key | Should -Be 'unknown-pc|192.0.2.99'
        $out[0].Data.pc | Should -Be 'unknown'
        $out[0].Data.address | Should -Be '192.0.2.99'
        $out[0].Data.account | Should -Be 'TESTLAB\user-1'
        & $tick @(New-Row '192.0.2.99')                       # reads
        $out.Count | Should -Be 1
        & $tick @(New-Row '192.0.2.99' -Writing $true)        # first write
        $out.Count | Should -Be 2
        $out[1].Type | Should -Be 'unknown-pc-write'
        $out[1].Key | Should -Be 'unknown-pc-write|192.0.2.99'
        & $tick @(New-Row '192.0.2.99' -Writing $true)        # keeps writing
        $out.Count | Should -Be 2
        & $tick @()                                           # disconnects
        $seen.Count | Should -Be 0
        & $tick @(New-Row '192.0.2.99' -Writing $true)        # reconnects, writing at once
        $out.Count | Should -Be 4
        @($out[2].Type, $out[3].Type) | Should -Be @('unknown-pc', 'unknown-pc-write')
    }
    It 'T78-09 nothing for a named PC, or for any PC unelevated' {
        $seen = @{}
        @(Get-UnknownPcEvents -Seen $seen -PcRows @(New-Row '192.0.2.10' -Known $true -Writing $true) -Elevated $true).Count | Should -Be 0
        @(Get-UnknownPcEvents -Seen $seen -PcRows @(New-Row '192.0.2.99' -Writing $true) -Elevated $false).Count | Should -Be 0
        $seen.Count | Should -Be 0
    }
    It 'T78-09 a row with no address raises nothing' {
        @(Get-UnknownPcEvents -Seen @{} -PcRows @(New-Row $null -Writing $true) -Elevated $true).Count | Should -Be 0
    }
}

Describe 'T78-10 the event table and the repeat rule' {
    It 'T78-10 unknown-pc is a warn with no banner, unknown-pc-write a flag with a banner, both logged, keys by address' {
        $t = Get-EventTypes
        $t['unknown-pc'].Severity | Should -Be 'warn'; $t['unknown-pc'].Banner | Should -BeFalse; $t['unknown-pc'].Logged | Should -BeTrue
        $t['unknown-pc-write'].Severity | Should -Be 'flag'; $t['unknown-pc-write'].Banner | Should -BeTrue; $t['unknown-pc-write'].Logged | Should -BeTrue
    }
    It 'T78-10 a reconnect within 10 minutes is suppressed by the repeat rule, one after 10 minutes is kept' {
        $t0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $box = @{ Now = $t0 }
        $clock = { $box.Now }.GetNewClosure()
        $q = New-SrrQueue; $store = New-EventStore -Clock $clock
        $logged = New-Object System.Collections.Generic.List[object]
        $writers = @{ Event = { param($e) $logged.Add($e) }.GetNewClosure() }
        $seen = @{}
        foreach ($step in @(@(0, $true), @(1, $false), @(2, $true), @(11, $false), @(12, $true))) {
            $box.Now = $t0.AddMinutes($step[0])
            $rows = if ($step[1]) { @(New-Row '192.0.2.99' -Writing $true) } else { @() }
            foreach ($e in @(Get-UnknownPcEvents -Seen $seen -PcRows $rows -Elevated $true)) {
                Add-SrrQueueItem -Queue $q -Item (New-TypedEvent -Type $e.Type -Data $e.Data -Key $e.Key)
            }
            Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $clock | Out-Null
        }
        # connect at 0 (2 events), reconnect at 2 (suppressed: same keys within 10 minutes), reconnect at 12 (kept)
        @($store.Published | Where-Object type -eq 'unknown-pc').Count | Should -Be 2
        @($store.Published | Where-Object type -eq 'unknown-pc-write').Count | Should -Be 2
        @($store.Published | Where-Object type -eq 'unknown-pc' | ForEach-Object time) | Should -Be @($t0.ToUnixTimeMilliseconds(), $t0.AddMinutes(12).ToUnixTimeMilliseconds())
        $logged.Count | Should -Be 4
    }
}

Describe 'T78-11 what the log keeps' {
    It 'T78-11 the four new types keep pc, address and account; a Plex stream event still drops its user' {
        foreach ($type in 'unknown-pc', 'unknown-pc-write', 'write-burst', 'write-burst-ended') {
            if (-not (Get-EventTypes).ContainsKey($type)) { continue }   # the burst types arrive with #77
            $e = New-TypedEvent -Type $type -Data @{ pc = 'unknown'; address = '192.0.2.99'; account = 'TESTLAB\guest-user' } -Key "$type|192.0.2.99"
            $e.id = 5; $e.time = 5
            $l = ConvertTo-LoggedEvent $e
            $l.data['pc'] | Should -Be 'unknown'
            $l.data['address'] | Should -Be '192.0.2.99'
            $l.data['account'] | Should -Be 'TESTLAB\guest-user'
        }
        $plex = New-SrrEvent -Type 'stream-start' -Severity 'info' -Key 'k' -Data @{ user = 'CanaryUserWv'; title = 'CanaryFilmYp'; account = 'kept?' } -Logged $true
        $l = ConvertTo-LoggedEvent $plex
        $l.data.Contains('user') | Should -BeFalse
        $l.data.Contains('title') | Should -BeFalse
    }
}

Describe 'T78-12 the NamedPCs setting' {
    BeforeAll {
        function Test-Named($Value) { $s = Get-SrrDefaultSettings; $s.NamedPCs = $Value; Test-SrrSettings $s | Out-Null }
        function New-Entry([string]$Name, [object[]]$Addresses) { @{ Name = $Name; Addresses = @($Addresses) } }
    }
    It 'T78-12 the default is an empty list, and valid entries (an IPv4 and an IPv6 address) are accepted' {
        (Get-SrrDefaultSettings).ContainsKey('NamedPCs') | Should -BeTrue
        @((Get-SrrDefaultSettings).NamedPCs).Count | Should -Be 0
        { Test-Named @() } | Should -Not -Throw
        { Test-Named @(New-Entry 'Desk PC' @('192.0.2.10', '2001:db8::10')) } | Should -Not -Throw
        { Test-Named @((New-Entry 'A' @('192.0.2.1')), (New-Entry 'B' @('192.0.2.2'))) } | Should -Not -Throw
    }
    It 'T78-12 33 entries is an error, 32 is fine' {
        { Test-Named @(1..32 | ForEach-Object { New-Entry "PC $_" @("192.0.2.$_") }) } | Should -Not -Throw
        { Test-Named @(1..33 | ForEach-Object { New-Entry "PC $_" @("192.0.2.$_") }) } | Should -Throw '*NamedPCs*32*'
    }
    It 'T78-12 a Name that is empty, over 40 characters, has a control character or repeats another (any case) is an error' {
        { Test-Named @(New-Entry '' @('192.0.2.1')) } | Should -Throw '*Name*'
        { Test-Named @(New-Entry ('x' * 41) @('192.0.2.1')) } | Should -Throw '*Name*'
        { Test-Named @(New-Entry ('x' * 40) @('192.0.2.1')) } | Should -Not -Throw
        { Test-Named @(New-Entry "bad$([char]9)name" @('192.0.2.1')) } | Should -Throw '*Name*'
        { Test-Named @((New-Entry 'Desk' @('192.0.2.1')), (New-Entry 'DESK' @('192.0.2.2'))) } | Should -Throw '*Name*'
        { Test-Named @(@{ Addresses = @('192.0.2.1') }) } | Should -Throw '*Name*'
    }
    It 'T78-12 Addresses: none, 9, a range, a subnet, loopback, 0.0.0.0, ::, multicast, a name, a duplicate: one plain error each' {
        { Test-Named @(New-Entry 'A' @()) } | Should -Throw '*Addresses*'
        { Test-Named @(New-Entry 'A' @(1..9 | ForEach-Object { "192.0.2.$_" })) } | Should -Throw '*Addresses*'
        { Test-Named @(New-Entry 'A' @(1..8 | ForEach-Object { "192.0.2.$_" })) } | Should -Not -Throw
        foreach ($bad in '192.0.2.1-192.0.2.9', '192.0.2.0/24', '127.0.0.1', '::1', '0.0.0.0', '::', '224.0.0.1', 'ff02::1', 'desk-pc', '192.0.2', '::ffff:127.0.0.1') {
            { Test-Named @(New-Entry 'A' @($bad)) } | Should -Throw '*Addresses*' -Because $bad
        }
        { Test-Named @(New-Entry 'A' @('192.0.2.1', '192.0.2.1')) } | Should -Throw '*Addresses*'
        { Test-Named @(New-Entry 'A' @('192.0.2.1', '::ffff:192.0.2.1')) } | Should -Throw '*Addresses*'
        { Test-Named @((New-Entry 'A' @('192.0.2.1')), (New-Entry 'B' @('::ffff:192.0.2.1'))) } | Should -Throw '*Addresses*'
    }
    It 'T78-12 an unknown key in an entry, an entry that is not a table, or a setting that is not a list is an error' {
        { Test-Named @(@{ Name = 'A'; Addresses = @('192.0.2.1'); Adress = 'x' }) } | Should -Throw '*Adress*'
        { Test-Named @('192.0.2.1') } | Should -Throw '*NamedPCs*'
        { Test-Named 'Desk' } | Should -Throw '*NamedPCs*'
    }
}

Describe 'T78-13 the TransferFolders setting' {
    It 'T78-13 true by default; false is accepted; ''yes'' and 1 are errors' {
        (Get-SrrDefaultSettings).TransferFolders | Should -BeTrue
        foreach ($ok in $true, $false) { $s = Get-SrrDefaultSettings; $s.TransferFolders = $ok; { Test-SrrSettings $s } | Should -Not -Throw }
        foreach ($bad in 'yes', 1) { $s = Get-SrrDefaultSettings; $s.TransferFolders = $bad; { Test-SrrSettings $s } | Should -Throw '*TransferFolders*' }
    }
}

Describe 'T78-14 one normalized form for addresses' {
    It 'T78-14 the settings check and ConvertTo-PcAddress give the same form for every address' {
        foreach ($a in '192.0.2.10', '::ffff:192.0.2.20', '[fe80::5%3]', 'FE80::ABCD', '2001:DB8::7', '2001:db8:0:0:0:0:0:7', ' 192.0.2.30 ') {
            Get-NormalizedPcAddress $a | Should -Be (ConvertTo-PcAddress $a) -Because $a
        }
        Get-NormalizedPcAddress 'desk-pc' | Should -BeNullOrEmpty
    }
}

Describe 'T78-15 the docs' {
    BeforeAll {
        $script:Readme = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'README.md'))
        $script:Example = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'SRRVRR.config.example.psd1'))
    }
    It 'T78-15 the README settings table and the example config name NamedPCs and TransferFolders with the defaults' {
        $script:Readme | Should -Match '\| `NamedPCs` \| `@\(\)` \|'
        $script:Readme | Should -Match '\| `TransferFolders` \| `\$true` \|'
        $script:Example | Should -Match '(?m)^\s*NamedPCs\s*=\s*@\(\)'
        $script:Example | Should -Match '(?m)^\s*TransferFolders\s*=\s*\$true'
        $script:Example | Should -Match 'Name = ''Desk PC''; Addresses = @\(''192\.0\.2\.10''\)'
    }
    It 'T78-15 What it shows has a PCs paragraph and Administrator vs. not says PCs and folders need administrator' {
        $script:Readme | Should -Match 'never keeps file names'
        $adminSection = [regex]::Match($script:Readme, '(?s)## Administrator vs\. not.*?(?=\r?\n## |\z)').Value
        $adminSection | Should -Match 'PCs and folders need administrator'
    }
    It 'T78-15 the example config and the code agree on the defaults' {
        $d = Get-SrrDefaultSettings
        @($d.NamedPCs).Count | Should -Be 0
        $d.TransferFolders | Should -BeTrue
        $copy = Join-Path (New-TestDataPath) 'SRRVRR.config.psd1'
        try {
            Copy-Item -LiteralPath (Join-Path (Get-RepoRoot) 'SRRVRR.config.example.psd1') -Destination $copy
            { Import-SrrSettings -Folder (Split-Path -Parent $copy) | Out-Null } | Should -Not -Throw
        } finally { Remove-TestDataPath (Split-Path -Parent (Split-Path -Parent $copy)) }
    }
}

Describe 'T78-16 the CIM readers on a real share' -Tag 'Elevated' {
    BeforeAll {
        $script:ShareName = 'srrvrr-t7816'
        $script:ShareDir = Join-Path $env:TEMP 'srrvrr-t7816-share'
        New-Item -ItemType Directory -Force -Path $script:ShareDir | Out-Null
        # Win32_Share.Create, not New-SmbShare: that would load the SmbShare module, which the test checks isn't loaded.
        $null = Invoke-CimMethod -ClassName Win32_Share -MethodName Create -Arguments @{ Name = $script:ShareName; Path = $script:ShareDir; Type = [uint32]0 }
        $script:Stream = [IO.File]::Open("\\localhost\$($script:ShareName)\open.bin", 'Create', 'ReadWrite', 'ReadWrite')
        $script:S = @(Get-SmbSessionList); $script:F = @(Get-SmbOpenFileList)
    }
    AfterAll {
        if ($script:Stream) { $script:Stream.Dispose() }
        Get-CimInstance -ClassName Win32_Share -Filter "Name='$($script:ShareName)'" | Remove-CimInstance
        Remove-Item -LiteralPath $script:ShareDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'T78-16 the lists have the fixtures'' key shape, the file is open for writing and the SmbShare module is not loaded' {
        $script:S.Count | Should -BeGreaterThan 0
        $script:F.Count | Should -BeGreaterThan 0
        (@($script:S[0].PSObject.Properties.Name) | Sort-Object) -join ',' | Should -Be ((@($script:Sessions[0].PSObject.Properties.Name) | Sort-Object) -join ',')
        (@($script:F[0].PSObject.Properties.Name) | Sort-Object) -join ',' | Should -Be ((@($script:OpenFiles[0].PSObject.Properties.Name) | Sort-Object) -join ',')
        $script:S[0].SessionId | Should -BeOfType [string]
        @($script:F | Where-Object { $_.Path -like "*$($script:ShareName)*" -or $_.Path -like '*srrvrr-t7816-share*' -and (([long]$_.Permissions -band 0x50000006) -ne 0) }).Count | Should -BeGreaterThan 0
        Get-Module SmbShare | Should -BeNullOrEmpty
    }
}

Describe 'T78-17 the recording tool' {
    BeforeAll {
        $script:Tool = Join-Path (Get-RepoRoot) 'tools\Export-TransferSample.ps1'
        $script:Raw = Join-Path (New-TestDataPath) 'raw'
        New-Item -ItemType Directory -Force -Path $script:Raw | Out-Null
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText((Join-Path $script:Raw 'sessions.json'), (@'
[
  { "SessionId": "77", "ClientComputerName": "192.168.1.50", "ClientUserName": "HOMEDOM\\jsmith", "Dialect": "3.1.1" },
  { "SessionId": "78", "ClientComputerName": "[fe80::aaaa:bbbb%4]", "ClientUserName": "HOMEDOM\\mjones", "Dialect": "3.0.2" },
  { "SessionId": "79", "ClientComputerName": "192.168.1.50", "ClientUserName": "HOMEDOM\\jsmith", "Dialect": "3.1.1" }
]
'@), $utf8)
        [IO.File]::WriteAllText((Join-Path $script:Raw 'openfiles.json'), (@'
[
  { "SessionId": "77", "Path": "E:\\Family Photos\\Holiday 2025\\IMG_4411_beach.jpg", "ShareRelativePath": "Holiday 2025\\IMG_4411_beach.jpg", "Permissions": 1342177286, "Signed": true, "Encrypted": false },
  { "SessionId": "78", "Path": "E:\\Family Photos\\Taxes\\secret-return.pdf", "ShareRelativePath": "Taxes\\secret-return.pdf", "Permissions": 1179785, "Signed": true, "Encrypted": true }
]
'@), $utf8)
        [IO.File]::WriteAllText((Join-Path $script:Raw 'shares.json'), (@'
[
  { "Name": "FamilyPhotos", "Path": "E:\\Family Photos", "Type": 0 },
  { "Name": "E$", "Path": "E:\\", "Type": 2147483648 },
  { "Name": "IPC$", "Path": "", "Type": 2147483651 }
]
'@), $utf8)
        $script:Out = Join-Path (New-TestDataPath) 'out'
        $script:Before = @(& git -C (Get-RepoRoot) status --porcelain)
        $script:Run = Invoke-InChildPowerShell -File $script:Tool -Arguments @('-FromFolder', $script:Raw, '-OutFolder', $script:Out)
    }
    AfterAll { Remove-TestDataPath (Split-Path -Parent $script:Raw); Remove-TestDataPath (Split-Path -Parent $script:Out) }
    It 'T78-17 it writes three files, replaces names, accounts and paths, and maps addresses into the documentation ranges' {
        $script:Run.ExitCode | Should -Be 0
        $text = ''
        foreach ($n in 'sessions.json', 'openfiles.json', 'shares.json') {
            $p = Join-Path $script:Out $n
            Test-Path -LiteralPath $p | Should -BeTrue -Because $n
            $text += [IO.File]::ReadAllText($p)
        }
        foreach ($real in 'jsmith', 'mjones', 'HOMEDOM', 'Family', 'Photos', 'Holiday', 'IMG_4411', 'beach', 'Taxes', 'secret', 'return', '192.168.1.50', 'aaaa:bbbb', 'FamilyPhotos') {
            $text | Should -Not -Match ([regex]::Escape($real)) -Because $real
        }
        $sessions = @(ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $script:Out 'sessions.json'))))
        $s = @($sessions[0])
        @($s | ForEach-Object { $_.ClientComputerName }) | Should -Be @('192.0.2.10', '2001:db8::2', '192.0.2.10')
        $s[0].ClientUserName | Should -Match '^TESTLAB\\user-\d+$'
        $s[0].ClientUserName | Should -Be $s[2].ClientUserName
    }
    It 'T78-17 the same real thing becomes the same made-up thing, so a file still nests in its share' {
        $files = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $script:Out 'openfiles.json')))
        $shares = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $script:Out 'shares.json')))
        $family = @($shares | Where-Object { $_.Name -like 'share-*' -and -not $_.Name.EndsWith('$') })
        $family.Count | Should -Be 1
        @($files)[0].Path.StartsWith($family[0].Path + '\') | Should -BeTrue
        @($shares | Where-Object Name -eq 'IPC$').Count | Should -Be 1
        @($shares | Where-Object { $_.Name -match '^share-\d+\$$' }).Count | Should -Be 1
    }
    It 'T78-17 it compares the key shapes with the fixtures, and writes nothing inside the repo' {
        $script:Run.Output | Should -Match 'Key shapes match the fixtures'
        @(& git -C (Get-RepoRoot) status --porcelain) | Should -Be $script:Before
        $r = Invoke-InChildPowerShell -File $script:Tool -Arguments @('-FromFolder', $script:Raw, '-OutFolder', (Join-Path (Get-RepoRoot) 'out\sample'))
        $r.ExitCode | Should -Be 2
        $r.Output | Should -Match 'inside the SRRVRR repo'
        Test-Path -LiteralPath (Join-Path (Get-RepoRoot) 'out\sample') | Should -BeFalse
    }
    It 'T78-17 unelevated and with no input folder it refuses with a plain message and writes nothing' {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) { Set-ItResult -Skipped -Because 'this run is elevated'; return }
        $out = Join-Path (New-TestDataPath) 'refused'
        try {
            $r = Invoke-InChildPowerShell -File $script:Tool -Arguments @('-OutFolder', $out)
            $r.ExitCode | Should -Be 2
            $r.Output | Should -Match 'need administrator'
            Test-Path -LiteralPath $out | Should -BeFalse
        } finally { Remove-TestDataPath (Split-Path -Parent $out) }
    }
}

Describe 'T78-20 /stats with every bound full' {
    It 'T78-20 64 PCs with 10 folders of 120 characters, and 32 shares: /stats p95 within 30 ms, and the folders are serialized in full' {
        $folders = @(1..10 | ForEach-Object { @{ share = 'ShareName1'; path = ('a' * 38) + '\' + ('b' * 38) + '\' + ('c' * 38); files = 20 - $_; writing = ($_ -eq 1) } })
        $pcs = @(1..64 | ForEach-Object { @{ name = "PC $_"; address = "192.0.2.$_"; known = $true; account = "TESTLAB\user-$_"; smb = '3.1.1'; signed = $true; encrypted = $false; readBps = 1000 * $_; writeBps = 10; openFiles = 40; writing = $true; burst = $false; folders = $folders } })
        $shares = @(1..32 | ForEach-Object { @{ name = "share-$_"; path = "D:\Lab\share-$_"; drive = 'D:'; readBps = 100; writeBps = 10; openFiles = 4; secPerRequest = 0.001; queue = 0 } })
        $state = [hashtable]::Synchronized(@{ ready = $true; cpu = 3; transfers = @{ available = $true; reason = $null; bottleneck = @{ name = 'idle' }; shares = $shares; pcs = $pcs; updatedMs = 1L } })
        $errors = New-Object System.Collections.Generic.List[string]
        $c = @{
            State = $state; WebRoot = $env:TEMP; Identity = @{ Names = @('SRRVRR'); Addresses = @('10.0.0.5') }; Port = 8091
            BootTime = [DateTimeOffset]::new(2026, 1, 5, 11, 0, 0, [TimeSpan]::Zero)
            Clock = { [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero) }; LogError = { param($m) $errors.Add($m) }.GetNewClosure(); Errors = $errors
        }
        $call = { Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c }
        foreach ($i in 1..5) { $null = & $call }
        $times = foreach ($i in 1..100) { (Measure-Command { $null = & $call }).TotalMilliseconds }
        $r = & $call
        $r.Status | Should -Be 200
        $doc = $r.Body | ConvertFrom-Json
        @($doc.transfers.pcs).Count | Should -Be 64
        @($doc.transfers.pcs[63].folders).Count | Should -Be 10
        $doc.transfers.pcs[63].folders[0].path.Length | Should -BeGreaterThan 100
        $p95 = @($times | Sort-Object)[[int][Math]::Ceiling(0.95 * @($times).Count) - 1]
        Write-Host ("    T78-20: /stats {0:N0} bytes with every bound full, p95 {1:N1} ms" -f $r.Body.Length, $p95)
        if (-not $env:GITHUB_ACTIONS) { $p95 | Should -BeLessThan 30 }   # informational on CI's shared runners, a budget on the server
    }
}
