# Maintenance (spec sections 4 and 8): the on/off state with its end time, state\maintenance.json, the checks on a
# POST /maintenance request, and the rate limit. Time comes from a -Clock scriptblock or -Now; nothing here reads the
# clock. This module doesn't raise events: changes come back as records the caller turns into events and log lines,
#   @{ type = 'maintenance-on' | 'maintenance-off'; data = @{ address; untilMs; reason = 'requested' | 'expired' } }
# (address is $null for an expiry). The objects here are used on the main thread only.
Set-StrictMode -Version 2

$script:HourMs = 3600000.0

function New-MaintenanceChange([string]$Type, $Address, [long]$UntilMs, [string]$Reason) {
    @{ type = $Type; data = @{ address = $Address; untilMs = $UntilMs; reason = $Reason } }
}

# The Maintenance state. UntilMs is the end time (ms since 1970), 0 when off; -UntilMs restores a saved one (held to
# MaxHours from now). Methods: IsOn(); SetOn(address) and SetOff(address) return a change record; Poll(), called
# once a second, returns the 'expired' change exactly once when the time runs out, else $null; Snapshot() returns
# @{ on; untilMs } for /stats (untilMs $null when off).
function New-MaintenanceState {
    param([Parameter(Mandatory)][scriptblock]$Clock, [double]$Hours = 2, [double]$MaxHours = 8, [long]$UntilMs = 0)
    $maxMs = [long]($MaxHours * $script:HourMs)
    $m = [pscustomobject]@{ Clock = $Clock; DurationMs = [long]([Math]::Min($Hours, $MaxHours) * $script:HourMs); MaxMs = $maxMs; UntilMs = 0L }
    if ($UntilMs -gt 0) { $m.UntilMs = [Math]::Min($UntilMs, (& $Clock).ToUnixTimeMilliseconds() + $maxMs) }
    $m | Add-Member ScriptMethod NowMs { (& $this.Clock).ToUnixTimeMilliseconds() }
    $m | Add-Member ScriptMethod IsOn { $this.UntilMs -gt 0 -and $this.NowMs() -lt $this.UntilMs }
    $m | Add-Member ScriptMethod SetOn {
        param([string]$Address)
        $this.UntilMs = $this.NowMs() + $this.DurationMs
        New-MaintenanceChange 'maintenance-on' $Address $this.UntilMs 'requested'
    }
    # The record carries the end time that was in force (0 if it was already off).
    $m | Add-Member ScriptMethod SetOff {
        param([string]$Address)
        $was = $this.UntilMs
        $this.UntilMs = 0L
        New-MaintenanceChange 'maintenance-off' $Address $was 'requested'
    }
    $m | Add-Member ScriptMethod Poll {
        if ($this.UntilMs -le 0 -or $this.NowMs() -lt $this.UntilMs) { return $null }
        $ended = $this.UntilMs
        $this.UntilMs = 0L
        New-MaintenanceChange 'maintenance-off' $null $ended 'expired'
    }
    $m | Add-Member ScriptMethod Snapshot {
        $on = $this.IsOn()
        @{ on = $on; untilMs = $(if ($on) { $this.UntilMs } else { $null }) }
    }
    $m
}

# Writes maintenance.json.tmp, then swaps it in: {"version":1,"on":..,"untilMs":..}. An end time that has passed but
# not yet been reported by Poll() is saved as on, so the next start reports the expiry. Returns @{ Ok; Error } and
# never throws.
function Save-Maintenance {
    param($State, [string]$StatePath)
    $tmp = $null
    try {
        $until = [long]$State.UntilMs
        $on = if ($until -gt 0) { 'true' } else { 'false' }
        $json = '{"version":1,"on":' + $on + ',"untilMs":' + $until.ToString([Globalization.CultureInfo]::InvariantCulture) + '}'
        # [IO.Path]::Combine, not Join-Path: Join-Path fails on a drive that's gone (an unplugged USB data drive).
        $target = [IO.Path]::Combine($StatePath, 'maintenance.json')
        $tmp = "$target.tmp"
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        # [NullString]::Value: a plain $null would arrive as an empty backup path.
        if ([IO.File]::Exists($target)) { [IO.File]::Replace($tmp, $target, [NullString]::Value) } else { [IO.File]::Move($tmp, $target) }
        @{ Ok = $true; Error = $null }
    } catch {
        try { if ($tmp -and [IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } } catch { $null = $_ }
        @{ Ok = $false; Error = "couldn't save the maintenance state: $($_.Exception.Message)" }
    }
}

function Move-MaintenanceAside([string]$Path) {
    $bad = "$Path.bad"
    if ([IO.File]::Exists($bad)) { [IO.File]::Delete($bad) }
    [IO.File]::Move($Path, $bad)
}

# Reads at most MaxBytes + 1 bytes, so an oversized file (even one growing while it's read) is never read further.
# Returns the text, or $null when the file is over MaxBytes.
function Read-BoundedText([string]$Path, [long]$MaxBytes) {
    $buffer = New-Object byte[] ($MaxBytes + 1)
    $total = 0
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        while ($total -lt $buffer.Length) {
            $n = $fs.Read($buffer, $total, $buffer.Length - $total)
            if ($n -le 0) { break }
            $total += $n
        }
    } finally { $fs.Dispose() }
    if ($total -gt $MaxBytes) { return $null }
    $start = 0
    if ($total -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { $start = 3 }   # BOM
    [Text.Encoding]::UTF8.GetString($buffer, $start, $total - $start)
}

function Test-WholeNumber($Value) { $Value -is [int] -or $Value -is [long] }

# Loads state\maintenance.json. Returns @{ UntilMs; Change; Reason; Error }:
#   UntilMs  the end time to restore (pass it to New-MaintenanceState -UntilMs), 0 for off;
#   Change   the 'expired' change record (carrying the saved end time) when the file was on but its time ran out
#            while SRRVRR was stopped, else $null;
#   Reason   none, off, on, held (on, end held to MaxHours from now), expired, damaged, too big, unknown version,
#            unreadable;
#   Error    the text for one error line when the file couldn't be used, else $null.
# Damaged, oversized or unknown-version files are renamed maintenance.json.bad.
function Import-Maintenance {
    param([string]$StatePath, [DateTimeOffset]$Now, [double]$MaxHours = 8, [long]$MaxBytes = 4KB)
    $off = @{ UntilMs = 0L; Change = $null; Reason = 'none'; Error = $null }
    try {
        $path = [IO.Path]::Combine($StatePath, 'maintenance.json')
        if (-not [IO.File]::Exists($path)) { return $off }
        $text = Read-BoundedText $path $MaxBytes
        if ($null -eq $text) {
            Move-MaintenanceAside $path
            return @{ UntilMs = 0L; Change = $null; Reason = 'too big'; Error = "maintenance.json is too big (over $MaxBytes bytes); renamed maintenance.json.bad, Maintenance off" }
        }
        $doc = $null
        if ($text.TrimStart().StartsWith('{')) { try { $doc = $text | ConvertFrom-Json } catch { $doc = $null } }
        $names = @()
        if ($doc -is [PSCustomObject]) { $names = @($doc.PSObject.Properties | ForEach-Object { $_.Name }) }
        $valid = ($names -contains 'version') -and (Test-WholeNumber $doc.version)
        if ($valid -and $doc.version -ne 1) {
            Move-MaintenanceAside $path
            return @{ UntilMs = 0L; Change = $null; Reason = 'unknown version'; Error = "maintenance.json has unknown version $($doc.version); renamed maintenance.json.bad, Maintenance off" }
        }
        if ($valid) { $valid = ($names -contains 'on') -and $doc.on -is [bool] -and ($names -contains 'untilMs') -and (Test-WholeNumber $doc.untilMs) }
        if (-not $valid) {
            Move-MaintenanceAside $path
            return @{ UntilMs = 0L; Change = $null; Reason = 'damaged'; Error = 'maintenance.json is damaged; renamed maintenance.json.bad, Maintenance off' }
        }
        if (-not $doc.on) { return @{ UntilMs = 0L; Change = $null; Reason = 'off'; Error = $null } }
        $until = [long]$doc.untilMs
        $nowMs = $Now.ToUnixTimeMilliseconds()
        if ($until -le $nowMs) {
            return @{ UntilMs = 0L; Change = (New-MaintenanceChange 'maintenance-off' $null $until 'expired'); Reason = 'expired'; Error = $null }
        }
        $limit = $nowMs + [long]($MaxHours * $script:HourMs)
        if ($until -gt $limit) { return @{ UntilMs = $limit; Change = $null; Reason = 'held'; Error = $null } }
        @{ UntilMs = $until; Change = $null; Reason = 'on'; Error = $null }
    } catch {
        @{ UntilMs = 0L; Change = $null; Reason = 'unreadable'; Error = "couldn't read maintenance.json: $($_.Exception.Message); Maintenance off" }
    }
}

# The body of POST /maintenance: {"on": true} or {"on": false}, other fields ignored. Only a JSON object with a real
# JSON boolean "on" is accepted. Returns @{ Ok; On; Status } with Status 200, or 400 and On $null.
function ConvertFrom-MaintenanceBody {
    param([AllowNull()][AllowEmptyString()][string]$Body, [int]$MaxLength = 1024)
    $bad = @{ Ok = $false; On = $null; Status = 400 }
    if ([string]::IsNullOrWhiteSpace($Body) -or $Body.Length -gt $MaxLength) { return $bad }
    # Only an object: PowerShell 5.1 unrolls a one-element array into the object inside it.
    if (-not $Body.TrimStart().StartsWith('{')) { return $bad }
    $doc = $null
    try { $doc = $Body | ConvertFrom-Json } catch { return $bad }
    if ($doc -isnot [PSCustomObject]) { return $bad }
    $p = $doc.PSObject.Properties['on']
    if (-not $p -or $p.Value -isnot [bool]) { return $bad }
    @{ Ok = $true; On = [bool]$p.Value; Status = 200 }
}

# One header's value from a hashtable (keys in any case, even a case-sensitive one) or a NameValueCollection;
# $null when absent. Several keys differing only in case are joined with commas, as HttpListener joins repeats.
function Get-HeaderValue($Headers, [string]$Name) {
    if ($null -eq $Headers) { return $null }
    if ($Headers -is [Collections.Specialized.NameValueCollection]) { return $Headers.Get($Name) }
    $values = @(foreach ($k in @($Headers.Keys)) { if ([string]::Equals([string]$k, $Name, [StringComparison]::OrdinalIgnoreCase)) { [string]$Headers[$k] } })
    if ($values.Count -eq 0) { return $null }
    $values -join ','
}

# The Origin must be http://<host>:<Port> with a host from the same list as the Host check in Web.psm1
# (Test-HostAllowed): localhost, 127.0.0.1, [::1] and this machine's names and addresses, in any case.
function Test-OriginAllowed([string]$Origin, [int]$Port, [hashtable]$Identity) {
    if (-not $Origin) { return $false }
    if ($Origin -cnotmatch '^http://(?<h>\[[^\[\]/@?#\s]+\]|[^:/\[\]@?#\s]+)(:(?<p>\d+))?$') { return $false }
    $name = $matches['h'].TrimStart('[').TrimEnd(']')
    $p = 0
    if ($matches['p']) { if (-not [int]::TryParse($matches['p'], [ref]$p)) { return $false } }
    elseif ($Port -eq 80) { $p = 80 }   # browsers leave out :80
    if ($p -ne $Port -or $name.EndsWith('.')) { return $false }
    $name = ($name -replace '%.*$', '')   # IPv6 zone id
    $allowed = @('localhost', '127.0.0.1', '::1')
    if ($Identity) { $allowed += @($Identity['Names']) + @($Identity['Addresses'] | ForEach-Object { $_ -replace '%.*$', '' }) }
    foreach ($a in $allowed) { if ($a -and [string]::Equals($a, $name, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

# The guard on POST /maintenance (spec section 8): X-SRRVRR exactly 1, Content-Type application/json (parameters
# such as charset allowed), and an allowed Origin. No Origin is refused; Referer is never used. Returns @{ Ok; Status }
# with Status 200 or 403.
function Test-MaintenanceRequest {
    param($Headers, [hashtable]$Identity, [int]$Port)
    $refused = @{ Ok = $false; Status = 403 }
    if ((Get-HeaderValue $Headers 'X-SRRVRR') -cne '1') { return $refused }
    $type = Get-HeaderValue $Headers 'Content-Type'
    if (-not $type -or -not [string]::Equals($type.Split(';')[0].Trim(), 'application/json', [StringComparison]::OrdinalIgnoreCase)) { return $refused }
    if (-not (Test-OriginAllowed (Get-HeaderValue $Headers 'Origin') $Port $Identity)) { return $refused }
    @{ Ok = $true; Status = 200 }
}

# The rate limit on Maintenance changes: one per address per PerAddressSeconds, and PerDay per address a day (the
# clock's local date, as the daily logs use). Allow(address) returns $true (and counts the change) or $false.
# Refused requests are counted in .Refused; TakeRefused() returns that count and resets it, for one log line.
# Counters live in memory only, so a restart resets them.
function New-RateLimiter {
    param([Parameter(Mandatory)][scriptblock]$Clock, [int]$PerAddressSeconds = 10, [int]$PerDay = 60)
    $l = [pscustomobject]@{ Clock = $Clock; Window = [TimeSpan]::FromSeconds($PerAddressSeconds); PerDay = $PerDay; Day = ''; Counts = @{}; Last = @{}; Refused = 0 }
    $l | Add-Member ScriptMethod Allow {
        param([string]$Address)
        $now = & $this.Clock
        $day = $now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if ($day -ne $this.Day) {
            $this.Day = $day; $this.Counts = @{}
            # Forget addresses whose window has passed, so the table stays small.
            foreach ($k in @($this.Last.Keys)) { if (($now - $this.Last[$k]) -ge $this.Window) { $this.Last.Remove($k) } }
        }
        $last = $this.Last[$Address]
        # A clock that stepped back (now before the last change) doesn't lock the address out.
        $tooSoon = $null -ne $last -and $now -ge $last -and ($now - $last) -lt $this.Window
        # Per address, so one device that uses up its changes can't lock the others out until midnight.
        $count = [int]$this.Counts[$Address]
        if ($tooSoon -or $count -ge $this.PerDay) { $this.Refused++; return $false }
        $this.Counts[$Address] = $count + 1
        $this.Last[$Address] = $now
        $true
    }
    $l | Add-Member ScriptMethod TakeRefused { $n = $this.Refused; $this.Refused = 0; $n }
    $l
}

Export-ModuleMember -Function New-MaintenanceState, Save-Maintenance, Import-Maintenance, ConvertFrom-MaintenanceBody,
    Test-MaintenanceRequest, New-RateLimiter
