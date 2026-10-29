# Counter math for the samplers. Counters are read a whole category at a time, and each value is worked out
# from the change since the previous read. Snapshots are shaped like PerformanceCounterCategory.ReadCategory():
# category -> counter -> instance -> object with .Sample and .RawValue. Nothing here reads counters, processes or
# the clock itself: the fast sampler passes them in (see New-FastTickContext).

# @{ instance = value } for one counter, between the previous read and this one.
function Get-CounterDelta {
    param($Previous, $Current, [string]$Category, [string]$Counter)
    $out = @{}
    if (-not $Previous -or -not $Current -or -not $Current.ContainsKey($Category) -or -not $Previous.ContainsKey($Category)) { return $out }
    $now = $Current[$Category][$Counter]; $old = $Previous[$Category][$Counter]
    if (-not $now -or -not $old) { return $out }
    foreach ($inst in $now.Keys) {
        $o = $old[$inst]
        if ($o) { $out[$inst] = [Diagnostics.CounterSample]::Calculate($o.Sample, $now[$inst].Sample) }
    }
    $out
}

function Get-CounterSum([hashtable]$Values) {
    $t = 0.0
    foreach ($v in $Values.Values) { $t += $v }
    $t
}

function Get-CpuTotal([hashtable]$Values) {
    $cpu = 0
    if ($Values.ContainsKey('_Total')) { $cpu = $Values['_Total'] }
    [math]::Min(100, $cpu)
}

# Like Task Manager: add up every process on each engine, then report the busiest engine.
function Get-GpuUsage {
    param([hashtable]$Utilization, [string]$GpuLuid)
    $engines = @{}
    $byProcess = @{}   # process id -> @{ engine = utilization }
    foreach ($k in $Utilization.Keys) {
        if ($k -match 'pid_(\d+)_luid_(\w+?_\w+?)_phys_(\d+)_eng_(\d+)_engtype_(.*)$') {
            if ($GpuLuid -and $matches[2] -ne $GpuLuid) { continue }   # another GPU
            $key = "$($matches[2])|$($matches[3])|$($matches[4])"
            if (-not $engines.ContainsKey($key)) { $engines[$key] = @{ v = 0.0; t = $matches[5] } }
            $engines[$key].v += $Utilization[$k]
            $procId = [int]$matches[1]
            if (-not $byProcess.ContainsKey($procId)) { $byProcess[$procId] = @{} }
            $byProcess[$procId][$key] += $Utilization[$k]
        }
    }
    $gpu = 0; $engine = ''
    foreach ($e in $engines.Values) { if ($e.v -gt $gpu) { $gpu = $e.v; $engine = $e.t } }
    @{ Gpu = $gpu; Engine = $engine; ByProcess = $byProcess }
}

function Get-GpuMemory {
    param([hashtable]$Values, [string]$GpuLuid)
    $total = 0
    foreach ($k in $Values.Keys) { if (-not $GpuLuid -or $k -like "luid_${GpuLuid}_*") { $total += $Values[$k] } }
    $total
}

# Read/write speed per drive letter (the LogicalDisk counters' "C:", "D:" ... instances).
function Get-DiskIO {
    param([hashtable]$Reads, [hashtable]$Writes)
    $io = @{}
    foreach ($k in $Reads.Keys) {
        if ($k -match '^[A-Za-z]:$') { $io[$k.ToUpper()] = @{ r = [math]::Round($Reads[$k]); w = [math]::Round($Writes[$k]) } }
    }
    $io
}

# Process id -> private working set, from the Process category.
function Get-PrivateMemory($Current) {
    $out = @{}
    if ($Current -and $Current.ContainsKey('Process')) {
        $ids = $Current['Process']['ID Process']; $ws = $Current['Process']['Working Set - Private']
        if ($ids -and $ws) { foreach ($k in $ws.Keys) { $i = $ids[$k]; if ($i) { $out[[int]$i.RawValue] = $ws[$k].RawValue } } }
    }
    $out
}

# Per-process rows: CPU and GPU the way Task Manager counts them, memory as a share of RAM.
# Returns @{ Rows; CpuTimes }, CpuTimes being each process's CPU seconds for the next call.
function Get-ServiceRows {
    param(
        [object[]]$Services, [object[]]$Processes, [hashtable]$PrivateMemory, [hashtable]$CpuTimes,
        [hashtable]$GpuByProcess, $Net, [double]$Elapsed, [int]$Cores, [double]$TotalRam
    )
    $nextCpuTimes = @{}
    $rows = @()
    foreach ($svc in $Services) {
        $group = @($Processes | Where-Object { $_.ProcessName -like $svc.match })
        if (-not ($group | Where-Object { $_.ProcessName -eq $svc.main })) {
            $rows += @{ name = $svc.name; icon = $svc.icon; online = $false }
            continue
        }
        $cpuSec = 0.0; $mem = 0; $sent = 0; $recv = 0; $gpuEngines = @{}
        foreach ($p in $group) {
            $mem += if ($PrivateMemory.ContainsKey($p.Id)) { $PrivateMemory[$p.Id] } else { $p.WorkingSet64 }
            try {
                $t = $p.TotalProcessorTime.TotalSeconds
                if ($null -ne $t) {   # $null when the property can't be read
                    if ($CpuTimes.ContainsKey($p.Id)) { $cpuSec += $t - $CpuTimes[$p.Id] }
                    $nextCpuTimes[$p.Id] = $t
                }
            } catch { $null = $_ }   # process exited or is not readable
            if ($GpuByProcess.ContainsKey($p.Id)) {
                foreach ($e in $GpuByProcess[$p.Id].Keys) { $gpuEngines[$e] += $GpuByProcess[$p.Id][$e] }
            }
            $bytes = $null
            if ($Net -and $Net.TryGetValue($p.Id, [ref]$bytes)) { $sent += $bytes[0]; $recv += $bytes[1] }
        }
        $procGpu = 0
        foreach ($v in $gpuEngines.Values) { if ($v -gt $procGpu) { $procGpu = $v } }
        $rows += @{
            name      = $svc.name
            icon      = $svc.icon
            online    = $true
            cpu       = [math]::Round([math]::Min(100, 100 * $cpuSec / ($Elapsed * $Cores)), 1)
            # The same CPU time in whole cores (1.0 = one core flat out); shows when a mostly single-threaded
            # server like Valheim is maxing out its main thread.
            coresUsed = [math]::Round($cpuSec / $Elapsed, 1)
            mem       = [math]::Round(100 * $mem / $TotalRam, 1)
            gpu       = [math]::Round([math]::Min(100, $procGpu), 1)
            tx        = if ($Net) { [math]::Round($sent / $Elapsed) } else { $null }
            rx        = if ($Net) { [math]::Round($recv / $Elapsed) } else { $null }
        }
    }
    @{ Rows = $rows; CpuTimes = $nextCpuTimes }
}

# Everything the fast tick needs that isn't the state itself. CpuTimes is kept here between ticks.
function New-FastTickContext {
    param(
        [scriptblock]$Reader, [scriptblock]$Processes, [scriptblock]$Tracer, [object[]]$Services, [double]$TotalRam,
        [string]$GpuLuid, [int]$Cores, [string[]]$CpuCounter, $TickStopwatch, $IntervalStopwatch
    )
    @{
        Reader = $Reader; Processes = $Processes; Tracer = $Tracer; Services = $Services; TotalRam = $TotalRam
        GpuLuid = $GpuLuid; Cores = $Cores; CpuCounter = $CpuCounter; TickStopwatch = $TickStopwatch
        IntervalStopwatch = $IntervalStopwatch; CpuTimes = @{}
    }
}

# One reading: reads the counters, works out every value, and writes it into the shared state.
# Returns the snapshot to pass as -Previous next time (the old one again if this read failed).
function Invoke-FastTick {
    param([hashtable]$State, [hashtable]$Context, $Previous, [DateTimeOffset]$Now)
    $Context.TickStopwatch.Restart()
    try {
        $cur = & $Context.Reader
        $elapsed = $Context.IntervalStopwatch.Elapsed.TotalSeconds
        $Context.IntervalStopwatch.Restart()
        if ($Previous) {
            $cpu = Get-CpuTotal (Get-CounterDelta $Previous $cur $Context.CpuCounter[0] $Context.CpuCounter[1])
            $gpu = Get-GpuUsage -Utilization (Get-CounterDelta $Previous $cur 'GPU Engine' 'Utilization Percentage') -GpuLuid $Context.GpuLuid
            $rows = Get-ServiceRows -Services $Context.Services -Processes @(& $Context.Processes) `
                -PrivateMemory (Get-PrivateMemory $cur) -CpuTimes $Context.CpuTimes -GpuByProcess $gpu.ByProcess `
                -Net (& $Context.Tracer) -Elapsed $elapsed -Cores $Context.Cores -TotalRam $Context.TotalRam
            $Context.CpuTimes = $rows.CpuTimes
            $State.services = $rows.Rows
            $State.cpu = [math]::Round($cpu, 1)
            $State.memUsed = $Context.TotalRam - (Get-CounterSum (Get-CounterDelta $Previous $cur 'Memory' 'Available Bytes'))
            $State.rx = [math]::Round((Get-CounterSum (Get-CounterDelta $Previous $cur 'Network Interface' 'Bytes Received/sec')))
            $State.tx = [math]::Round((Get-CounterSum (Get-CounterDelta $Previous $cur 'Network Interface' 'Bytes Sent/sec')))
            $State.gpu = [math]::Round([math]::Min(100, $gpu.Gpu), 1)
            $State.gpuEngine = $gpu.Engine
            $State.gpuMem = Get-GpuMemory -Values (Get-CounterDelta $Previous $cur 'GPU Adapter Memory' 'Dedicated Usage') -GpuLuid $Context.GpuLuid
            $State.diskIO = Get-DiskIO -Reads (Get-CounterDelta $Previous $cur 'LogicalDisk' 'Disk Read Bytes/sec') `
                -Writes (Get-CounterDelta $Previous $cur 'LogicalDisk' 'Disk Write Bytes/sec')
            $State.ts = $Now.ToUnixTimeMilliseconds()
            $State.tickMs = [int][math]::Round($Context.TickStopwatch.Elapsed.TotalMilliseconds)
            $State.error = $null
            $State.ready = $true
        }
        return $cur
    } catch {
        $State.error = $_.Exception.Message
        return $Previous
    }
}

Export-ModuleMember -Function Get-CounterDelta, Get-CounterSum, Get-CpuTotal, Get-GpuUsage, Get-GpuMemory, Get-DiskIO,
    Get-PrivateMemory, Get-ServiceRows, New-FastTickContext, Invoke-FastTick
