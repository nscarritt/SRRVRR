# Request handling as plain functions. The listener loop in SRRVRR.ps1 turns each request into a hashtable
# (ConvertTo-SrrRequest), calls Invoke-SrrRoute, and writes the result back (Send-SrrResponse); nothing else here
# touches HttpListener objects.
#
# Context (a hashtable): State (the shared state), WebRoot (the web\ folder), Identity (@{ Names; Addresses } of this
# machine), BootTime ([DateTimeOffset]), Clock (scriptblock returning [DateTimeOffset]), LogError (scriptblock taking
# one message).

# The only files ever served, by URL path. File paths are never built from more of the URL than a checked name.
$script:StaticTable = @{
    '/'          = @{ File = 'index.html'; ContentType = 'text/html; charset=utf-8' }
    '/app.js'    = @{ File = 'app.js'; ContentType = 'application/javascript' }
    '/style.css' = @{ File = 'style.css'; ContentType = 'text/css' }
}
$script:ImageTypes = @{ svg = 'image/svg+xml'; png = 'image/png' }

function Get-StaticRoute([string]$UrlPath) {
    if ($script:StaticTable.ContainsKey($UrlPath)) { return $script:StaticTable[$UrlPath] }
    if ($UrlPath -cmatch '^/img/([a-z0-9-]+)\.(svg|png)$' -and $UrlPath.Length -le 128) {
        return @{ File = "img\$($matches[1]).$($matches[2])"; ContentType = $script:ImageTypes[$matches[2]] }
    }
    $null
}

# The Host header must name this machine (its names or addresses, or localhost) with the port SRRVRR listens on.
# That stops a website a LAN user visits from reaching SRRVRR through DNS rebinding.
function Test-HostAllowed {
    param([string]$HostHeader, [int]$Port, [hashtable]$Identity)
    if (-not $HostHeader) { return $false }
    if ($HostHeader -match '^\[(?<h>[^\]]+)\](:(?<p>\d+))?$' -or $HostHeader -match '^(?<h>[^:\[\]]+)(:(?<p>\d+))?$') {
        $name = $matches['h']
        $p = 0
        if ($matches['p']) { if (-not [int]::TryParse($matches['p'], [ref]$p)) { return $false } }
        elseif ($Port -eq 80) { $p = 80 }   # browsers leave out :80
    } else { return $false }
    if ($p -ne $Port -or $name.EndsWith('.')) { return $false }
    $name = ($name -replace '%.*$', '')   # IPv6 zone id
    $allowed = @('localhost', '127.0.0.1', '::1') + @($Identity.Names) + @($Identity.Addresses | ForEach-Object { $_ -replace '%.*$', '' })
    foreach ($a in $allowed) { if ($a -and [string]::Equals($a, $name, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

# This machine's names and addresses, for the Host allowlist: the computer name, its .local (mDNS) name, its full
# DNS name and the name with the network's DNS suffix, any aliases, and every address of its network adapters.
function Get-HostIdentity {
    $names = New-Object System.Collections.Generic.List[string]
    $names.Add($env:COMPUTERNAME); $names.Add("$env:COMPUTERNAME.local")
    try { $entry = [Net.Dns]::GetHostEntry(''); $names.Add($entry.HostName); foreach ($a in $entry.Aliases) { $names.Add($a) } } catch { $null = $_ }
    try { $domain = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName; if ($domain) { $names.Add("$env:COMPUTERNAME.$domain") } } catch { $null = $_ }
    $addresses = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($u in $nic.GetIPProperties().UnicastAddresses) { $addresses.Add(($u.Address.ToString() -replace '%.*$', '')) }
        }
    } catch { $null = $_ }
    @{ Names = @($names | Where-Object { $_ } | Select-Object -Unique); Addresses = @($addresses | Select-Object -Unique) }
}

# The /stats document: a copy of the shared state, plus uptime.
function New-StatsSnapshot {
    param([hashtable]$State, [DateTimeOffset]$BootTime, [DateTimeOffset]$Now)
    $snapshot = @{}
    # Under the table's lock: the samplers write to it every second, and a write ends any walk of its keys.
    [Threading.Monitor]::Enter($State.SyncRoot)
    try { foreach ($k in @($State.Keys)) { $snapshot[$k] = $State[$k] } } finally { [Threading.Monitor]::Exit($State.SyncRoot) }
    $snapshot.uptime = [int]($Now - $BootTime).TotalSeconds
    $snapshot
}

# The events a page hasn't seen: those after the id Since, oldest first, at most Limit (the oldest Limit after it,
# Truncated). An id the store doesn't hold (older than the store, in the future, or not a number) gets the newest
# Limit. Returns @{ Events; Truncated }. Reads the published array once, so a drain can't change it underneath.
function Get-EventsSince {
    param([object]$Store, [long]$Since, [int]$Limit = 50, [switch]$Unknown)
    $all = $Store.Published
    $at = -1
    if (-not $Unknown) { for ($i = $all.Count - 1; $i -ge 0; $i--) { if ($all[$i].id -eq $Since) { $at = $i; break } } }
    if ($at -lt 0) {
        $skip = [Math]::Max(0, $all.Count - $Limit)
        return @{ Events = [object[]]@($all | Select-Object -Skip $skip); Truncated = $all.Count -gt $Limit }
    }
    $newer = $all.Count - $at - 1
    @{ Events = [object[]]@($all | Select-Object -Skip ($at + 1) -First $Limit); Truncated = $newer -gt $Limit }
}

# Adds the events, Maintenance and the log retention to the /stats document. A page's first request has no since
# and gets no events (no replay): it starts counting from lastEventId.
function Add-EventFields {
    param([hashtable]$Doc, [hashtable]$Query, [hashtable]$Context)
    $store = $Context['Events']
    if (-not $store) { return }
    $published = $store.Published
    $Doc.lastEventId = if ($published.Count) { $published[$published.Count - 1].id } else { $store.LastId }
    $Doc.events = @()
    if ($Query -and $Query.ContainsKey('since')) {
        $since = 0L
        $known = [long]::TryParse([string]$Query['since'], [ref]$since)
        $r = Get-EventsSince -Store $store -Since $since -Unknown:(-not $known)
        $Doc.events = $r.Events
        if ($r.Truncated) { $Doc.eventsTruncated = $true }
    }
    $m = $Context['Maintenance']
    $Doc.maintenance = @{ on = [bool]($m -and $m.IsOn()); untilMs = if ($m) { [long]$m.UntilMs } else { 0L } }
    if ($Context['LogRetentionDays']) { $Doc.logRetentionDays = [int]$Context['LogRetentionDays'] }
}

# /events?days=n: the logged events of the last n days, newest first, from memory (Context.ReadEvents). n must be a
# whole number from 1 to LogRetentionDays; anything else, including no n, is 400.
function Get-EventsResult {
    param([hashtable]$Query, [hashtable]$Context)
    $days = 0
    $text = if ($Query) { [string]$Query['days'] } else { '' }
    $max = [int]$Context['LogRetentionDays']
    if ($text -notmatch '^\d{1,4}$' -or -not [int]::TryParse($text, [ref]$days) -or $days -lt 1 -or $days -gt $max) {
        return New-Result 400 'text/plain; charset=utf-8' "days must be a whole number from 1 to $max"
    }
    $events = @(& $Context['ReadEvents'] $days | ForEach-Object { $_ })   # flat whether the list came back whole or unrolled
    New-Result 200 'application/json; charset=utf-8' (ConvertTo-Json -InputObject @{ events = $events } -Compress -Depth 6)
}

function Read-StaticFile([string]$Path) {
    , [IO.File]::ReadAllBytes($Path)   # the comma keeps the byte[] whole instead of unrolling it into the pipeline
}

function New-Result([int]$Status, [string]$ContentType, $Body, [hashtable]$Headers) {
    if ($null -eq $Headers) { $Headers = @{ 'X-Content-Type-Options' = 'nosniff'; 'Cache-Control' = 'no-store' } }
    @{ Status = $Status; ContentType = $ContentType; Body = $Body; Headers = $Headers }
}

# Returns @{ Status; ContentType; Body ([string] or [byte[]]); Headers }.
function Invoke-SrrRoute {
    param(
        [string]$Method, [string]$Path, [hashtable]$Query, [hashtable]$Headers, [string]$Body,
        [string]$RemoteAddress, [int]$LocalPort, [hashtable]$Context
    )
    try {
        if (-not (Test-HostAllowed -HostHeader $Headers['Host'] -Port $LocalPort -Identity $Context.Identity)) {
            return New-Result 421 $null '' @{}
        }
        # Maintenance is the one thing that takes a POST, and it takes nothing else (Context.HandleMaintenance).
        if ($Path -eq '/maintenance') {
            if ($Method -ne 'POST') { return New-Result 405 'text/plain; charset=utf-8' 'Method not allowed' }
            if (-not $Context['HandleMaintenance']) { return New-Result 404 'text/plain; charset=utf-8' 'Not found' }
            $r = & $Context['HandleMaintenance'] $Headers $Body $RemoteAddress
            return New-Result $r.Status 'application/json; charset=utf-8' (ConvertTo-Json -InputObject $r.Body -Compress)
        }
        if ($Method -ne 'GET') { return New-Result 405 'text/plain; charset=utf-8' 'Method not allowed' }
        if ($Path -eq '/stats') {
            $doc = New-StatsSnapshot -State $Context.State -BootTime $Context.BootTime -Now (& $Context.Clock)
            Add-EventFields -Doc $doc -Query $Query -Context $Context
            return New-Result 200 'application/json; charset=utf-8' ($doc | ConvertTo-Json -Compress -Depth 6)
        }
        if ($Path -eq '/events' -and $Context['ReadEvents']) { return Get-EventsResult -Query $Query -Context $Context }
        # 15 minutes of graph history: a copy taken under the store's lock, then written to JSON (modules\History.psm1).
        if ($Path -eq '/history' -and $Context.History) {
            return New-Result 200 'application/json; charset=utf-8' ([SrrHistoryStore]::ToJson($Context.History.Copy()))
        }
        $route = Get-StaticRoute $Path
        if (-not $route) { return New-Result 404 'text/plain; charset=utf-8' 'Not found' }
        $file = Join-Path $Context.WebRoot $route.File
        try { $bytes = Read-StaticFile $file }
        catch {
            Write-RouteError $Context "Couldn't read the page file web\$($route.File): $($_.Exception.Message)"
            return New-Result 500 'text/plain; charset=utf-8' "SRRVRR couldn't read web\$($route.File). See the error log."
        }
        New-Result 200 $route.ContentType $bytes
    } catch {
        Write-RouteError $Context "Error answering $Method ${Path}: $($_.Exception.Message)"
        New-Result 500 'text/plain; charset=utf-8' 'SRRVRR had an error answering this request. See the error log.'
    }
}

function Write-RouteError([hashtable]$Context, [string]$Message) {
    try { & $Context.LogError $Message } catch { $null = $_ }   # the log must never take the server down
}

# One request from start to finish: the listener loop in SRRVRR.ps1 and the tests' server both call this.
# Anything that still goes wrong drops just this connection.
function Invoke-SrrRequest($ListenerContext, [hashtable]$Context) {
    try {
        $request = ConvertTo-SrrRequest -ListenerContext $ListenerContext
        # POST /maintenance is the only request with a body. It's read only once the Host check has passed and the
        # X-SRRVRR header is there (the full guard runs after), and only within one short deadline: the listener has
        # one thread, so a body trickled in slowly must not hold up every other request.
        if ($request.Method -eq 'POST' -and $request.Path -eq '/maintenance' -and
            (Test-HostAllowed -HostHeader $request.Headers['Host'] -Port $request.LocalPort -Identity $Context.Identity)) {
            if ($request.Headers['X-SRRVRR'] -cne '1') {
                Send-SrrResponse -ListenerContext $ListenerContext -Result (New-Result 403 'application/json; charset=utf-8' '{"error":"refused"}'); return
            }
            $read = Read-RequestBody -Request $ListenerContext.Request
            if ($read.Status -eq 408) { $ListenerContext.Response.Abort(); return }
            if (-not $read.Ok) { Send-SrrResponse -ListenerContext $ListenerContext -Result (New-Result $read.Status 'text/plain; charset=utf-8' $read.Error); return }
            $request.Body = $read.Body
        }
        Send-SrrResponse -ListenerContext $ListenerContext -Result (Invoke-SrrRoute @request -Context $Context)
    } catch {
        try { $ListenerContext.Response.Abort() } catch { $null = $_ }   # usually the browser went away mid-response
    }
}

# The parts of an HttpListener request the router needs, as plain values.
function ConvertTo-SrrRequest($ListenerContext) {
    $r = $ListenerContext.Request
    $headers = @{}
    foreach ($k in $r.Headers.AllKeys) { $headers[$k] = $r.Headers[$k] }
    $query = @{}
    foreach ($k in $r.QueryString.AllKeys) { if ($k) { $query[$k] = $r.QueryString[$k] } }
    # The body is never read here: the listener has one thread, and a slow or endless body would hold up every
    # other request. A route that needs a body (POST /maintenance, #50) reads it itself, after the Host check.
    @{
        Method = $r.HttpMethod; Path = $r.Url.AbsolutePath; Query = $query; Headers = $headers; Body = ''
        RemoteAddress = [string]$r.RemoteEndPoint.Address; LocalPort = $r.LocalEndPoint.Port
    }
}

# A request's body as text: at most MaxBytes, with a stated length, all of it within DeadlineMs. Returns @{ Ok; Body;
# Status; Error }: 411 with no length, 413 when too long, 408 when the deadline passed (the caller drops the
# connection).
function Read-RequestBody($Request, [int]$MaxBytes = 1024, [int]$DeadlineMs = 2000) {
    if (-not $Request.HasEntityBody) { return @{ Ok = $true; Body = '' } }
    $length = $Request.ContentLength64
    if ($length -lt 0) { return @{ Ok = $false; Status = 411; Error = 'A Content-Length is required' } }
    if ($length -gt $MaxBytes) { return @{ Ok = $false; Status = 413; Error = 'Request body too large' } }
    $buffer = New-Object byte[] $length
    $total = 0
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($total -lt $length) {
        $left = $DeadlineMs - [int]$clock.ElapsedMilliseconds
        $pending = $Request.InputStream.BeginRead($buffer, $total, $length - $total, $null, $null)
        if ($left -le 0 -or -not $pending.AsyncWaitHandle.WaitOne($left)) { return @{ Ok = $false; Status = 408; Error = 'Request body too slow' } }
        $n = $Request.InputStream.EndRead($pending)
        if ($n -le 0) { break }
        $total += $n
    }
    @{ Ok = $true; Body = [Text.Encoding]::UTF8.GetString($buffer, 0, $total) }
}

function Send-SrrResponse($ListenerContext, [hashtable]$Result) {
    $resp = $ListenerContext.Response
    $resp.StatusCode = $Result.Status
    if ($Result.ContentType) { $resp.ContentType = $Result.ContentType }
    foreach ($k in $Result.Headers.Keys) { $resp.Headers[$k] = $Result.Headers[$k] }
    $bytes = if ($Result.Body -is [byte[]]) { $Result.Body } else { [Text.Encoding]::UTF8.GetBytes([string]$Result.Body) }
    $resp.ContentLength64 = $bytes.Length
    # A HEAD response must not carry a body: HttpListener drops the connection if one is written.
    if ($bytes.Length -and $ListenerContext.Request.HttpMethod -ne 'HEAD') { $resp.OutputStream.Write($bytes, 0, $bytes.Length) }
    $resp.Close()
}

Export-ModuleMember -Function Get-StaticRoute, Test-HostAllowed, Get-HostIdentity, New-StatsSnapshot, Get-EventsSince, Read-StaticFile,
    Invoke-SrrRoute, Invoke-SrrRequest, ConvertTo-SrrRequest, Send-SrrResponse
