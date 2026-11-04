# The event log's reading side (spec section 4): the in-memory index that answers /events without reading files per
# request, and the daily cleanup of both logs. Events.psm1's New-EventLogWriter and Logging.psm1's New-DailyLog
# write the files: logs\events-YYYY-MM-DD.jsonl, one JSON object per line, dated by local time.
Set-StrictMode -Version 2

# The names cleanup may delete: the event log and the crash and error log, nothing else.
$script:LogNamePattern = '^(events|srrvrr)-(\d{4}-\d{2}-\d{2})\.(jsonl|log)$'
$script:EventFilePattern = '^events-(\d{4}-\d{2}-\d{2})\.jsonl$'

# The date in a log file's name, or $null when it isn't a real date (srrvrr-2026-13-40.log).
function Get-NameDate([string]$Text) {
    $d = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($Text, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { $d } else { $null }
}

# Each line of a JSON-lines file as its parsed object. A line that isn't JSON (empty, garbled or cut off) comes back
# as @{ Line; Error } instead of throwing. The file is opened so a writer can keep appending to it.
function Read-JsonLines {
    param([Parameter(Mandatory)][string]$Path)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.Trim()) { @{ Line = $line; Error = 'empty line' }; continue }
            try { ConvertFrom-Json -InputObject $line -ErrorAction Stop }
            catch { @{ Line = $line; Error = $_.Exception.Message } }
        }
    } finally { $reader.Dispose() }
}

# A logged event as the index keeps it: an object with a whole-number id and time, or $null if it isn't one.
function ConvertTo-IndexedEvent([object]$Item) {
    if ($Item -is [Collections.IDictionary]) { $Item = [pscustomobject]$Item }
    if ($Item -isnot [Management.Automation.PSCustomObject]) { return $null }
    foreach ($name in 'id', 'time') {
        $p = $Item.PSObject.Properties[$name]
        if (-not $p -or -not ($p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [double] -or $p.Value -is [decimal])) { return $null }
    }
    $Item
}

# Loads the logged events of the last Days days (today is day 1) from LogDir's events-YYYY-MM-DD.jsonl files,
# oldest first. Returns the index: Events (the newest MaxEvents, oldest first), LastId, BadLines (lines skipped
# because they weren't a logged event) and BadLineMessage (one line for the error log, or $null when none were
# skipped). Add(<logged event>) appends an event the writer has just written and returns $false for an id the
# index already has. MaxEvents defaults to the /events limit, since an older event could never be returned.
function Initialize-EventIndex {
    param(
        [Parameter(Mandatory)][string]$LogDir, [Parameter(Mandatory)][ValidateRange(1, 36500)][int]$Days,
        [Parameter(Mandatory)][DateTimeOffset]$Now, [ValidateRange(1, 1000000)][int]$MaxEvents = 1000
    )
    $index = [pscustomobject]@{
        Events = New-Object System.Collections.Generic.List[object]; MaxEvents = $MaxEvents; LastId = 0L
        BadLines = 0; BadLineMessage = $null
    }
    $index | Add-Member ScriptMethod Add {
        param([object]$Item)
        $e = ConvertTo-IndexedEvent $Item
        if ($null -eq $e -or [long]$e.id -le $this.LastId) { return $false }
        $this.Events.Add($e)
        $this.LastId = [long]$e.id
        if ($this.Events.Count -gt $this.MaxEvents) { $this.Events.RemoveRange(0, $this.Events.Count - $this.MaxEvents) }
        $true
    }
    if (-not [IO.Directory]::Exists($LogDir)) { return $index }

    $first = $Now.Date.AddDays( - ($Days - 1))
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in (New-Object IO.DirectoryInfo($LogDir)).GetFiles('events-*.jsonl')) {
        if ($f.Name -cnotmatch $script:EventFilePattern) { continue }
        $date = Get-NameDate $Matches[1]
        if ($null -ne $date -and $date -ge $first) { $files.Add(@{ Date = $date; Path = $f.FullName; Name = $f.Name }) }
    }
    $bad = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($files | Sort-Object { $_.Date })) {
        $skipped = 0
        try {
            foreach ($row in (Read-JsonLines -Path $f.Path)) {
                if (-not $index.Add($row)) { $skipped++ }
            }
        } catch { $bad.Add("$($f.Name) (unreadable: $($_.Exception.Message))"); continue }
        if ($skipped) { $index.BadLines += $skipped; $bad.Add("$($f.Name) ($skipped)") }
    }
    if ($bad.Count) { $index.BadLineMessage = "event index: skipped $($index.BadLines) bad or cut-off lines in $($bad -join ', ')" }
    $index
}

# The indexed events from the last Days days (today is day 1, from local midnight in Now's offset), newest first,
# at most Limit. Memory only: no file is read. Always returns an array, empty when there are none.
function Get-IndexedEvents {
    param(
        [Parameter(Mandatory)][object]$Index, [Parameter(Mandatory)][ValidateRange(1, 36500)][int]$Days,
        [Parameter(Mandatory)][DateTimeOffset]$Now, [ValidateRange(1, 1000000)][int]$Limit = 1000
    )
    $fromMs = ([DateTimeOffset]::new($Now.Date.AddDays( - ($Days - 1)), $Now.Offset)).ToUnixTimeMilliseconds()
    $events = $Index.Events
    $out = New-Object System.Collections.Generic.List[object]
    for ($i = $events.Count - 1; $i -ge 0 -and $out.Count -lt $Limit; $i--) {
        $e = $events[$i]
        if ([long]$e.time -lt $fromMs) { break }
        $out.Add($e)
    }
    , $out.ToArray()
}

# Deletes old event and crash logs: only regular files (not folders, links or junctions) directly in LogDir whose
# names match the log pattern, aged by the date in the name (today is day 1, so a file dated exactly RetentionDays
# ago goes). The newest FloorDays days of files (counted from the newest file's date) are always kept. A clock
# earlier than the newest file's date, or more than RetentionDays past it, skips the whole run, so a wrong clock
# can't wipe the logs. Returns @{ Deleted = names deleted; Errors = lines for the error log (one for a skipped run,
# one per file that couldn't be deleted); Skipped = $true when the clock check stopped the run }.
function Remove-OldLogs {
    param(
        [Parameter(Mandatory)][string]$LogDir, [Parameter(Mandatory)][ValidateRange(1, 36500)][int]$RetentionDays,
        [Parameter(Mandatory)][DateTimeOffset]$Now, [ValidateRange(1, 36500)][int]$FloorDays = 7
    )
    $deleted = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $result = @{ Deleted = [string[]]@(); Errors = [string[]]@(); Skipped = $false }
    if (-not [IO.Directory]::Exists($LogDir)) { return $result }

    $skip = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint
    $logs = New-Object System.Collections.Generic.List[object]
    foreach ($item in (New-Object IO.DirectoryInfo($LogDir)).GetFileSystemInfos()) {
        if ($item.Name -cnotmatch $script:LogNamePattern) { continue }
        if ($item.Attributes -band $skip) { continue }
        $date = Get-NameDate $Matches[2]
        if ($null -ne $date) { $logs.Add(@{ Name = $item.Name; Path = $item.FullName; Date = $date }) }
    }
    if (-not $logs.Count) { return $result }

    $today = $Now.Date
    $newest = ($logs | ForEach-Object { $_.Date } | Sort-Object | Select-Object -Last 1)
    $clockError = $null
    if ($today -lt $newest) {
        $clockError = "log cleanup skipped: the clock ($($today.ToString('yyyy-MM-dd'))) is earlier than the newest log file's date ($($newest.ToString('yyyy-MM-dd')))"
    } elseif (($today - $newest).Days -gt $RetentionDays) {
        $clockError = "log cleanup skipped: the clock ($($today.ToString('yyyy-MM-dd'))) is more than $RetentionDays days past the newest log file's date ($($newest.ToString('yyyy-MM-dd')))"
    }
    if ($clockError) { $result.Errors = [string[]]@($clockError); $result.Skipped = $true; return $result }

    foreach ($log in @($logs | Sort-Object { $_.Date })) {
        if (($today - $log.Date).Days -lt $RetentionDays) { continue }
        if (($newest - $log.Date).Days -lt $FloorDays) { continue }
        try {
            [IO.File]::Delete($log.Path)
            $deleted.Add($log.Name)
        } catch { $errors.Add("log cleanup couldn't delete $($log.Name): $($_.Exception.Message)") }
    }
    $result.Deleted = $deleted.ToArray()
    $result.Errors = $errors.ToArray()
    $result
}

# Whether cleanup should run: right after startup (no last run), then once Interval has passed since the last run.
function Test-CleanupDue {
    param([AllowNull()][Nullable[DateTimeOffset]]$LastRun, [Parameter(Mandatory)][DateTimeOffset]$Now, [TimeSpan]$Interval = [TimeSpan]::FromHours(24))
    if ($null -eq $LastRun) { return $true }
    ($Now - [DateTimeOffset]$LastRun) -ge $Interval
}

Export-ModuleMember -Function Read-JsonLines, Initialize-EventIndex, Get-IndexedEvents, Remove-OldLogs, Test-CleanupDue
