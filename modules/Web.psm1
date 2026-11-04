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
        if ($Method -ne 'GET') { return New-Result 405 'text/plain; charset=utf-8' 'Method not allowed' }
        if ($Path -eq '/stats') {
            $doc = New-StatsSnapshot -State $Context.State -BootTime $Context.BootTime -Now (& $Context.Clock)
            return New-Result 200 'application/json; charset=utf-8' ($doc | ConvertTo-Json -Compress -Depth 6)
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

Export-ModuleMember -Function Get-StaticRoute, Test-HostAllowed, Get-HostIdentity, New-StatsSnapshot, Read-StaticFile,
    Invoke-SrrRoute, Invoke-SrrRequest, ConvertTo-SrrRequest, Send-SrrResponse
