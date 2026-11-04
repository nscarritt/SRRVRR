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

Export-ModuleMember -Function New-EventId, New-SrrEvent, New-SrrError, New-SrrQueue, Add-SrrQueueItem, New-EventStore, Invoke-QueueDrain
