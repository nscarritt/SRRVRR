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
    if ($HostHeader -match '^\[(?<h>[^\]]+)\]:(?<p>\d+)$' -or $HostHeader -match '^(?<h>[^:\[\]]+):(?<p>\d+)$') {
        $name = $matches['h']; $p = [int]$matches['p']
    } else { return $false }
    if ($p -ne $Port -or $name.EndsWith('.')) { return $false }
    $name = ($name -replace '%.*$', '')   # IPv6 zone id
    $allowed = @('localhost', '127.0.0.1', '::1') + @($Identity.Names) + @($Identity.Addresses | ForEach-Object { $_ -replace '%.*$', '' })
    foreach ($a in $allowed) { if ($a -and [string]::Equals($a, $name, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    $false
}

# The /stats document: a copy of the shared state, plus uptime.
function New-StatsSnapshot {
    param([hashtable]$State, [DateTimeOffset]$BootTime, [DateTimeOffset]$Now)
    $snapshot = @{}
    foreach ($k in @($State.Keys)) { $snapshot[$k] = $State[$k] }
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
        & $Context.LogError "Couldn't read the page file web\$($route.File): $($_.Exception.Message)"
        return New-Result 500 'text/plain; charset=utf-8' "SRRVRR couldn't read web\$($route.File). See the error log."
    }
    New-Result 200 $route.ContentType $bytes
}

# The parts of an HttpListener request the router needs, as plain values.
function ConvertTo-SrrRequest($ListenerContext) {
    $r = $ListenerContext.Request
    $headers = @{}
    foreach ($k in $r.Headers.AllKeys) { $headers[$k] = $r.Headers[$k] }
    $query = @{}
    foreach ($k in $r.QueryString.AllKeys) { if ($k) { $query[$k] = $r.QueryString[$k] } }
    $body = ''
    if ($r.HasEntityBody -and $r.ContentLength64 -le 65536) {
        $reader = New-Object IO.StreamReader $r.InputStream, ([Text.Encoding]::UTF8)
        try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    @{
        Method = $r.HttpMethod; Path = $r.Url.AbsolutePath; Query = $query; Headers = $headers; Body = $body
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

Export-ModuleMember -Function Get-StaticRoute, Test-HostAllowed, New-StatsSnapshot, Read-StaticFile, Invoke-SrrRoute,
    ConvertTo-SrrRequest, Send-SrrResponse
