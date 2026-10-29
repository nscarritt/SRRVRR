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
