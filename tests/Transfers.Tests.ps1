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