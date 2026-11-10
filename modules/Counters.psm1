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

# One second of SMB file-server traffic, the links and the drives (shapes: the v0.9.0 plan, "Data shapes"):
# @{ available; readBps; writeBps; shares; sessions; links; drives }. Not available (and everything empty) on a
# first reading, or when either SMB category is missing. The counters need no administrator. Counter names are
# lower case, as the category lists them. Share instances are '\\*\name' and session instances numeric ids.
function Get-SmbCounterReading {
    param($Previous, $Current)
    $out = @{ available = $false; readBps = 0; writeBps = 0; shares = @(); sessions = @(); links = @(); drives = @{} }
    foreach ($c in 'SMB Server Shares', 'SMB Server Sessions') {
        if (-not $Previous -or -not $Current -or -not $Previous.ContainsKey($c) -or -not $Current.ContainsKey($c)) { return $out }
    }
    $sh = 'SMB Server Shares'; $se = 'SMB Server Sessions'
    $read = Get-CounterDelta $Previous $Current $sh 'read bytes/sec'
    $write = Get-CounterDelta $Previous $Current $sh 'write bytes/sec'
    $open = Get-CounterDelta $Previous $Current $sh 'current open file count'
    $secs = Get-CounterDelta $Previous $Current $sh 'avg. sec/request'
    $queue = Get-CounterDelta $Previous $Current $sh 'current data queue length'
    $shares = @(); $readTotal = 0.0; $writeTotal = 0.0
    foreach ($inst in $read.Keys) {
        $name = $inst -replace '^.*\\', ''
        if ($name -eq '_total' -or $name -eq 'ipc$') { continue }
        $r = [math]::Round([double]$read[$inst]); $w = if ($write.ContainsKey($inst)) { [math]::Round([double]$write[$inst]) } else { 0 }
        $readTotal += $r; $writeTotal += $w
        $shares += @{
            name = $name; readBps = $r; writeBps = $w
            openFiles = if ($open.ContainsKey($inst)) { [int]$open[$inst] } else { 0 }
            secPerRequest = if ($secs.ContainsKey($inst)) { [math]::Round([double]$secs[$inst], 4) } else { 0 }
            queue = if ($queue.ContainsKey($inst)) { [int]$queue[$inst] } else { 0 }
        }
    }
    $sRead = Get-CounterDelta $Previous $Current $se 'read bytes/sec'
    $sWrite = Get-CounterDelta $Previous $Current $se 'write bytes/sec'
    $sOpen = Get-CounterDelta $Previous $Current $se 'current open file count'
    $sOpened = Get-CounterDelta $Previous $Current $se 'files opened/sec'
    $sessions = @()
    foreach ($id in $sRead.Keys) {
        if ($id -eq '_total') { continue }
        $sessions += @{
            id = [string]$id; readBps = [math]::Round([double]$sRead[$id])
            writeBps = if ($sWrite.ContainsKey($id)) { [math]::Round([double]$sWrite[$id]) } else { 0 }
            openFiles = if ($sOpen.ContainsKey($id)) { [int]$sOpen[$id] } else { 0 }
            filesOpened = if ($sOpened.ContainsKey($id)) { [int][math]::Round([double]$sOpened[$id]) } else { 0 }
        }
    }
    # Adapters that report a Current Bandwidth (bits per second); the others (loopback, tunnels) have no limit to hit.
    $speed = Get-CounterDelta $Previous $Current 'Network Interface' 'Current Bandwidth'
    $recv = Get-CounterDelta $Previous $Current 'Network Interface' 'Bytes Received/sec'
    $sent = Get-CounterDelta $Previous $Current 'Network Interface' 'Bytes Sent/sec'
    $links = @()
    foreach ($nic in $speed.Keys) {
        if ($speed[$nic] -le 0) { continue }
        $links += @{
            inBps = if ($recv.ContainsKey($nic)) { [math]::Round([double]$recv[$nic]) } else { 0 }
            outBps = if ($sent.ContainsKey($nic)) { [math]::Round([double]$sent[$nic]) } else { 0 }
            speedBits = [double]$speed[$nic]
        }
    }
    # Drive letters only; busy is 100 minus the idle time (which can read a little over 100).
    $idle = Get-CounterDelta $Previous $Current 'LogicalDisk' '% Idle Time'
    $dq = Get-CounterDelta $Previous $Current 'LogicalDisk' 'Current Disk Queue Length'
    $drives = @{}
    foreach ($k in $idle.Keys) {
        if ($k -notmatch '^[A-Za-z]:$') { continue }
        $drives[$k.ToUpper()] = @{
            busy = [math]::Round([math]::Max(0, [math]::Min(100, 100 - [double]$idle[$k])), 1)
            queue = if ($dq.ContainsKey($k)) { [int][math]::Round([double]$dq[$k]) } else { 0 }
        }
    }
    @{ available = $true; readBps = $readTotal; writeBps = $writeTotal; shares = $shares; sessions = $sessions; links = $links; drives = $drives }
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

# What to log about the network tracer, given its status now and when it was last logged (each a hashtable of
# ErrorText, ErrorType, ErrorCount, Alive): $null, or @{ Level; Message } when the error count rose or the
# tracer's thread stopped.
function Get-TracerLogEntry {
    param([hashtable]$Current, [hashtable]$LastLogged)
    if ($LastLogged.Alive -and -not $Current.Alive) { return @{ Level = 'ERROR'; Message = "network tracer thread stopped$(if ($Current.ErrorText) { " (last error: $($Current.ErrorType): $($Current.ErrorText))" })" } }
    if ($Current.ErrorCount -gt $LastLogged.ErrorCount) {
        $new = $Current.ErrorCount - $LastLogged.ErrorCount   # errors since the last line, this one included
        return @{ Level = 'ERROR'; Message = "network tracer: $($Current.ErrorType): $($Current.ErrorText)$(if ($new -gt 1) { " ($new more since the last line)" })" }
    }
    $null
}

# Everything the fast tick needs that isn't the state itself. CpuTimes is kept here between ticks.
function New-FastTickContext {
    param(
        [scriptblock]$Reader, [scriptblock]$Processes, [scriptblock]$Tracer, [object[]]$Services, [double]$TotalRam,
        [string]$GpuLuid, [int]$Cores, [string[]]$CpuCounter, $TickStopwatch, $IntervalStopwatch, $History, [scriptblock]$Transfers
    )
    @{
        Reader = $Reader; Processes = $Processes; Tracer = $Tracer; Services = $Services; TotalRam = $TotalRam
        GpuLuid = $GpuLuid; Cores = $Cores; CpuCounter = $CpuCounter; TickStopwatch = $TickStopwatch
        IntervalStopwatch = $IntervalStopwatch; CpuTimes = @{}; History = $History; Transfers = $Transfers
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
            # The transfer monitor (modules\Transfers.psm1) takes the SMB reading; its failure never stops the tick.
            if ($Context.Transfers) {
                try { & $Context.Transfers (Get-SmbCounterReading -Previous $Previous -Current $cur) $Now }
                catch { $State.transfersError = "transfer tick: $($_.Exception.Message)" }
            }
            $State.ts = $Now.ToUnixTimeMilliseconds()
            $State.tickMs = [int][math]::Round($Context.TickStopwatch.Elapsed.TotalMilliseconds)
            $State.error = $null
            $State.ready = $true
            # The graph history (modules\History.psm1): memory as a percent of the total, like the page draws it.
            if ($Context.History) {
                $ms = $Now.ToUnixTimeMilliseconds(); $h = $Context.History
                $h.Append('cpu', $State.cpu, $ms); $h.Append('gpu', $State.gpu, $ms)
                $h.Append('mem', $(if ($Context.TotalRam) { [math]::Round(100 * $State.memUsed / $Context.TotalRam, 1) }), $ms)
                $h.Append('rx', $State.rx, $ms); $h.Append('tx', $State.tx, $ms)
            }
        }
        return $cur
    } catch {
        $State.error = $_.Exception.Message
        return $Previous
    }
}

# How long the fast sampler sleeps: until 20 ms past the next whole second, so each tick lands in its own second
# (a plain 1000 ms sleep drifts and skips a second every minute or two, which shows as a gap in the graphs).
function Get-TickWait([DateTime]$Now) {
    $wait = 1020 - $Now.Millisecond
    if ($wait -gt 1000) { $wait -= 1000 }
    $wait
}

Export-ModuleMember -Function Get-TickWait, Get-CounterDelta, Get-CounterSum, Get-CpuTotal, Get-GpuUsage, Get-GpuMemory, Get-DiskIO,
    Get-PrivateMemory, Get-SmbCounterReading, Get-ServiceRows, Get-TracerLogEntry, New-FastTickContext, Invoke-FastTick
