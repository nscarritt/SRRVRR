# Events decided on the server (spec section 4): ids that keep increasing, a shared queue any thread can add to, and
# one drain on the main thread that assigns ids, suppresses repeats, hands logged events and errors to the writers
# and publishes the in-memory events as a new array each time.
Set-StrictMode -Version 2

# The larger of now in ms and the last id + 1, so a clock that steps back can't reuse or reorder ids.
function New-EventId {
    param([long]$NowMs, [long]$LastId)
    [Math]::Max($NowMs, $LastId + 1)
}

# An event before the drain gives it an id and a time. Banner and Logged say where it goes; the drain marks it
# maintenance when Maintenance is on.
function New-SrrEvent {
    param(
        [string]$Type, [ValidateSet('info', 'warn', 'flag')][string]$Severity, [string]$Key, [hashtable]$Data = @{},
        [bool]$Banner = $false, [bool]$Logged = $false
    )
    if (-not $Type) { throw 'An event needs a type.' }
    if (-not $Severity) { throw 'An event needs a severity.' }
    if (-not $Key) { throw "Event '$Type' needs a key for repeat suppression." }
    [pscustomobject]@{
        id = 0L; time = 0L; type = $Type; severity = $Severity; key = $Key; data = $Data
        maintenance = $false; banner = $Banner; logged = $Logged
    }
}

# An error for the crash and error log, raised from any thread like an event.
function New-SrrError {
    param([string]$Source, [string]$Message)
    [pscustomobject]@{ kind = 'error'; source = $Source; message = $Message }
}

function New-SrrQueue { , (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') }

function Add-SrrQueueItem {
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$Queue, [object]$Item)
    $Queue.Enqueue($Item)
}

# The last Size events in memory. Published is replaced, never changed in place, so a reader serializing it can't
# fail with "collection was modified".
function New-EventStore {
    param([Parameter(Mandatory)][scriptblock]$Clock, [int]$Size = 200, [TimeSpan]$SuppressFor = [TimeSpan]::FromMinutes(10))
    [pscustomobject]@{ Clock = $Clock; Size = $Size; SuppressFor = $SuppressFor; Published = [object[]]@(); LastId = 0L; LastKept = @{} }
}

# Empties the queue. Writers: @{ Event = { param($event) }; Error = { param($source, $message) } }, either optional.
# Maintenance, when given, says whether Maintenance is on. Returns the number of events kept.
function Invoke-QueueDrain {
    param(
        [System.Collections.Concurrent.ConcurrentQueue[object]]$Queue, [object]$Store, [hashtable]$Writers = @{},
        [scriptblock]$Clock, [scriptblock]$Maintenance
    )
    $kept = New-Object System.Collections.Generic.List[object]
    $item = $null
    while ($Queue.TryDequeue([ref]$item)) {
        if ($item.PSObject.Properties['kind'] -and $item.kind -eq 'error') {
            if ($Writers['Error']) { & $Writers['Error'] $item.source $item.message }
            continue
        }
        $now = & $Clock
        $nowMs = $now.ToUnixTimeMilliseconds()
        $last = $Store.LastKept[$item.key]
        if ($null -ne $last -and ($nowMs - $last) -lt $Store.SuppressFor.TotalMilliseconds) { continue }
        $Store.LastKept[$item.key] = $nowMs
        $item.id = New-EventId -NowMs $nowMs -LastId $Store.LastId
        $item.time = $nowMs
        if ($Maintenance) { $item.maintenance = [bool](& $Maintenance) }
        $Store.LastId = $item.id
        if ($item.logged -and $Writers['Event']) { & $Writers['Event'] $item }
        $kept.Add($item)
    }
    if ($kept.Count) {
        $all = New-Object System.Collections.Generic.List[object]
        $all.AddRange([object[]]$Store.Published)
        $all.AddRange($kept)
        $skip = [Math]::Max(0, $all.Count - $Store.Size)
        $Store.Published = [object[]]$all.GetRange($skip, $all.Count - $skip).ToArray()
    }
    $kept.Count
}

# The starting set of events (spec section 4): severity, whether it shows a banner, whether it's logged.
$script:EventTypes = @{
    'player-join' = @{ Severity = 'info'; Banner = $true; Logged = $false }
    'player-leave' = @{ Severity = 'info'; Banner = $true; Logged = $false }
    'plex-stream' = @{ Severity = 'info'; Banner = $true; Logged = $false }
    'service-offline' = @{ Severity = 'warn'; Banner = $true; Logged = $true }
    'service-back' = @{ Severity = 'warn'; Banner = $true; Logged = $true }
    'query-stopped' = @{ Severity = 'warn'; Banner = $true; Logged = $true }
    'query-back' = @{ Severity = 'warn'; Banner = $true; Logged = $true }
    'restart-pending' = @{ Severity = 'info'; Banner = $false; Logged = $true }
    'drive-health' = @{ Severity = 'flag'; Banner = $true; Logged = $true }
    'data-drive-missing' = @{ Severity = 'flag'; Banner = $true; Logged = $true }
    'data-fallback' = @{ Severity = 'flag'; Banner = $true; Logged = $true }
    'share-found' = @{ Severity = 'flag'; Banner = $true; Logged = $true }
    'history-save-failed' = @{ Severity = 'warn'; Banner = $true; Logged = $true }
    'sampler-error' = @{ Severity = 'warn'; Banner = $false; Logged = $true }
    'worker-stopped' = @{ Severity = 'warn'; Banner = $false; Logged = $true }
    'maintenance-on' = @{ Severity = 'info'; Banner = $false; Logged = $true }
    'maintenance-off' = @{ Severity = 'info'; Banner = $false; Logged = $true }
    'started' = @{ Severity = 'info'; Banner = $false; Logged = $true }
    'stopped' = @{ Severity = 'info'; Banner = $false; Logged = $true }
}

function Get-EventTypes { $script:EventTypes.Clone() }

# An event of a known type, its severity, banner and logging taken from the table. Key defaults to the type.
function New-TypedEvent {
    param([string]$Type, [hashtable]$Data = @{}, [string]$Key)
    $t = $script:EventTypes[$Type]
    if (-not $t) { throw "Unknown event type '$Type'." }
    if (-not $Key) { $Key = $Type }
    New-SrrEvent -Type $Type -Severity $t.Severity -Key $Key -Data $Data -Banner $t.Banner -Logged $t.Logged
}

# A list comes back unrolled, so an empty one is $null: use Test-Field to ask whether it's there.
function Get-Field([object]$Table, [string]$Name) {
    if ($Table -is [Collections.IDictionary] -and $Table.Contains($Name)) { $Table[$Name] } else { $null }
}
function Test-Field([object]$Table, [string]$Name) { $Table -is [Collections.IDictionary] -and $Table.Contains($Name) }

# What changed between two readings of the state. Nothing on the first observation (no replay): a section missing
# from either reading raises nothing. Maintenance, start and stop, the data folder, history saves and errors are
# raised by their owners with New-TypedEvent.
function Get-StateEvents {
    param([object]$Old, [object]$New)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Old -or -not $New) { return }
    $oa = Get-Field $Old 'activity'; $na = Get-Field $New 'activity'
    foreach ($name in 'Valheim', 'Plex') {
        $o = Get-Field $oa $name; $n = Get-Field $na $name
        if (-not $o -or -not $n) { continue }
        $oErr = Get-Field $o 'error'; $nErr = Get-Field $n 'error'
        if (-not $oErr -and $nErr -and (Get-Field $n 'alert')) { $out.Add((New-TypedEvent -Type 'query-stopped' -Data @{ name = $name; error = [string]$nErr } -Key "query-stopped|$name")) }
        elseif ($oErr -and (Get-Field $o 'alert') -and -not $nErr) { $out.Add((New-TypedEvent -Type 'query-back' -Data @{ name = $name } -Key "query-back|$name")) }
        if ($oErr -or $nErr) { continue }
        if ($name -eq 'Valheim') {
            $op = Get-Field $o 'players'; $np = Get-Field $n 'players'
            if ($null -eq $op -or $null -eq $np -or $op -eq $np) { continue }
            $oNames = @(Get-Field $o 'names' | Where-Object { $_ } | ForEach-Object { Get-Field $_ 'name' })
            $nNames = @(Get-Field $n 'names' | Where-Object { $_ } | ForEach-Object { Get-Field $_ 'name' })
            $up = $np -gt $op
            $who = if ($up) { @($nNames | Where-Object { $oNames -notcontains $_ }) } else { @($oNames | Where-Object { $nNames -notcontains $_ }) }
            $type = if ($up) { 'player-join' } else { 'player-leave' }
            $out.Add((New-TypedEvent -Type $type -Data @{ players = [int]$np; change = [int][Math]::Abs($np - $op); who = $who } -Key "$type|$np|$($who -join ',')"))
        } else {
            if (-not (Test-Field $o 'items') -or -not (Test-Field $n 'items')) { continue }
            $oKeys = @(Get-Field $o 'items' | Where-Object { $_ } | ForEach-Object { Get-Field $_ 'key' })
            foreach ($i in @(Get-Field $n 'items' | Where-Object { $_ })) {
                $k = Get-Field $i 'key'
                if (-not $k -or $oKeys -contains $k) { continue }
                $data = @{}; foreach ($f in $i.Keys) { $data[$f] = $i[$f] }
                $out.Add((New-TypedEvent -Type 'plex-stream' -Data $data -Key "plex-stream|$k"))
            }
        }
    }
    $os = @{}; foreach ($s in @(Get-Field $Old 'services' | Where-Object { $_ })) { $os[[string](Get-Field $s 'name')] = [bool](Get-Field $s 'online') }
    foreach ($s in @(Get-Field $New 'services' | Where-Object { $_ })) {
        $name = [string](Get-Field $s 'name'); $on = [bool](Get-Field $s 'online')
        if (-not $os.ContainsKey($name) -or $os[$name] -eq $on) { continue }
        $type = if ($on) { 'service-back' } else { 'service-offline' }
        $out.Add((New-TypedEvent -Type $type -Data @{ name = $name } -Key "$type|$name"))
    }
    if ($Old -is [Collections.IDictionary] -and $Old.Contains('restartPending') -and -not $Old['restartPending'] -and (Get-Field $New 'restartPending')) {
        $out.Add((New-TypedEvent -Type 'restart-pending' -Data @{ reason = [string](Get-Field $New 'restartReason') }))
    }
    $od = @{}; foreach ($d in @(Get-Field $Old 'drives' | Where-Object { $_ })) { $od[[string](Get-Field $d 'letter')] = [string](Get-Field $d 'health') }
    foreach ($d in @(Get-Field $New 'drives' | Where-Object { $_ })) {
        $letter = [string](Get-Field $d 'letter'); $health = [string](Get-Field $d 'health')
        if (-not $od.ContainsKey($letter) -or $od[$letter] -eq $health) { continue }
        $type = if ($health -eq 'Missing') { 'data-drive-missing' } else { 'drive-health' }
        $out.Add((New-TypedEvent -Type $type -Data @{ letter = $letter; health = $health; was = $od[$letter] } -Key "$type|$letter|$health"))
    }
    $out
}

# The copy of an event that goes to a log: no player, user or device names and no titles, only counts (spec 4).
function ConvertTo-LoggedEvent {
    param([object]$Item)
    $data = [ordered]@{}
    foreach ($k in @($Item.data.Keys)) { if ($k -notin 'who', 'names', 'user', 'title', 'device', 'app', 'key') { $data[$k] = $Item.data[$k] } }
    [ordered]@{ id = $Item.id; time = $Item.time; type = $Item.type; severity = $Item.severity; maintenance = $Item.maintenance; data = $data }
}

# The drain's Event writer for an events-YYYY-MM-DD.jsonl daily log: one JSON object per line, flags written past
# the daily cap.
function New-EventLogWriter {
    param([Parameter(Mandatory)][object]$Log)
    $convert = ${function:ConvertTo-LoggedEvent}
    { param($e) $Log.Write((ConvertTo-Json -InputObject (& $convert $e) -Compress -Depth 5), ($e.severity -eq 'flag')) }.GetNewClosure()
}

Export-ModuleMember -Function New-EventId, New-SrrEvent, New-SrrError, New-SrrQueue, Add-SrrQueueItem, New-EventStore, Invoke-QueueDrain,
    Get-EventTypes, New-TypedEvent, Get-StateEvents, ConvertTo-LoggedEvent, New-EventLogWriter
