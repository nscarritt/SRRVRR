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

#region 77 Write bursts (#77)
$script:BurstEndedKeepMs = 120000L   # an ended burst stays in the list this long, for the watcher to see it end
$script:BurstMaxPcs = 64             # PCs tracked at once
$script:BurstMaxEnded = 128          # ended bursts kept, at most
$script:BurstMaxShares = 32
$script:BurstMaxFolders = 5          # folders in one burst event

# One field of a hashtable or an object, or $null.
function Get-BurstValue([object]$Item, [string]$Name) {
    if ($null -eq $Item) { return $null }
    if ($Item -is [Collections.IDictionary]) { if ($Item.Contains($Name)) { return $Item[$Name] } else { return $null } }
    $p = $Item.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Moves a PC's ring up to the second Sec: the slots for the seconds in between (and the one for Sec) are emptied,
# so a second with no reading counts as quiet. The sums are kept as running totals, so a tick costs a few operations.
function Step-BurstRing([hashtable]$Tracker, [long]$Sec) {
    $w = $Tracker.Slots.Length
    if ($null -eq $Tracker.LastSec) { $Tracker.LastSec = $Sec; return }
    $gap = $Sec - $Tracker.LastSec
    if ($gap -eq 0) { return }
    if ($gap -lt 0 -or $gap -ge $w) {
        [Array]::Clear($Tracker.Slots, 0, $w); [Array]::Clear($Tracker.Bytes, 0, $w)
        $Tracker.Sum = 0L; $Tracker.BytesSum = 0L
    } else {
        for ($i = 1; $i -le $gap; $i++) {
            $ix = [int](($Tracker.LastSec + $i) % $w)
            $Tracker.Sum -= $Tracker.Slots[$ix]; $Tracker.BytesSum -= $Tracker.Bytes[$ix]
            $Tracker.Slots[$ix] = 0L; $Tracker.Bytes[$ix] = 0L
        }
    }
    $Tracker.LastSec = $Sec
}

# A set of share names as a sorted array.
function Get-SortedBurstShares([Collections.Generic.HashSet[string]]$Set) {
    $names = [string[]]::new($Set.Count)
    $Set.CopyTo($names)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    , $names
}

# The write-burst detector, one call per reading (a pure function of the readings: the caller passes the time). Per PC
# key, a ring of WindowSeconds slots holds the files opened in each second in which the PC was writing. A burst starts
# when the ring's sum reaches Files and ends when the sum has stayed below Files for QuietMs, so a rise sooner than
# that is the same burst. A PC missing from a second counts as quiet. State is the monitor (its Bursts table and
# BurstList) or any hashtable that holds the detector's tables between calls. Pcs are PC seconds, Shares the SMB
# reading's share rows. Seconds is how many seconds the reading covers (the slow sampler's 5): its speeds are averages, so the
# second of the call counts Seconds times the files opened per second and the bytes per second. Returns the burst list (shape in the plan): the active bursts, and those that ended within
# 120 s, oldest first; also stored in State.BurstList when State has one.
function Update-WriteBursts {
    param([hashtable]$State, [object[]]$Pcs, [object[]]$Shares, [long]$NowMs, [int]$Files, [int]$WindowSeconds, [long]$QuietMs, [double]$Seconds = 1)
    $store = if ($State.ContainsKey('Bursts') -and $State['Bursts'] -is [hashtable]) { $State['Bursts'] } else { $State }
    if (-not $store.ContainsKey('Pcs')) { $store['Pcs'] = @{}; $store['Ended'] = [Collections.Generic.List[object]]::new() }
    $trackers = $store['Pcs']; $ended = $store['Ended']
    $w = [Math]::Max(1, $WindowSeconds)
    $sec = [long][Math]::Floor($NowMs / 1000.0)
    $ix = [int]($sec % $w)

    # Plain property reads below, not function calls or pipelines: they were written for the fast loop's budget.
    $writingShares = [Collections.Generic.List[string]]::new()
    foreach ($s in $Shares) {
        if ($null -eq $s) { continue }
        $bps = $s.writeBps
        if ($null -ne $bps -and [double]$bps -gt 0) { $writingShares.Add([string]$s.name) }
    }
    $seen = @{}
    foreach ($pc in $Pcs) {
        if ($null -eq $pc) { continue }
        $key = [string]$pc.key
        if ($key) { $seen[$key] = $pc }
    }
    # A tracker is made when a PC first writes (idle PCs cost nothing), and dropped when its ring is empty.
    foreach ($key in $seen.Keys) {
        if ($trackers.ContainsKey($key) -or $trackers.Count -ge $script:BurstMaxPcs) { continue }
        if (-not $seen[$key].writing) { continue }
        $trackers[$key] = @{ Slots = [long[]]::new($w); Bytes = [long[]]::new($w); LastSec = $null; Sum = 0L; BytesSum = 0L
            Burst = $null; BelowSinceMs = $null; Shares = [Collections.Generic.HashSet[string]]::new() }
    }
    foreach ($key in @($trackers.Keys)) {
        $t = $trackers[$key]
        if ($t.Slots.Length -ne $w) {   # the window changed: start the ring again, keep the burst
            $t.Slots = [long[]]::new($w); $t.Bytes = [long[]]::new($w); $t.Sum = 0L; $t.BytesSum = 0L; $t.LastSec = $null
        }
        Step-BurstRing $t $sec
        $pc = if ($seen.ContainsKey($key)) { $seen[$key] } else { $null }
        $writing = $false; $opened = 0L; $bytes = 0L
        if ($pc) {
            $writing = [bool]$pc.writing
            if ($writing) {
                $f = $pc.filesOpened; if ($null -ne $f) { $opened = [long][Math]::Round([double]$f * $Seconds) }
                $b = $pc.writeBps; if ($null -ne $b) { $bytes = [long][Math]::Round([double]$b * $Seconds) }
                $t.Slots[$ix] += $opened; $t.Sum += $opened; $t.Bytes[$ix] += $bytes; $t.BytesSum += $bytes
            }
        }
        $burst = $t.Burst
        if ($burst) {
            if ($pc) {
                $a = $pc.address; if ($a) { $burst.address = [string]$a }
                $ids = $pc.sessions; if ($ids) { $burst.sessions = [string[]]@($ids) }
            }
            if ($writing) {
                $burst.files += $opened; $burst.bytes += $bytes
                foreach ($n in $writingShares) { if ($t.Shares.Count -lt $script:BurstMaxShares) { [void]$t.Shares.Add($n) } }
            }
            if ($t.Sum -ge $Files) { $t.BelowSinceMs = $null }
            else {
                if ($null -eq $t.BelowSinceMs) { $t.BelowSinceMs = $NowMs }
                if (($NowMs - $t.BelowSinceMs) -ge $QuietMs) {
                    $burst.endedMs = $NowMs; $burst.reason = 'quiet'
                    $burst.shares = Get-SortedBurstShares $t.Shares
                    $ended.Add($burst); $t.Burst = $null; $t.BelowSinceMs = $null; $t.Shares.Clear()
                }
            }
        } elseif ($t.Sum -ge $Files) {
            $a = $null; $ids = @()
            if ($pc) { $a = $pc.address; $ids = @($pc.sessions) }
            foreach ($n in $writingShares) { if ($t.Shares.Count -lt $script:BurstMaxShares) { [void]$t.Shares.Add($n) } }
            $t.Burst = @{ key = $key; address = $(if ($a) { [string]$a } else { $null }); sessions = [string[]]@($ids | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                startMs = $NowMs; endedMs = $null; files = [long]$t.Sum; bytes = [long]$t.BytesSum; shares = [string[]]@(); reason = $null }
            $t.BelowSinceMs = $null
        }
        if (-not $t.Burst -and $t.Sum -le 0 -and -not $writing) { $trackers.Remove($key) }
    }
    for ($i = $ended.Count - 1; $i -ge 0; $i--) {
        if (($NowMs - [long]$ended[$i].endedMs) -ge $script:BurstEndedKeepMs) { $ended.RemoveAt($i) }
    }
    if ($ended.Count -gt $script:BurstMaxEnded) { $ended.RemoveRange(0, $ended.Count - $script:BurstMaxEnded) }

    # A fresh copy of each burst, so what the watcher holds never changes under it.
    $list = [Collections.Generic.List[object]]::new()
    foreach ($e in $ended) { $list.Add($e) }
    foreach ($key in $trackers.Keys) {
        $t = $trackers[$key]
        if (-not $t.Burst) { continue }
        $c = $t.Burst.Clone()
        $c.shares = Get-SortedBurstShares $t.Shares
        $list.Add($c)
    }
    $out = $list.ToArray()
    if ($out.Length -gt 1) {   # oldest first
        $starts = [long[]]::new($out.Length)
        for ($i = 0; $i -lt $out.Length; $i++) { $starts[$i] = [long]$out[$i].startMs }
        [Array]::Sort($starts, $out)
    }
    if ($State.ContainsKey('BurstList')) { $State['BurstList'] = $out }
    $out
}

# One event record for a burst: Type, Key and Data as the plan's event table has them. A burst's PC is its address's
# row in PcRows; with no address (unelevated) it is "a PC (needs administrator)" with its session id and nothing else
# about the PC. Folders (share, path, counts; never file names) come from PcFolders, and only with IncludeFolders.
function New-BurstEventRecord {
    param([string]$Type, [object]$Burst, [hashtable]$RowByAddress, [hashtable]$PcFolders, [bool]$IncludeFolders, [long]$EndMs, [string]$Reason)
    $key = [string](Get-BurstValue $Burst 'key'); $address = Get-BurstValue $Burst 'address'
    $startMs = [long](Get-BurstValue $Burst 'startMs')
    $data = @{ shares = @([string[]]@(Get-BurstValue $Burst 'shares')); files = [long](Get-BurstValue $Burst 'files'); bytes = [long](Get-BurstValue $Burst 'bytes'); startMs = $startMs }
    if ($address) {
        $row = $RowByAddress[[string]$address]
        $name = Get-BurstValue $row 'name'
        $data.pc = $(if ($name) { [string]$name } else { 'unknown' })
        $data.address = [string]$address
        $data.account = Get-BurstValue $row 'account'
        $rows = @()
        if ($PcFolders -and $PcFolders.ContainsKey([string]$address)) { $rows = @($PcFolders[[string]$address]) }
        $folderShares = @($rows | ForEach-Object { Get-BurstValue $_ 'share' } | Where-Object { $_ } | Sort-Object -Unique)
        if ($folderShares.Count) { $data.shares = @([string[]]$folderShares) }
        $data.folders = @()
        if ($IncludeFolders) {
            $data.folders = @($rows | Select-Object -First $script:BurstMaxFolders | ForEach-Object {
                @{ share = [string](Get-BurstValue $_ 'share'); path = [string](Get-BurstValue $_ 'path'); files = [long](Get-BurstValue $_ 'files') } })
        }
    } else {
        $data.pc = 'a PC (needs administrator)'
        $data.session = if ($key -like 'session:*') { $key.Substring(8) } else { [string]@(Get-BurstValue $Burst 'sessions')[0] }
    }
    if ($Type -eq 'write-burst-ended') {
        $data.durationSeconds = [int][Math]::Max(0, [Math]::Round(($EndMs - $startMs) / 1000.0))
        $data.reason = $Reason
    }
    @{ Type = $Type; Key = "$Type|$key|$startMs"; Data = $data }
}

# The events between two burst lists (the one the watcher saw last, and the one now): a burst new in New raises
# write-burst, one that gained endedMs raises write-burst-ended. With StopMs above zero (a clean stop), instead an
# ended record with reason "stopped" for every burst still active in New, and nothing else. PcRows (the page's PC rows)
# give the name and account.
function Get-BurstEvents {
    param([object[]]$Old, [object[]]$New, [object[]]$PcRows, [hashtable]$PcFolders, [bool]$IncludeFolders, [long]$StopMs)
    $oldBy = @{}
    foreach ($o in @($Old)) { if ($null -ne $o) { $oldBy["$(Get-BurstValue $o 'key')|$(Get-BurstValue $o 'startMs')"] = $o } }
    $rowBy = @{}
    foreach ($r in @($PcRows)) { $a = Get-BurstValue $r 'address'; if ($a) { $rowBy[[string]$a] = $r } }
    $out = [Collections.Generic.List[object]]::new()
    foreach ($b in @($New)) {
        if ($null -eq $b) { continue }
        $endedMs = Get-BurstValue $b 'endedMs'
        if ($StopMs -gt 0) {
            if ($null -eq $endedMs) { $out.Add((New-BurstEventRecord 'write-burst-ended' $b $rowBy $PcFolders $IncludeFolders $StopMs 'stopped')) }
            continue
        }
        $was = $oldBy["$(Get-BurstValue $b 'key')|$(Get-BurstValue $b 'startMs')"]
        if ($null -eq $was) {
            $out.Add((New-BurstEventRecord 'write-burst' $b $rowBy $PcFolders $IncludeFolders 0 $null))
            if ($null -ne $endedMs) { $out.Add((New-BurstEventRecord 'write-burst-ended' $b $rowBy $PcFolders $IncludeFolders ([long]$endedMs) ([string](Get-BurstValue $b 'reason')))) }
        } elseif ($null -eq (Get-BurstValue $was 'endedMs') -and $null -ne $endedMs) {
            $out.Add((New-BurstEventRecord 'write-burst-ended' $b $rowBy $PcFolders $IncludeFolders ([long]$endedMs) ([string](Get-BurstValue $b 'reason'))))
        }
    }
    $out.ToArray()
}
#endregion 77

#region 78 PCs and folders (#78)
# A field of a hashtable or an object (the CIM readers' records are objects, the monitor's are hashtables), or $null.
function Get-PcsValue {
    param([object]$Item, [string]$Name)
    if ($null -eq $Item) { return $null }
    if ($Item -is [Collections.IDictionary]) { if ($Item.Contains($Name)) { return $Item[$Name] } else { return $null } }
    $p = $Item.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# The folder of an open file: its path below the share, without the last part (the file's name, which is dropped
# here and goes no further), cut to 3 levels and 120 characters. A file in the share's root has no folder: ''.
function Get-PcsFolderPath {
    param([string]$Path, [int]$ShareLength, [int]$Levels = 3, [int]$Characters = 120)
    $parts = @($Path.Substring($ShareLength).Split('\') | Where-Object { $_ })
    if ($parts.Count -le 1) { return '' }
    $dirs = @($parts[0..($parts.Count - 2)])
    if ($dirs.Count -gt $Levels) { $dirs = @($dirs[0..($Levels - 1)]) }
    $text = $dirs -join '\'
    if ($text.Length -gt $Characters) { $text = $text.Substring(0, $Characters) }
    $text
}

# Sessions + open files -> the session PCs and, per PC address, the folders its files are in.
# Sessions: records with SessionId, ClientComputerName, ClientUserName, Dialect (Get-SmbSessionList). OpenFiles:
# SessionId, Path, Permissions, Signed, Encrypted (Get-SmbOpenFileList). Shares: name and path (Monitor.Shares).
# Returns @{ SessionPcs (session id -> session PC); PcFolders (address -> up to 10 folder rows); Capped }.
# Privacy: a file's name is cut off in Get-PcsFolderPath and is held by nothing that comes out of here.
function Get-SessionPcs {
    param([object[]]$Sessions, [object[]]$OpenFiles, [object[]]$Shares, [hashtable]$Index, [string[]]$ServerAddresses, [bool]$Folders, [int]$MaxOpenFiles = 5000)
    if (-not $Index) { $Index = @{} }
    $sessionPcs = @{}; $keyOf = @{}
    foreach ($s in $Sessions) {
        $id = [string](Get-PcsValue $s 'SessionId')
        if (-not $id) { continue }
        $who = Find-NamedPC -Address ([string](Get-PcsValue $s 'ClientComputerName')) -Index $Index -ServerAddresses $ServerAddresses
        $sessionPcs[$id] = @{
            address = $who.Address; name = $who.Name; known = $who.Known; account = [string](Get-PcsValue $s 'ClientUserName')
            smb = [string](Get-PcsValue $s 'Dialect'); signed = $null; encrypted = $null; writingFiles = $false
        }
        $keyOf[$id] = if ($who.Address) { $who.Address } else { "session:$id" }
    }
    # Shares, longest path first; at equal length a share not ending in $ comes first.
    $shareList = New-Object System.Collections.Generic.List[object]
    if ($Folders) {
        foreach ($sh in $Shares) {
            $path = [string](Get-PcsValue $sh 'path')
            $name = [string](Get-PcsValue $sh 'name')
            if (-not $path -or -not $name) { continue }
            $trim = $path.TrimEnd('\')
            $shareList.Add(@{ Name = $name; Prefix = "$trim\"; Length = $trim.Length; Admin = $name.EndsWith('$') })
        }
    }
    $ordered = @($shareList | Sort-Object -Property @{ Expression = { $_.Length }; Descending = $true }, @{ Expression = { $_.Admin } })
    $agg = @{}; $folderMap = @{}
    $seen = 0; $capped = $false
    foreach ($f in $OpenFiles) {
        if ($null -eq $f) { continue }
        if ($seen -ge $MaxOpenFiles) { $capped = $true; break }
        $seen++
        $id = [string](Get-PcsValue $f 'SessionId')
        if (-not $keyOf.ContainsKey($id)) { continue }
        $key = $keyOf[$id]
        if (-not $agg.ContainsKey($key)) { $agg[$key] = @{ Files = 0; Signed = 0; Encrypted = 0; Writing = $false } }
        $a = $agg[$key]
        $a.Files++
        if (Get-PcsValue $f 'Signed') { $a.Signed++ }
        if (Get-PcsValue $f 'Encrypted') { $a.Encrypted++ }
        $writing = (([long](Get-PcsValue $f 'Permissions')) -band 0x50000006) -ne 0
        if ($writing) { $a.Writing = $true }
        $address = $sessionPcs[$id].address
        if (-not $Folders -or -not $address) { continue }
        $path = [string](Get-PcsValue $f 'Path')
        foreach ($sh in $ordered) {
            if ($path.StartsWith($sh.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $folder = Get-PcsFolderPath -Path $path -ShareLength $sh.Length
                if (-not $folderMap.ContainsKey($address)) { $folderMap[$address] = @{} }
                $fk = "$($sh.Name)|$folder"
                if (-not $folderMap[$address].ContainsKey($fk)) { $folderMap[$address][$fk] = @{ share = $sh.Name; path = $folder; files = 0; writing = $false } }
                $row = $folderMap[$address][$fk]
                $row.files++
                if ($writing) { $row.writing = $true }
                break
            }
        }
    }
    foreach ($id in @($sessionPcs.Keys)) {
        $a = $agg[$keyOf[$id]]
        if ($a) {
            $sessionPcs[$id].signed = ($a.Signed -eq $a.Files)
            $sessionPcs[$id].encrypted = ($a.Encrypted -eq $a.Files)
            $sessionPcs[$id].writingFiles = [bool]$a.Writing
        }
    }
    $pcFolders = @{}
    foreach ($address in @($folderMap.Keys)) {
        $rows = @($folderMap[$address].Values | Sort-Object -Property @{ Expression = { $_.files }; Descending = $true }, @{ Expression = { $_.share } }, @{ Expression = { $_.path } } | Select-Object -First 10)
        $pcFolders[$address] = $rows
    }
    @{ SessionPcs = $sessionPcs; PcFolders = $pcFolders; Capped = $capped }
}

# PC seconds (Group-SessionsByPc) + session PCs + folders + bursts -> the /stats pcs rows, busiest first, at most MaxPcs.
function Get-TransferPcRows {
    param([object[]]$Pcs, [hashtable]$SessionPcs, [hashtable]$PcFolders, [object[]]$Bursts, [int]$MaxPcs = 64)
    $active = @{}
    foreach ($b in $Bursts) { if ($null -ne $b -and $null -eq (Get-PcsValue $b 'endedMs')) { $active[[string](Get-PcsValue $b 'key')] = $true } }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($pc in $Pcs) {
        if ($null -eq $pc) { continue }
        $sp = $null
        if ($SessionPcs) { foreach ($id in @(Get-PcsValue $pc 'sessions')) { if ($SessionPcs.ContainsKey([string]$id)) { $sp = $SessionPcs[[string]$id]; break } } }
        $address = Get-PcsValue $pc 'address'
        $folders = @()
        if ($address -and $PcFolders -and $PcFolders.ContainsKey($address)) { $folders = @($PcFolders[$address]) }
        $rows.Add(@{
            name = (Get-PcsValue $sp 'name'); address = $address; known = [bool](Get-PcsValue $sp 'known'); account = (Get-PcsValue $sp 'account')
            smb = (Get-PcsValue $sp 'smb'); signed = (Get-PcsValue $sp 'signed'); encrypted = (Get-PcsValue $sp 'encrypted')
            readBps = (Get-PcsValue $pc 'readBps'); writeBps = (Get-PcsValue $pc 'writeBps'); openFiles = (Get-PcsValue $pc 'openFiles')
            writing = [bool](Get-PcsValue $pc 'writing'); burst = [bool]$active[[string](Get-PcsValue $pc 'key')]; folders = $folders
        })
    }
    $sorted = @($rows | Sort-Object -Property @{ Expression = { [double]$_.readBps + [double]$_.writeBps }; Descending = $true }, @{ Expression = { [string]$_.address } })
    foreach ($r in ($sorted | Select-Object -First $MaxPcs)) { $r }
}

# Unknown PCs (Seen is Monitor.UnknownSeen: address -> @{ Written }): unknown-pc when an unknown address first
# appears, unknown-pc-write on its first writing second. An address gone from the rows is forgotten, so a reconnect
# raises both again. Nothing without administrator (the rows have no addresses to judge). Records: Type, Key, Data.
function Get-UnknownPcEvents {
    param([hashtable]$Seen, [object[]]$PcRows, [bool]$Elevated)
    if (-not $Elevated) { return }
    $present = @{}
    foreach ($r in $PcRows) {
        $address = [string](Get-PcsValue $r 'address')
        if (-not $address -or (Get-PcsValue $r 'known')) { continue }
        $present[$address] = $true
        $data = { @{ pc = 'unknown'; address = $address; account = (Get-PcsValue $r 'account') } }
        if (-not $Seen.ContainsKey($address)) {
            $Seen[$address] = @{ Written = $false }
            @{ Type = 'unknown-pc'; Key = "unknown-pc|$address"; Data = (& $data) }
        }
        if ((Get-PcsValue $r 'writing') -and -not $Seen[$address].Written) {
            $Seen[$address].Written = $true
            @{ Type = 'unknown-pc-write'; Key = "unknown-pc-write|$address"; Data = (& $data) }
        }
    }
    foreach ($address in @($Seen.Keys)) { if (-not $present.ContainsKey($address)) { $Seen.Remove($address) } }
}
#endregion 78

#region 79 (none: #79's code is in Maintenance.psm1, Web.psm1 and web\app.js)
#endregion 79
