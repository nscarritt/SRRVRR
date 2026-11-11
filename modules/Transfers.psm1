# The Transfers card (docs/specs/2026-11-07-srrvrr-v0.9.0-design.md): the bottleneck, the shares, PCs and folders,
# write bursts. Pure functions: no clock, counter, CIM or file calls; callers pass readings and times in. One region
# per story (docs/plans/2026-11-10-srrvrr-v0.9.0-implementation-plan.md, Shared interfaces): change only your own.
# Every function is exported (no Export-ModuleMember), so the regions never share a line.
Set-StrictMode -Version 2

#region Shared (byte-identical in every branch; only the lead changes it)
# What the samplers and the web server share: one synchronized table, given to both runspaces.
function New-TransferMonitor {
    param([hashtable]$Settings = @{}, [bool]$Elevated, [string[]]$ServerAddresses = @())
    $get = { param($k, $d) if ($Settings.ContainsKey($k) -and $null -ne $Settings[$k]) { $Settings[$k] } else { $d } }
    [hashtable]::Synchronized(@{
        Elevated = $Elevated; ServerAddresses = @($ServerAddresses); BottleneckPercent = [int](& $get 'BottleneckPercent' 80)
        BurstFiles = [int](& $get 'BurstFiles' 500); BurstWindowSeconds = [int](& $get 'BurstWindowSeconds' 60)
        BurstQuietMinutes = [int](& $get 'BurstQuietMinutes' 5); TransferFolders = [bool](& $get 'TransferFolders' $true)
        NamedIndex = (New-NamedPcIndex -NamedPCs @(& $get 'NamedPCs' @()))
        Shares = @(); SessionPcs = @{}; PcFolders = @{}; OpenFilesCapped = $false; UpdatedMs = $null; Busy = $false; LastTickMs = $null
        Hold = @{ Shown = 'idle'; Candidate = 'idle'; SinceMs = 0L }; Bursts = @{}; BurstList = @(); UnknownSeen = @{}
    })
}
# An address as SRRVRR compares it: IPv4-mapped IPv6 back to IPv4, brackets and the zone id dropped, IPv6 in lower
# case. $null for anything that isn't an address.
function ConvertTo-PcAddress {
    param([string]$Address)
    if (-not $Address) { return $null }
    $text = ($Address.Trim() -replace '^\[|\]$', '') -replace '%.*$', ''
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($text, [ref]$ip)) { return $null }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $ip.ToString().ToLowerInvariant()
}
# Address (as ConvertTo-PcAddress gives it) -> the named PC's Name, from the NamedPCs setting.
function New-NamedPcIndex {
    param([object[]]$NamedPCs = @())
    $index = @{}
    foreach ($pc in $NamedPCs) {
        if ($pc -isnot [Collections.IDictionary]) { continue }
        foreach ($a in @($pc['Addresses'])) { $k = ConvertTo-PcAddress ([string]$a); if ($k) { $index[$k] = [string]$pc['Name'] } }
    }
    $index
}
# Who an address is: @{ Address; Name; Known; Self }. Self: loopback or one of ServerAddresses (the server itself is
# always trusted). Known: Self, or in the index. Name: the named PC's Name, else $null.
function Find-NamedPC {
    param([string]$Address, [hashtable]$Index = @{}, [string[]]$ServerAddresses = @())
    $a = ConvertTo-PcAddress $Address
    $out = @{ Address = $a; Name = $null; Known = $false; Self = $false }
    if (-not $a) { return $out }
    $self = [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($a))
    foreach ($s in $ServerAddresses) { if (-not $self -and (ConvertTo-PcAddress $s) -eq $a) { $self = $true } }
    if ($self) { $out.Known = $true; $out.Self = $true; return $out }
    if ($Index -and $Index.ContainsKey($a)) { $out.Name = $Index[$a]; $out.Known = $true }
    $out
}
#endregion Shared

#region 76 The bottleneck and the shares (#76)
# SMB file-server traffic, the links and the drives since the previous reading (shapes: the v0.9.0 plan, "Data shapes"):
# @{ available; readBps; writeBps; shares; sessions; links; drives }. Not available (and everything empty) on a
# first reading, or when either SMB category is missing. The counters need no administrator. Counter names are
# lower case, as the category lists them. Share instances are '\\*\name' and session instances numeric ids.
function Get-SmbCounterReading {
    param($Previous, $Current)
    $out = @{ available = $false; readBps = 0; writeBps = 0; shares = @(); sessions = @(); links = @(); drives = @{} }
    foreach ($c in 'SMB Server Shares', 'SMB Server Sessions') {
        if (-not $Previous -or -not $Current -or -not $Previous.ContainsKey($c) -or -not $Current.ContainsKey($c)) { return $out }
    }
    # Plain loops over the counters' own tables, with no helper call per value (it was written for the fast tick).
    $calc = [Diagnostics.CounterSample]
    $pS = $Previous['SMB Server Shares']; $cS = $Current['SMB Server Shares']
    $shares = New-Object System.Collections.Generic.List[object]; $readTotal = 0.0; $writeTotal = 0.0
    $nowRead = $cS['read bytes/sec']; $oldRead = $pS['read bytes/sec']
    if ($nowRead -and $oldRead) {
        $nowWrite = $cS['write bytes/sec']; $oldWrite = $pS['write bytes/sec']
        $nowOpen = $cS['current open file count']; $nowSecs = $cS['avg. sec/request']; $oldSecs = $pS['avg. sec/request']; $nowQueue = $cS['current data queue length']
        foreach ($inst in $nowRead.Keys) {
            $name = $inst -replace '^.*\\', ''
            if ($name -eq '_total' -or $name -eq 'ipc$') { continue }
            $o = $oldRead[$inst]; if (-not $o) { continue }
            $r = [math]::Round([double]$calc::Calculate($o.Sample, $nowRead[$inst].Sample)); $w = 0
            if ($nowWrite -and $oldWrite -and $oldWrite[$inst]) { $w = [math]::Round([double]$calc::Calculate($oldWrite[$inst].Sample, $nowWrite[$inst].Sample)) }
            $readTotal += $r; $writeTotal += $w
            $secs = 0
            if ($nowSecs -and $oldSecs -and $oldSecs[$inst]) { $secs = [math]::Round([double]$calc::Calculate($oldSecs[$inst].Sample, $nowSecs[$inst].Sample), 4) }
            $shares.Add(@{
                name = $name; readBps = $r; writeBps = $w
                openFiles = $(if ($nowOpen -and $nowOpen[$inst]) { [int]$nowOpen[$inst].RawValue } else { 0 })
                secPerRequest = $secs
                queue = $(if ($nowQueue -and $nowQueue[$inst]) { [int]$nowQueue[$inst].RawValue } else { 0 })   # a count at this moment: no delta
            })
        }
    }
    $pE = $Previous['SMB Server Sessions']; $cE = $Current['SMB Server Sessions']
    $sessions = New-Object System.Collections.Generic.List[object]
    $nowRead = $cE['read bytes/sec']; $oldRead = $pE['read bytes/sec']
    if ($nowRead -and $oldRead) {
        $nowWrite = $cE['write bytes/sec']; $oldWrite = $pE['write bytes/sec']; $nowOpen = $cE['current open file count']
        $nowOpened = $cE['files opened/sec']; $oldOpened = $pE['files opened/sec']
        foreach ($id in $nowRead.Keys) {
            if ($id -eq '_total') { continue }
            $o = $oldRead[$id]; if (-not $o) { continue }
            $w = 0; $opened = 0
            if ($nowWrite -and $oldWrite -and $oldWrite[$id]) { $w = [math]::Round([double]$calc::Calculate($oldWrite[$id].Sample, $nowWrite[$id].Sample)) }
            if ($nowOpened -and $oldOpened -and $oldOpened[$id]) { $opened = [int][math]::Round([double]$calc::Calculate($oldOpened[$id].Sample, $nowOpened[$id].Sample)) }
            $sessions.Add(@{
                id = [string]$id; readBps = [math]::Round([double]$calc::Calculate($o.Sample, $nowRead[$id].Sample)); writeBps = $w
                openFiles = $(if ($nowOpen -and $nowOpen[$id]) { [int]$nowOpen[$id].RawValue } else { 0 }); filesOpened = $opened
            })
        }
    }
    # Adapters that report a Current Bandwidth (bits per second); the others (loopback, tunnels) have no limit to hit.
    $links = New-Object System.Collections.Generic.List[object]
    if ($Current.ContainsKey('Network Interface') -and $Previous.ContainsKey('Network Interface')) {
        $cN = $Current['Network Interface']; $pN = $Previous['Network Interface']
        $speed = $cN['current bandwidth']; $nowRecv = $cN['bytes received/sec']; $oldRecv = $pN['bytes received/sec']; $nowSent = $cN['bytes sent/sec']; $oldSent = $pN['bytes sent/sec']
        if ($speed) {
            foreach ($nic in $speed.Keys) {
                $bw = [double]$speed[$nic].RawValue
                if ($bw -le 0) { continue }
                $in = 0; $outB = 0
                if ($nowRecv -and $oldRecv -and $oldRecv[$nic]) { $in = [math]::Round([double]$calc::Calculate($oldRecv[$nic].Sample, $nowRecv[$nic].Sample)) }
                if ($nowSent -and $oldSent -and $oldSent[$nic]) { $outB = [math]::Round([double]$calc::Calculate($oldSent[$nic].Sample, $nowSent[$nic].Sample)) }
                $links.Add(@{ inBps = $in; outBps = $outB; speedBits = $bw })
            }
        }
    }
    # Drive letters only; busy is 100 minus the idle time (which can read a little over 100).
    $drives = @{}
    if ($Current.ContainsKey('LogicalDisk') -and $Previous.ContainsKey('LogicalDisk')) {
        $nowIdle = $Current['LogicalDisk']['% idle time']; $oldIdle = $Previous['LogicalDisk']['% idle time']; $dq = $Current['LogicalDisk']['current disk queue length']
        if ($nowIdle -and $oldIdle) {
            foreach ($k in $nowIdle.Keys) {
                if ($k -notmatch '^[A-Za-z]:$' -or -not $oldIdle[$k]) { continue }
                $idle = [double]$calc::Calculate($oldIdle[$k].Sample, $nowIdle[$k].Sample)
                $drives[$k.ToUpper()] = @{
                    busy = [math]::Round([math]::Max(0.0, [math]::Min(100.0, 100 - $idle)), 1)
                    queue = $(if ($dq -and $dq[$k]) { [int]$dq[$k].RawValue } else { 0 })
                }
            }
        }
    }
    @{ available = $true; readBps = $readTotal; writeBps = $writeTotal; shares = $shares.ToArray(); sessions = $sessions.ToArray(); links = $links.ToArray(); drives = $drives }
}

# Win32_Share-shaped list (Name, Path, Type) -> the share list: @{ name; path; drive } with the drive letter
# ('D:') the share's path starts with, else $null (IPC$, a path with no letter such as a mount folder).
function Get-ShareDriveMap {
    param([object[]]$Shares = @())
    foreach ($s in $Shares) {
        if ($null -eq $s) { continue }
        $path = [string]$s.Path
        $drive = if ($path -match '^([A-Za-z]):') { $matches[1].ToUpperInvariant() + ':' } else { $null }
        @{ name = [string]$s.Name; path = $path; drive = $drive }
    }
}

# Share name -> its entry in the share list (names compared without regard to case: the counters list them in lower
# case, Win32_Share as they were made).
function ConvertTo-ShareIndex {
    param([object[]]$Shares = @())
    $index = @{}
    foreach ($s in $Shares) { if ($s -and $s['name']) { $index[[string]$s['name']] = $s } }
    $index
}

# The bottleneck (design section 2). Reading is the SMB reading (Counters.psm1), Shares the share list, Cpu the CPU
# percent, Percent the BottleneckPercent setting. Hold (@{ Shown; Candidate; SinceMs }) is updated in place: a new
# name is shown only once it has been the raw result for HoldMs; the percents change every second regardless.
function Get-Bottleneck {
    param(
        [hashtable]$Reading, [object[]]$Shares = @(), [double]$Cpu, [int]$Percent = 80, [hashtable]$Hold, [long]$NowMs,
        [double]$FloorBps = 1MB, [int]$HoldMs = 2000
    )
    # The link: the busiest adapter's larger direction, as a percent of its Current Bandwidth (bits per second).
    $link = $null
    foreach ($l in @($Reading.links)) {
        $bytes = [math]::Max([double]$l.inBps, [double]$l.outBps)
        $pct = [math]::Round([math]::Min(100.0, 100 * 8 * $bytes / [double]$l.speedBits), 1)
        if ($null -eq $link -or $pct -gt $link.percent) { $link = @{ percent = $pct; bytesPerSec = $bytes; speedBits = [double]$l.speedBits } }
    }
    # The drive: the busiest one behind a share with traffic this second (admin shares count too).
    $index = ConvertTo-ShareIndex $Shares
    $drive = $null
    foreach ($s in @($Reading.shares)) {
        if ($s.readBps + $s.writeBps -le 0) { continue }
        $entry = $index[[string]$s.name]
        if (-not $entry -or -not $entry.drive) { continue }
        $d = $Reading.drives[$entry.drive]
        if (-not $d) { continue }
        if ($null -eq $drive -or $d.busy -gt $drive.percent) { $drive = @{ letter = [string]$entry.drive; percent = [double]$d.busy; queue = [int]$d.queue } }
    }
    $cpuRow = @{ percent = [double]$Cpu }
    # The raw result: idle below the floor, else the highest percent (ties: link, drive, CPU) if it reaches Percent.
    $traffic = [double]$Reading.readBps + [double]$Reading.writeBps
    $best = 'cpu'; $high = $cpuRow.percent
    if ($drive -and $drive.percent -ge $high) { $best = 'drive'; $high = $drive.percent }
    if ($link -and $link.percent -ge $high) { $best = 'link'; $high = $link.percent }
    $high = [math]::Round($high, 1)
    $raw = if ($traffic -lt $FloorBps) { 'idle' } elseif ($high -ge $Percent) { $best } else { 'none' }
    if ($raw -eq $Hold.Shown) { $Hold.Candidate = $raw; $Hold.SinceMs = $NowMs }
    elseif ($raw -ne $Hold.Candidate) { $Hold.Candidate = $raw; $Hold.SinceMs = $NowMs }
    elseif ($NowMs - $Hold.SinceMs -ge $HoldMs) { $Hold.Shown = $raw }
    $name = $Hold.Shown
    $shown = switch ($name) {
        'link' { if ($link) { $link.percent } else { $null } }
        'drive' { if ($drive) { $drive.percent } else { $null } }
        'cpu' { [math]::Round($cpuRow.percent, 1) }
        'none' { $high }
        default { $null }
    }
    @{ name = $name; percent = $shown; link = $link; drive = $drive; cpu = $cpuRow }
}

# One second of sessions -> one row per PC (the address; or 'session:<id>' when a session has no PC, as when the
# session list is unavailable). SessionPcs is Monitor.SessionPcs (session id -> Session PC). A PC is writing when
# its write speed is above zero or one of its open files is open for writing.
function Group-SessionsByPc {
    param([object[]]$Sessions = @(), [hashtable]$SessionPcs = @{})
    $rows = [ordered]@{}
    foreach ($s in $Sessions) {
        $id = [string]$s.id
        $pc = if ($SessionPcs -and $SessionPcs.ContainsKey($id)) { $SessionPcs[$id] } else { $null }
        $address = if ($pc -and $pc['address']) { [string]$pc['address'] } else { $null }
        $key = if ($address) { $address } else { "session:$id" }
        if (-not $rows.Contains($key)) {
            $rows[$key] = @{ key = $key; address = $address; sessions = @(); readBps = 0; writeBps = 0; openFiles = 0; filesOpened = 0; writing = $false }
        }
        $r = $rows[$key]
        $r.sessions += $id
        $r.readBps += $s.readBps; $r.writeBps += $s.writeBps; $r.openFiles += $s.openFiles; $r.filesOpened += $s.filesOpened
        if ($s.writeBps -gt 0 -or ($pc -and $pc['writingFiles'])) { $r.writing = $true }
    }
    foreach ($k in $rows.Keys) { $rows[$k] }
}

# What the slow sampler (every 5 s) reads for the transfer monitor. Readers: @{ Shares; Sessions; OpenFiles }
# scriptblocks. The share list at tick 0 and every 12th (60 s); administrator only: the session and open-file lists
# every tick while the shares are busy, else every 6th (30 s), turned into PCs and folders by Get-SessionPcs. A
# reader's error goes to the caller, and the monitor keeps what it had.
function Invoke-TransferSample {
    param([hashtable]$Monitor, [int]$Tick, [long]$NowMs, [hashtable]$Readers)
    if ($Tick % 12 -eq 0) { $Monitor.Shares = @(Get-ShareDriveMap -Shares @(& $Readers.Shares | ForEach-Object { $_ })) }   # a reader may hand its list back wrapped, as Get-ShareList does
    if ($Monitor.Elevated -and ($Monitor.Busy -or $Tick % 6 -eq 0)) {
        $sessions = @(& $Readers.Sessions | ForEach-Object { $_ })
        $files = @(& $Readers.OpenFiles | ForEach-Object { $_ })
        $r = Get-SessionPcs -Sessions $sessions -OpenFiles $files -Shares @($Monitor.Shares) -Index $Monitor.NamedIndex `
            -ServerAddresses @($Monitor.ServerAddresses) -Folders ([bool]$Monitor.TransferFolders)
        $Monitor.SessionPcs = $r.SessionPcs; $Monitor.PcFolders = $r.PcFolders; $Monitor.OpenFilesCapped = [bool]$r.Capped
        $Monitor.UpdatedMs = $NowMs
    }
}

# The /stats `transfers` value. Shares: only those with traffic or open files, busiest first, up to MaxShares, each
# with its drive (and the name as the share list spells it).
function New-TransfersSnapshot {
    param(
        [hashtable]$Reading, [hashtable]$Bottleneck, [object[]]$ShareList = @(), [object[]]$PcRows = @(),
        [bool]$Elevated, [bool]$Capped, $UpdatedMs, [int]$MaxShares = 32
    )
    $index = ConvertTo-ShareIndex $ShareList
    # The rows with traffic or open files, busiest first (a plain insertion sort: this runs every second, and the
    # pipeline cmdlets cost more than the whole rest of the tick).
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($x in @($Reading.shares)) {
        if ($x.readBps + $x.writeBps -le 0 -and $x.openFiles -le 0) { continue }
        $at = $rows.Count
        while ($at -gt 0 -and ($rows[$at - 1].readBps + $rows[$at - 1].writeBps) -lt ($x.readBps + $x.writeBps)) { $at-- }
        $rows.Insert($at, $x)
    }
    if ($rows.Count -gt $MaxShares) { $rows.RemoveRange($MaxShares, $rows.Count - $MaxShares) }
    $shares = @()
    foreach ($s in $rows) {
        $entry = $index[[string]$s.name]
        $row = @{}
        foreach ($k in $s.Keys) { $row[$k] = $s[$k] }
        if ($entry) { $row.name = $entry.name }
        $row.drive = if ($entry) { $entry.drive } else { $null }
        $shares += $row
    }    $reason = if (-not $Reading.available) { 'SMB counters are not available' }
              elseif (-not $Elevated) { 'PCs and folders need administrator' }
              elseif ($Capped) { 'more than 5,000 open files' }
              else { $null }
    @{ available = [bool]$Reading.available; reason = $reason; bottleneck = $Bottleneck; shares = $shares; pcs = @($PcRows); updatedMs = $UpdatedMs }
}

# One second of the transfer monitor, called by the fast sampler with the SMB reading: PC rows, the bottleneck, the
# bursts, the `transfers` value in the state, and the two history lines. The slow sampler calls it every 5 seconds
# (design Q1): the reading's speeds are averages over the time since the last call, so the burst detector is told how
# many seconds that was (1 to 60), and each of those seconds gets the average in the history lines.
function Invoke-TransferTick {
    param([hashtable]$State, [hashtable]$Monitor, [hashtable]$Reading, [long]$NowMs, $History)
    $seconds = 1.0
    if ($null -ne $Monitor.LastTickMs) { $seconds = [math]::Max(1.0, [math]::Min(60.0, ($NowMs - [long]$Monitor.LastTickMs) / 1000.0)) }
    $Monitor.LastTickMs = $NowMs
    $pcs = @(Group-SessionsByPc -Sessions @($Reading.sessions) -SessionPcs $Monitor.SessionPcs)
    # The fast loop sets cpu; the slow sampler's first pass can come before its first tick (and StrictMode throws on
    # a missing key).
    $cpu = if ($State.ContainsKey('cpu')) { [double]$State['cpu'] } else { 0.0 }
    $bottleneck = Get-Bottleneck -Reading $Reading -Shares @($Monitor.Shares) -Cpu $cpu `
        -Percent $Monitor.BottleneckPercent -Hold $Monitor.Hold -NowMs $NowMs
    $Monitor.BurstList = @(Update-WriteBursts -State $Monitor.Bursts -Pcs $pcs -Shares @($Reading.shares) -NowMs $NowMs `
        -Files $Monitor.BurstFiles -WindowSeconds $Monitor.BurstWindowSeconds -QuietMs ([long]$Monitor.BurstQuietMinutes * 60000) -Seconds $seconds)
    $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs $Monitor.SessionPcs -PcFolders $Monitor.PcFolders -Bursts $Monitor.BurstList)
    $busy = $Reading.readBps + $Reading.writeBps -gt 0
    foreach ($x in @($Reading.shares)) { if ($x.openFiles -gt 0) { $busy = $true } }
    $Monitor.Busy = $busy
    $State.transfers = New-TransfersSnapshot -Reading $Reading -Bottleneck $bottleneck -ShareList @($Monitor.Shares) -PcRows $rows `
        -Elevated ([bool]$Monitor.Elevated) -Capped ([bool]$Monitor.OpenFilesCapped) -UpdatedMs $Monitor.UpdatedMs
    if ($History) {
        $read = if ($Reading.available) { $Reading.readBps } else { $null }
        $write = if ($Reading.available) { $Reading.writeBps } else { $null }
        for ($t = $NowMs - ([long][math]::Round($seconds) - 1) * 1000; $t -le $NowMs; $t += 1000) {
            $History.Append('smbRead', $read, $t)
            $History.Append('smbWrite', $write, $t)
        }
    }
}
#endregion 76

#region 77 Write bursts (#77). Stubs until #77 lands: no bursts, no events.
function Update-WriteBursts { param([hashtable]$State, [object[]]$Pcs, [object[]]$Shares, [long]$NowMs, [int]$Files, [int]$WindowSeconds, [long]$QuietMs, [double]$Seconds = 1) }
function Get-BurstEvents { param([object[]]$Old, [object[]]$New, [object[]]$PcRows, [hashtable]$PcFolders, [bool]$IncludeFolders, [long]$StopMs) }
#endregion 77

#region 78 PCs and folders (#78). Stubs until #78 lands: no PCs, no events.
function Get-SessionPcs { param([object[]]$Sessions, [object[]]$OpenFiles, [object[]]$Shares, [hashtable]$Index, [string[]]$ServerAddresses, [bool]$Folders, [int]$MaxOpenFiles = 5000) @{ SessionPcs = @{}; PcFolders = @{}; Capped = $false } }
function Get-TransferPcRows { param([object[]]$Pcs, [hashtable]$SessionPcs, [hashtable]$PcFolders, [object[]]$Bursts, [int]$MaxPcs = 64) }
function Get-UnknownPcEvents { param([hashtable]$Seen, [object[]]$PcRows, [bool]$Elevated) }
#endregion 78

#region 79 (none: #79's code is in Maintenance.psm1, Web.psm1 and web\app.js)
#endregion 79
