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
        Shares = @(); SessionPcs = @{}; PcFolders = @{}; OpenFilesCapped = $false; UpdatedMs = $null; Busy = $false
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
    if ($Tick % 12 -eq 0) { $Monitor.Shares = @(Get-ShareDriveMap -Shares @(& $Readers.Shares)) }
    if ($Monitor.Elevated -and ($Monitor.Busy -or $Tick % 6 -eq 0)) {
        $sessions = @(& $Readers.Sessions)
        $files = @(& $Readers.OpenFiles)
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
    $rows = @(@($Reading.shares) | Where-Object { $_.readBps + $_.writeBps -gt 0 -or $_.openFiles -gt 0 } |
        Sort-Object -Property @{ Expression = { $_.readBps + $_.writeBps }; Descending = $true }, @{ Expression = { $_.name }; Descending = $false } |
        Select-Object -First $MaxShares)
    $shares = @()
    foreach ($s in $rows) {
        $entry = $index[[string]$s.name]
        $row = @{}
        foreach ($k in $s.Keys) { $row[$k] = $s[$k] }
        if ($entry) { $row.name = $entry.name }
        $row.drive = if ($entry) { $entry.drive } else { $null }
        $shares += $row
    }
    $reason = if (-not $Reading.available) { 'SMB counters are not available' }
              elseif (-not $Elevated) { 'PCs and folders need administrator' }
              elseif ($Capped) { 'more than 5,000 open files' }
              else { $null }
    @{ available = [bool]$Reading.available; reason = $reason; bottleneck = $Bottleneck; shares = $shares; pcs = @($PcRows); updatedMs = $UpdatedMs }
}

# One second of the transfer monitor, called by the fast sampler with the SMB reading: PC rows, the bottleneck, the
# bursts, the `transfers` value in the state, and the two history lines.
function Invoke-TransferTick {
    param([hashtable]$State, [hashtable]$Monitor, [hashtable]$Reading, [long]$NowMs, $History)
    $pcs = @(Group-SessionsByPc -Sessions @($Reading.sessions) -SessionPcs $Monitor.SessionPcs)
    $bottleneck = Get-Bottleneck -Reading $Reading -Shares @($Monitor.Shares) -Cpu ([double]$State.cpu) `
        -Percent $Monitor.BottleneckPercent -Hold $Monitor.Hold -NowMs $NowMs
    $Monitor.BurstList = @(Update-WriteBursts -State $Monitor.Bursts -Pcs $pcs -Shares @($Reading.shares) -NowMs $NowMs `
        -Files $Monitor.BurstFiles -WindowSeconds $Monitor.BurstWindowSeconds -QuietMs ([long]$Monitor.BurstQuietMinutes * 60000))
    $rows = @(Get-TransferPcRows -Pcs $pcs -SessionPcs $Monitor.SessionPcs -PcFolders $Monitor.PcFolders -Bursts $Monitor.BurstList)
    $Monitor.Busy = [bool]($Reading.readBps + $Reading.writeBps -gt 0 -or @(@($Reading.shares) | Where-Object { $_.openFiles -gt 0 }).Count)
    $State.transfers = New-TransfersSnapshot -Reading $Reading -Bottleneck $bottleneck -ShareList @($Monitor.Shares) -PcRows $rows `
        -Elevated ([bool]$Monitor.Elevated) -Capped ([bool]$Monitor.OpenFilesCapped) -UpdatedMs $Monitor.UpdatedMs
    if ($History) {
        $History.Append('smbRead', $(if ($Reading.available) { $Reading.readBps }), $NowMs)
        $History.Append('smbWrite', $(if ($Reading.available) { $Reading.writeBps }), $NowMs)
    }
}
#endregion 76

#region 77 Write bursts (#77). Stubs until #77 lands: no bursts, no events.
function Update-WriteBursts { param([hashtable]$State, [object[]]$Pcs, [object[]]$Shares, [long]$NowMs, [int]$Files, [int]$WindowSeconds, [long]$QuietMs) }
function Get-BurstEvents { param([object[]]$Old, [object[]]$New, [object[]]$PcRows, [hashtable]$PcFolders, [bool]$IncludeFolders, [long]$StopMs) }
#endregion 77

#region 78 PCs and folders (#78). Stubs until #78 lands: no PCs, no events.
function Get-SessionPcs { param([object[]]$Sessions, [object[]]$OpenFiles, [object[]]$Shares, [hashtable]$Index, [string[]]$ServerAddresses, [bool]$Folders, [int]$MaxOpenFiles = 5000) @{ SessionPcs = @{}; PcFolders = @{}; Capped = $false } }
function Get-TransferPcRows { param([object[]]$Pcs, [hashtable]$SessionPcs, [hashtable]$PcFolders, [object[]]$Bursts, [int]$MaxPcs = 64) }
function Get-UnknownPcEvents { param([hashtable]$Seen, [object[]]$PcRows, [bool]$Elevated) }
#endregion 78

#region 79 (none: #79's code is in Maintenance.psm1, Web.psm1 and web\app.js)
#endregion 79
