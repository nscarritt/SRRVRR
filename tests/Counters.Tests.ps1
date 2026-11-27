# modules\Counters.psm1: the counter math the fast sampler uses (spec section 1).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module "$PSScriptRoot\fakes\FakeCounterReader.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Counters.psm1') -Force

    function New-Proc($Id, $Name, $CpuSeconds, $WorkingSet, [switch]$Throws) {
        $p = [pscustomobject]@{ Id = $Id; ProcessName = $Name; WorkingSet64 = $WorkingSet }
        if ($Throws) { $p | Add-Member ScriptProperty TotalProcessorTime { throw 'Access is denied' } }
        else { $p | Add-Member NoteProperty TotalProcessorTime ([TimeSpan]::FromSeconds($CpuSeconds)) }
        $p
    }
    $script:Services = @(@{ name = 'Valheim'; icon = 'valheim'; match = 'valheim_server*'; main = 'valheim_server' })
}

Describe 'T47-11 CPU total' {
    It 'T47-11 _Total CPU comes from the change between two snapshots' {
        $prev = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 10; '0' = 5 } } }
        $cur = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 42; '0' = 7 } } }
        $values = Get-CounterDelta -Previous $prev -Current $cur -Category 'Processor' -Counter '% Processor Time'
        Get-CpuTotal -Values $values | Should -Be 42
    }
    It 'T47-11 no previous snapshot gives no values' {
        $cur = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 42 } } }
        (Get-CounterDelta -Previous $null -Current $cur -Category 'Processor' -Counter '% Processor Time').Count | Should -Be 0
    }
    It 'T47-11 an instance missing from the previous snapshot is skipped' {
        $prev = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 1 } } }
        $cur = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 2; '3' = 9 } } }
        $values = Get-CounterDelta -Previous $prev -Current $cur -Category 'Processor' -Counter '% Processor Time'
        $values.ContainsKey('3') | Should -BeFalse
        $values['_Total'] | Should -Be 2
    }
    It 'T47-11 CPU is capped at 100' {
        Get-CpuTotal -Values @{ '_Total' = 104.2 } | Should -Be 100
    }
    It 'T47-11 a fractional CPU total is not rounded by the cap (#81)' {
        Get-CpuTotal -Values @{ '_Total' = 79.9 } | Should -Be 79.9
    }
    It 'T47-11 no percentage cap is written [math]::Min(100, ...) (it would pick the Int32 overload and round, #81)' {
        $hits = Select-String -Path (Join-Path (Get-RepoRoot) 'modules\*.psm1') -Pattern '\[math\]::(Min|Max)\(\s*100\s*,'
        @($hits | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) | Should -BeNullOrEmpty
    }
}

Describe 'T47-12 GPU' {
    BeforeAll {
        $script:Util = @{
            'pid_10_luid_0x00000000_0x0000a1b2_phys_0_eng_0_engtype_3D' = 30
            'pid_11_luid_0x00000000_0x0000a1b2_phys_0_eng_0_engtype_3D' = 25
            'pid_11_luid_0x00000000_0x0000a1b2_phys_0_eng_3_engtype_VideoDecode' = 40
            'pid_12_luid_0x00000000_0x0000ffff_phys_0_eng_0_engtype_3D' = 99
        }
    }
    It 'T47-12 engines are summed across processes and the busiest engine is reported' {
        $g = Get-GpuUsage -Utilization $Util -GpuLuid '0x00000000_0x0000a1b2'
        $g.Gpu | Should -Be 55
        $g.Engine | Should -Be '3D'
    }
    It 'T47-12 the other adapter is excluded and per-process engines are kept' {
        $g = Get-GpuUsage -Utilization $Util -GpuLuid '0x00000000_0x0000a1b2'
        $g.ByProcess.ContainsKey(12) | Should -BeFalse
        $g.ByProcess[11].Count | Should -Be 2
    }
    It 'T47-12 no GPU engine values gives 0 and an empty engine' {
        $g = Get-GpuUsage -Utilization @{} -GpuLuid $null
        $g.Gpu | Should -Be 0
        $g.Engine | Should -Be ''
    }
    It 'T47-12 GPU memory is summed for the chosen adapter only' {
        $mem = @{ 'luid_0x00000000_0x0000a1b2_phys_0' = 1000; 'luid_0x00000000_0x0000a1b2_phys_1' = 500; 'luid_0x00000000_0x0000ffff_phys_0' = 7 }
        Get-GpuMemory -Values $mem -GpuLuid '0x00000000_0x0000a1b2' | Should -Be 1500
    }
}

Describe 'T47-13 process rows' {
    BeforeAll {
        $script:Common = @{ Services = $Services; Elapsed = 2.0; Cores = 4; TotalRam = 1000; GpuByProcess = @{}; Net = $null }
    }
    It 'T47-13 CPU %, cores used and memory % from private working set' {
        $procs = @(New-Proc 10 'valheim_server' 13 999)
        $r = Get-ServiceRows @Common -Processes $procs -PrivateMemory @{ 10 = 250 } -CpuTimes @{ 10 = 11.0 }
        $row = $r.Rows[0]
        $row.online | Should -BeTrue
        $row.cpu | Should -Be 25          # 2 s of CPU / (2 s x 4 cores)
        $row.coresUsed | Should -Be 1
        $row.mem | Should -Be 25          # 250 / 1000
        $r.CpuTimes[10] | Should -Be 13
    }
    It 'T47-13 memory falls back to WorkingSet64 and CPU is capped at 100' {
        $procs = @(New-Proc 10 'valheim_server' 30 400)
        $row = (Get-ServiceRows @Common -Processes $procs -PrivateMemory @{} -CpuTimes @{ 10 = 0.0 }).Rows[0]
        $row.mem | Should -Be 40
        $row.cpu | Should -Be 100
    }
    It 'T47-13 fractional process CPU and GPU are not rounded by the cap (#81)' {
        $procs = @(New-Proc 10 'valheim_server' 6.392 1)   # 6.392 s / (2 s x 4 cores) = 79.9 %
        $c = $Common.Clone(); $c.GpuByProcess = @{ 10 = @{ 'a|0|0' = 79.9 } }
        $row = (Get-ServiceRows @c -Processes $procs -PrivateMemory @{} -CpuTimes @{ 10 = 0.0 }).Rows[0]
        $row.cpu | Should -Be 79.9
        $row.gpu | Should -Be 79.9
    }
    It 'T47-13 the row is offline when the main process is missing' {
        $row = (Get-ServiceRows @Common -Processes @(New-Proc 20 'notepad' 1 1) -PrivateMemory @{} -CpuTimes @{}).Rows[0]
        $row.online | Should -BeFalse
        $row.name | Should -Be 'Valheim'
    }
    It 'T47-13 a process that throws on TotalProcessorTime is skipped, not fatal' {
        $procs = @((New-Proc 10 'valheim_server' 0 100 -Throws), (New-Proc 11 'valheim_server_helper' 3 100))
        $r = Get-ServiceRows @Common -Processes $procs -PrivateMemory @{} -CpuTimes @{ 11 = 1.0 }
        $r.Rows[0].cpu | Should -Be 25
        $r.CpuTimes.ContainsKey(10) | Should -BeFalse
    }
    It 'T47-13 tx and rx are null without the tracer, bytes per second with it' {
        $procs = @(New-Proc 10 'valheim_server' 1 1)
        (Get-ServiceRows @Common -Processes $procs -PrivateMemory @{} -CpuTimes @{}).Rows[0].tx | Should -BeNullOrEmpty
        $net = New-Object 'System.Collections.Generic.Dictionary[int,long[]]'
        $net[10] = [long[]]@(4000, 600)
        $c = $Common.Clone(); $c.Net = $net
        $row = (Get-ServiceRows @c -Processes $procs -PrivateMemory @{} -CpuTimes @{}).Rows[0]
        $row.tx | Should -Be 2000
        $row.rx | Should -Be 300
    }
}

Describe 'T47-15 disk and network' {
    It 'T47-15 only drive letters, upper-cased, appear in diskIO' {
        $reads = @{ 'c:' = 100; 'D:' = 5; 'HarddiskVolume3' = 7; '_Total' = 105 }
        $writes = @{ 'c:' = 1; 'D:' = 2; 'HarddiskVolume3' = 3; '_Total' = 3 }
        $io = Get-DiskIO -Reads $reads -Writes $writes
        @($io.Keys | Sort-Object) | Should -Be @('C:', 'D:')
        $io['C:'].r | Should -Be 100
        $io['C:'].w | Should -Be 1
    }
    It 'T47-15 network bytes are summed over adapters' {
        Get-CounterSum -Values @{ 'eth0' = 100; 'wifi' = 50.4 } | Should -Be 150.4
    }
}

Describe 'T47-16 tick time' {
    It 'T47-16 tickMs is the tick''s own time in whole milliseconds' {
        $state = @{}
        $snap = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 1 } } }
        $ctx = New-FastTickContext -Reader (New-FakeCounterReader @($snap, $snap)) -Processes { @() } -Tracer { $null } `
            -Services @() -TotalRam 1000 -GpuLuid $null -Cores 4 -CpuCounter @('Processor', '% Processor Time') `
            -TickStopwatch (New-FakeStopwatch 37.4) -IntervalStopwatch (New-FakeStopwatch 1000)
        $prev = Invoke-FastTick -State $state -Context $ctx -Previous $null -Now ([DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero))
        $state.tickMs | Should -BeNullOrEmpty -Because 'the first read has nothing to compare with'
        $null = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now ([DateTimeOffset]::new(2026, 1, 5, 12, 0, 1, [TimeSpan]::Zero))
        $state.tickMs | Should -Be 37
        $state.tickMs | Should -BeOfType [int]
    }
}

Describe 'T47-14 the fast tick in a runspace' -Tag 'Integration' {
    It 'T47-14 the state becomes ready, a failed read sets error, and the next tick clears it' {
        $root = Get-RepoRoot
        $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $iss.ImportPSModule(@((Join-Path $root 'modules\Counters.psm1'), (Join-Path $root 'tests\fakes\FakeCounterReader.psm1')))
        $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $state = [hashtable]::Synchronized(@{ ready = $false })
        [void]$ps.AddScript({
            param($state)
            $snap = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 12 } }; 'Memory' = @{ 'Available Bytes' = @{ '' = 400 } } }
            $ctx = New-FastTickContext -Reader (New-FakeCounterReader @($snap) -ThrowOn 3) -Processes { @() } -Tracer { $null } `
                -Services @() -TotalRam 1000 -GpuLuid $null -Cores 4 -CpuCounter @('Processor', '% Processor Time') `
                -TickStopwatch (New-FakeStopwatch 5) -IntervalStopwatch (New-FakeStopwatch 1000)
            $prev = $null
            $log = @()
            foreach ($i in 1..4) {
                $prev = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now ([DateTimeOffset]::new(2026, 1, 5, 12, 0, $i, [TimeSpan]::Zero))
                $log += @{ ready = $state.ready; error = $state.error }
            }
            $log
        }).AddArgument($state)
        try { $log = $ps.Invoke() } finally { $ps.Dispose(); $rs.Close() }
        $log[1].ready | Should -BeTrue
        $log[2].error | Should -Match 'fake counter read failed'
        $log[3].error | Should -BeNullOrEmpty
        $state.cpu | Should -Be 12
        $state.memUsed | Should -Be 600
        $state.ts | Should -Be ([DateTimeOffset]::new(2026, 1, 5, 12, 0, 4, [TimeSpan]::Zero).ToUnixTimeMilliseconds())
    }
}

Describe 'T49-18 the fast tick feeds the history' {
    It 'T49-18 each tick appends cpu, mem (percent of total), gpu, rx and tx' {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
        $h = New-HistoryStore -Slots 5
        $state = @{}
        $snap = New-FakeSnapshot @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 1 } }; 'Memory' = @{ 'Available Bytes' = @{ '' = 250 } } }
        $ctx = New-FastTickContext -Reader (New-FakeCounterReader @($snap, $snap, $snap, $snap)) -Processes { @() } -Tracer { $null } `
            -Services @() -TotalRam 1000 -GpuLuid $null -Cores 4 -CpuCounter @('Processor', '% Processor Time') `
            -TickStopwatch (New-FakeStopwatch 5) -IntervalStopwatch (New-FakeStopwatch 1000) -History $h
        $t = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $prev = $null
        for ($i = 0; $i -lt 4; $i++) { $prev = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now $t.AddSeconds($i) }
        $c = $h.Copy()
        $c.NewestMs | Should -Be $t.AddSeconds(3).ToUnixTimeMilliseconds()
        foreach ($n in 'cpu', 'mem', 'gpu', 'rx', 'tx') { @($c.Lines[$n] | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 3 -Because $n }
        $c.Lines['mem'][-1] | Should -Be ([math]::Round(100 * $state.memUsed / 1000, 1))
    }
}
Describe 'T49-18 ticks on whole seconds' {
    It 'T49-18 the wait reaches 20 ms past the next whole second, whatever time the tick ended' {
        foreach ($ms in 0, 19, 20, 21, 500, 980, 999) {
            $now = [DateTime]::new(2026, 1, 5, 12, 0, 0, $ms, 'Utc')
            $wait = Get-TickWait -Now $now
            $next = $now.AddMilliseconds($wait)
            $next.Millisecond | Should -Be 20 -Because "ended at .$ms"
            $wait | Should -BeGreaterThan 0
            $wait | Should -BeLessOrEqual 1000
        }
    }
}

#region 91
# Video memory on the Workstation (test plan 6.11): shared memory and its history lines in the fast tick, and the
# spill rule (New-SpillWatch, Update-SpillWatch; v0.10.0 plan, Shared interfaces, region 91).
Describe 'T91 video memory in the fast tick' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
        $script:Luid = '0x00000000_0x0000a1b2'
        $script:OtherLuid = '0x00000000_0x0000ffff'
        $script:T91Start = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $script:SevenLines = @('cpu', 'mem', 'gpu', 'rx', 'tx', 'vram', 'vramShared')
        # One reading: GPU Adapter Memory for the chosen card and for another card that holds more. Byte counts are
        # whole sixteenths of a GiB, so the counter math (a float) keeps them exact.
        function New-VramSnapshot([double]$Dedicated, [double]$Shared, [switch]$NoGpuCategory) {
            $data = @{ 'Processor' = @{ '% Processor Time' = @{ '_Total' = 1 } }; 'Memory' = @{ 'Available Bytes' = @{ '' = 250 } } }
            if (-not $NoGpuCategory) {
                $data['GPU Adapter Memory'] = @{
                    'Dedicated Usage' = @{ "luid_${Luid}_phys_0" = $Dedicated; "luid_${OtherLuid}_phys_0" = 3GB }
                    'Shared Usage'    = @{ "luid_${Luid}_phys_0" = $Shared; "luid_${OtherLuid}_phys_0" = 7GB }
                }
            }
            New-FakeSnapshot $data
        }
        # A fast-tick context as SRRVRR.ps1 makes one; Extra adds Workstation and GpuTotal (or nothing: the Server).
        function New-VramContext([object[]]$Snapshots, [hashtable]$Extra = @{}, $History, [string]$GpuLuid = $Luid) {
            $p = @{
                Reader = (New-FakeCounterReader $Snapshots); Processes = { @() }; Tracer = { $null }; Services = @(); TotalRam = 1000
                GpuLuid = $GpuLuid; Cores = 4; CpuCounter = @('Processor', '% Processor Time')
                TickStopwatch = (New-FakeStopwatch 5); IntervalStopwatch = (New-FakeStopwatch 1000); History = $History
            }
            foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
            New-FastTickContext @p
        }
        # The fast tick once a second from T91Start; returns gpuSpill after each tick (the first has no Previous).
        function Invoke-Ticks([hashtable]$State, [hashtable]$Context, [int]$Count) {
            $prev = $null
            for ($i = 0; $i -lt $Count; $i++) {
                $prev = Invoke-FastTick -State $State -Context $Context -Previous $prev -Now $T91Start.AddSeconds($i)
                , $State['gpuSpill']
            }
        }
    }
    It 'T91-01 a Workstation context reads shared memory from the chosen card only and appends vram and vramShared in GiB' {
        $h = New-HistoryStore -Slots 5 -Lines $SevenLines
        $snap = New-VramSnapshot -Dedicated (17.8125 * 1GB) -Shared (1.3125 * 1GB)
        $ctx = New-VramContext @($snap) -Extra @{ Workstation = $true; GpuTotal = 24GB } -History $h
        $ctx.Workstation | Should -Be $true
        $ctx.GpuTotal | Should -Be 24GB
        $ctx.Spill.Spilling | Should -Be $false -Because 'the context starts with a new spill watch'
        $state = @{}
        $null = Invoke-Ticks $state $ctx 2
        $state.error | Should -BeNullOrEmpty
        $state.gpuShared | Should -Be (1.3125 * 1GB) -Because 'the other card''s 7 GiB is left out'
        $state.gpuMem | Should -Be (17.8125 * 1GB)
        $state.gpuSpill | Should -BeOfType [bool]
        $state.gpuSpill | Should -Be $false
        $c = $h.Copy()
        $c.Lines['vram'][-1] | Should -Be 17.81 -Because 'dedicated bytes / 1 GiB, two decimals'
        $c.Lines['vramShared'][-1] | Should -Be 1.31 -Because 'shared bytes / 1 GiB, two decimals'
    }
    It 'T91-01 gpuSpill follows the spill rule tick by tick, from GpuTotal, dedicated and the chosen card''s shared memory' {
        $snap = New-VramSnapshot -Dedicated (23 * 1GB) -Shared (2 * 1GB)   # 95.8% of 24 GiB and 2 GiB shared
        $ctx = New-VramContext @($snap) -Extra @{ Workstation = $true; GpuTotal = 24GB } -History (New-HistoryStore -Slots 30 -Lines $SevenLines)
        $state = @{}
        $spill = @(Invoke-Ticks $state $ctx 14)
        $spill[5] | Should -Be $false -Because 'five seconds in, the 10-second hold is still running'
        $spill[13] | Should -Be $true -Because 'the start condition has held for more than 10 seconds'
        $state.error | Should -BeNullOrEmpty
    }
    It 'T91-01 with no GPU Adapter Memory category (no GPU counters, no GPU picked): gpuShared 0, gpuSpill $false, no error' {
        $snap = New-VramSnapshot -NoGpuCategory
        $ctx = New-VramContext @($snap) -Extra @{ Workstation = $true; GpuTotal = 0 } -History (New-HistoryStore -Slots 30 -Lines $SevenLines) -GpuLuid $null
        $state = @{}
        $spill = @(Invoke-Ticks $state $ctx 14)
        $state.error | Should -BeNullOrEmpty
        $state.ready | Should -Be $true
        $state.gpuShared | Should -Be 0
        $state.gpuSpill | Should -BeOfType [bool]
        $state.gpuSpill | Should -Be $false
        @($spill | Where-Object { $_ -eq $true }).Count | Should -Be 0
    }
    It 'T91-01 a Server context (Workstation $false, or not given) sets neither key and appends neither line' {
        foreach ($extra in @(@{ Workstation = $false; GpuTotal = 24GB }, @{})) {
            $h = New-HistoryStore -Slots 5 -Lines $SevenLines
            $snap = New-VramSnapshot -Dedicated (23 * 1GB) -Shared (2 * 1GB)
            $ctx = New-VramContext @($snap) -Extra $extra -History $h
            $ctx.Workstation | Should -Be $false -Because 'Workstation defaults to $false'
            $state = @{}
            $null = Invoke-Ticks $state $ctx 3
            $state.error | Should -BeNullOrEmpty
            $state.ready | Should -Be $true
            $state.ContainsKey('gpuShared') | Should -BeFalse
            $state.ContainsKey('gpuSpill') | Should -BeFalse
            $c = $h.Copy()
            @($c.Lines['vram'] | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
            @($c.Lines['vramShared'] | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 0
            @($c.Lines['cpu'] | Where-Object { -not [double]::IsNaN($_) }).Count | Should -Be 2
        }
    }
}

Describe 'T91 the spill rule' {
    BeforeAll {
        $script:Total = 24GB
        $script:At95 = $Total * 95 / 100     # exactly the start threshold, worked out as the rule writes it
        $script:At90 = $Total * 90 / 100     # exactly the end threshold
        # Update-SpillWatch once per time in Times with the same reading; each result must be one [bool].
        function Invoke-Readings([hashtable]$Watch, [double]$Dedicated, [double]$Shared, [long[]]$Times, [double]$Total = $script:Total) {
            foreach ($t in $Times) {
                $r = Update-SpillWatch -Watch $Watch -Dedicated $Dedicated -Total $Total -Shared $Shared -NowMs $t
                if ($r -isnot [bool]) { throw "Update-SpillWatch returned '$r' at $t ms, not one [bool]" }
                $r
            }
        }
        function Get-Times([long]$From, [long]$To) { for ($t = $From; $t -le $To; $t += 1000) { $t } }
        function New-SpillingWatch { $w = New-SpillWatch; $w.Spilling = $true; $w }
        $script:Half = $Total * 50 / 100
    }
    It 'T91-02 a new watch is not spilling, with no hold running' {
        $w = New-SpillWatch
        $w | Should -BeOfType [hashtable]
        $w.Spilling | Should -Be $false
        $w.ContainsKey('SinceMs') | Should -BeTrue
        $w.SinceMs | Should -BeNullOrEmpty
        $w.ContainsKey('LastMs') | Should -BeTrue
        $w.LastMs | Should -BeNullOrEmpty
    }
    It 'T91-02 at exactly 95% full and exactly 1 GiB shared, a reading a second: $false until the reading at 10,000 ms, then $true' {
        $w = New-SpillWatch
        $out = @(Invoke-Readings $w $At95 1GB (Get-Times 0 10000))
        $out.Count | Should -Be 11
        for ($i = 0; $i -lt 10; $i++) { $out[$i] | Should -Be $false -Because "at $($i * 1000) ms the hold is under 10 s" }
        $out[10] | Should -Be $true
        $w.Spilling | Should -Be $true
        $w.SinceMs | Should -BeNullOrEmpty -Because 'the hold ends when the state flips'
    }
    It 'T91-02 at 94.99% full, or with 1 GiB minus 1 byte shared, it never starts' {
        $w = New-SpillWatch
        $out = @(Invoke-Readings $w ($Total * 94.99 / 100) 1GB (Get-Times 0 30000))
        $out.Count | Should -Be 31
        $out | Should -Not -Contain $true
        $w.Spilling | Should -Be $false
        $w = New-SpillWatch
        $out = @(Invoke-Readings $w $At95 (1GB - 1) (Get-Times 0 30000))
        $out.Count | Should -Be 31
        $out | Should -Not -Contain $true
        $w.Spilling | Should -Be $false
    }
    It 'T91-03 dedicated at 89.99% for 29,000 ms, then 96%: still spilling, and the end hold starts over' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w ($Total * 89.99 / 100) 2GB (Get-Times 100000 129000))
        $out.Count | Should -Be 30
        $out | Should -Not -Contain $false
        @(Invoke-Readings $w ($Total * 96 / 100) 2GB @(130000)) | Should -Be $true
        $w.SinceMs | Should -BeNullOrEmpty -Because 'a false end condition resets the hold'
        $out = @(Invoke-Readings $w ($Total * 89.99 / 100) 2GB (Get-Times 131000 160000))
        $out.Count | Should -Be 30
        $out | Should -Not -Contain $false -Because 'the 30 s count starts again at 131,000 ms'
    }
    It 'T91-03 dedicated at 89.99% for 30,000 ms: $false at 30,000 ms' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w ($Total * 89.99 / 100) 2GB (Get-Times 100000 130000))
        $out.Count | Should -Be 31
        $out[0..29] | Should -Not -Contain $false
        $out[30] | Should -Be $false
        $w.Spilling | Should -Be $false
        $w.SinceMs | Should -BeNullOrEmpty
    }
    It 'T91-03 shared at 0.5 GiB minus 1 byte for 30,000 ms: $false' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w ($Total * 96 / 100) (512MB - 1) (Get-Times 100000 130000))
        $out.Count | Should -Be 31
        $out[0..29] | Should -Not -Contain $false
        $out[30] | Should -Be $false
    }
    It 'T91-03 shared at exactly 0.5 GiB for 60,000 ms: still spilling' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w ($Total * 96 / 100) 512MB (Get-Times 100000 160000))
        $out.Count | Should -Be 61
        $out | Should -Not -Contain $false
        $w.Spilling | Should -Be $true
    }
    It 'T91-03 dedicated at exactly 90% for 60,000 ms: still spilling (it ends below 90%)' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w $At90 2GB (Get-Times 100000 160000))
        $out.Count | Should -Be 61
        $out | Should -Not -Contain $false
        $w.Spilling | Should -Be $true
    }
    It 'T91-04 the start condition true for 9 s, false once, true for 9 s: never starts' {
        $w = New-SpillWatch
        $out = @(Invoke-Readings $w $At95 2GB (Get-Times 0 9000))
        $out += @(Invoke-Readings $w $Half 2GB @(10000))
        $out += @(Invoke-Readings $w $At95 2GB (Get-Times 11000 20000))
        $out.Count | Should -Be 21
        $out | Should -Not -Contain $true
        $w.Spilling | Should -Be $false
    }
    It 'T91-04 a total of 0, $null or below 0 is always $false and resets the watch, mid-hold or while spilling' {
        foreach ($bad in @(0, $null, -1)) {
            $w = New-SpillWatch
            $null = Invoke-Readings $w $At95 2GB (Get-Times 0 5000)   # a start hold running
            @(Invoke-Readings $w $At95 2GB @(6000) -Total $bad) | Should -Be $false -Because "total '$bad'"
            $w.Spilling | Should -Be $false
            $w.SinceMs | Should -BeNullOrEmpty -Because "total '$bad' resets the hold"
            $out = @(Invoke-Readings $w 30GB 30GB (Get-Times 7000 30000) -Total $bad)
            $out.Count | Should -Be 24
            $out | Should -Not -Contain $true -Because "total '$bad'"
            $w = New-SpillingWatch
            @(Invoke-Readings $w 30GB 30GB @(40000) -Total $bad) | Should -Be $false -Because "total '$bad' forces not spilling"
            $w.Spilling | Should -Be $false
            $w.SinceMs | Should -BeNullOrEmpty
        }
        # After the reset the whole 10 s hold is needed again.
        $w = New-SpillWatch
        $null = Invoke-Readings $w $At95 2GB (Get-Times 0 8000)
        $null = Invoke-Readings $w $At95 2GB @(9000) -Total 0
        $out = @(Invoke-Readings $w $At95 2GB (Get-Times 10000 19000))
        $out.Count | Should -Be 10
        $out | Should -Not -Contain $true
    }
    It 'T91-04 the clock going 5,000 ms back mid start-hold restarts the hold: no exception, no flip' {
        $w = New-SpillWatch
        $out = @(Invoke-Readings $w $At95 2GB (Get-Times 0 6000))
        $out += @(Invoke-Readings $w $At95 2GB @(1000))   # 5,000 ms back
        if ($null -ne $w.SinceMs) { $w.SinceMs | Should -BeLessOrEqual 1000 -Because 'a hold can''t start later than now' }
        $out += @(Invoke-Readings $w $At95 2GB (Get-Times 2000 10000))
        $out.Count | Should -Be 17
        $out | Should -Not -Contain $true -Because 'at 10,000 ms by the clock, the hold has not lasted 10 s since the jump'
        @(Invoke-Readings $w $At95 2GB (Get-Times 11000 20000))[-1] | Should -Be $true -Because 'the restarted hold still completes'
    }
    It 'T91-04 the clock going 5,000 ms back mid end-hold restarts the end hold: still spilling, then the end' {
        $w = New-SpillingWatch
        $out = @(Invoke-Readings $w $Half 2GB (Get-Times 0 20000))
        $out += @(Invoke-Readings $w $Half 2GB @(15000))   # 5,000 ms back
        if ($null -ne $w.SinceMs) { $w.SinceMs | Should -BeLessOrEqual 15000 -Because 'a hold can''t start later than now' }
        $out += @(Invoke-Readings $w $Half 2GB (Get-Times 16000 44000))
        $out.Count | Should -Be 51
        $out | Should -Not -Contain $false -Because 'at 44,000 ms by the clock, the end condition has not held 30 s since the jump'
        @(Invoke-Readings $w $Half 2GB (Get-Times 45000 60000))[-1] | Should -Be $false -Because 'the restarted end hold still completes'
    }
}
#endregion 91