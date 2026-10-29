# Shared helpers for SRRVRR's Pester tests. Imported by every test file:
#   BeforeAll { Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force }
# Functions are added by the task that first needs them (see docs/plans/2026-10-29-srrvrr-core-test-plan.md, 4.1).

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoRoot {
    $script:RepoRoot
}

# A fresh folder under %TEMP%\srrvrr-tests for one test; Remove-TestDataPath deletes only folders under it.
function New-TestDataPath {
    $root = Join-Path $env:TEMP 'srrvrr-tests'
    $path = Join-Path $root ([guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path (Join-Path $path 'state') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $path 'logs') | Out-Null
    $path
}

function Remove-TestDataPath([string]$Path) {
    $root = Join-Path $env:TEMP 'srrvrr-tests'
    if ($Path -and $Path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

# The parsed syntax tree of a script, without running it.
function Get-ScriptAst([string]$Path) {
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
    if ($errors) { throw "Parse errors in ${Path}: $($errors[0].Message)" }
    $ast
}

# Runs a script file in a new Windows PowerShell 5.1 process. Returns @{ ExitCode; Output }.
function Invoke-InChildPowerShell {
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [int]$TimeoutSeconds = 120)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = Join-Path $env:TEMP ("srrvrr-child-" + [guid]::NewGuid().ToString('n') + '.txt')
    $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $File + '" ' + ($quoted -join ' ')
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -NoNewWindow -PassThru -RedirectStandardOutput $out
    $null = $p.Handle   # caches the handle, or ExitCode reads as $null after WaitForExit(timeout)
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { $p.Kill(); throw "Timed out: $File" }
    $text = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' }
    Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
    @{ ExitCode = $p.ExitCode; Output = $text }
}

# A free TCP port on this machine (never 8091 or 8099, which SRRVRR copies use).
function Get-FreePort {
    do {
        $l = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
        $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
    } while ($port -in 8091, 8099)
    $port
}

# The production router (modules\Web.psm1) behind a real HttpListener, in a background runspace.
# Scriptblocks in -Context are re-created inside that runspace, since a scriptblock runs on the runspace that made
# it and the test's runspace is busy waiting for the response. LogError appends to $Context.Errors.
function Start-TestServer {
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$AllAddresses)
    $port = Get-FreePort
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add($(if ($AllAddresses) { "http://+:$port/" } else { "http://localhost:$port/" }))
    $listener.Start()
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule(@(Join-Path $script:RepoRoot 'modules\Web.psm1'))
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($listener, $Context)
        $Context.Clock = [scriptblock]::Create($Context.Clock.ToString())
        $Context.LogError = { param($m) $Context.Errors.Add($m) }
        while ($listener.IsListening) {
            try { $ctx = $listener.GetContext() } catch { break }
            if ($null -ne $Context.Requests) { $Context.Requests.Add("$($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath)") }
            Invoke-SrrRequest -ListenerContext $ctx -Context $Context   # the same code SRRVRR.ps1's loop runs
        }
    }).AddArgument($listener).AddArgument($Context)
    $handle = $ps.BeginInvoke()
    @{ Port = $port; Listener = $listener; PowerShell = $ps; Runspace = $rs; Handle = $handle }
}

function Stop-TestServer($Server) {
    if (-not $Server) { return }
    try { $Server.Listener.Stop(); $Server.Listener.Close() } catch { $null = $_ }
    try { $Server.PowerShell.Stop(); $Server.PowerShell.Dispose(); $Server.Runspace.Close() } catch { $null = $_ }
}

# An HTTP request that never throws on 4xx/5xx. Returns @{ Status; Headers; Body; Bytes }.
function Invoke-TestRequest {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Url, [hashtable]$Headers = @{}, [string]$Body)
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = 15000
    foreach ($k in $Headers.Keys) {
        switch ($k) {
            'Host' { $req.Host = $Headers[$k] }
            'Content-Type' { $req.ContentType = $Headers[$k] }
            default { $req.Headers[$k] = $Headers[$k] }
        }
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if (-not $resp) { throw } }
    try {
        $ms = New-Object IO.MemoryStream
        $stream = $resp.GetResponseStream(); if ($stream) { $stream.CopyTo($ms); $stream.Close() }
        $data = $ms.ToArray()
        $h = @{}; foreach ($k in $resp.Headers.AllKeys) { $h[$k] = $resp.Headers[$k] }
        @{ Status = [int]$resp.StatusCode; Headers = $h; Body = [Text.Encoding]::UTF8.GetString($data); Bytes = $data.Length }
    } finally { $resp.Close() }
}

# Every key path in a parsed JSON value ("services[].cpu"), as tests\fixtures\stats\v0.6.0-shape.json lists them.
function Get-JsonPaths($Value, [string]$Prefix = '') {
    if ($null -eq $Value) { return }
    if ($Value -is [array]) { foreach ($e in $Value) { Get-JsonPaths $e "$Prefix[]" }; return }
    if ($Value -is [pscustomobject]) {
        foreach ($p in $Value.PSObject.Properties) {
            $k = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            $k
            Get-JsonPaths $p.Value $k
        }
    }
}

# A state hashtable with a placeholder value at every key path, for shape checks.
function New-StateFromPaths([string[]]$Paths) {
    $root = @{}
    foreach ($path in ($Paths | Sort-Object)) {
        $node = $root
        $parts = $path -split '\.'
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $name = $parts[$i]; $isArray = $name.EndsWith('[]'); $name = $name.TrimEnd('[', ']')
            $last = $i -eq $parts.Count - 1
            if (-not $node.ContainsKey($name)) { $node[$name] = if ($isArray) { ,@(@{}) } elseif ($last) { 1 } else { @{} } }
            elseif ($node[$name] -isnot [hashtable] -and $node[$name] -isnot [array] -and -not $last) { $node[$name] = if ($isArray) { ,@(@{}) } else { @{} } }
            $node = if ($isArray) { $node[$name][0] } else { $node[$name] }
            if ($last -and $isArray) { $node['x'] = $null }
        }
    }
    $root
}

Export-ModuleMember -Function Get-RepoRoot, New-TestDataPath, Remove-TestDataPath, Get-ScriptAst, Invoke-InChildPowerShell,
    Get-FreePort, Start-TestServer, Stop-TestServer, Invoke-TestRequest, Get-JsonPaths, New-StateFromPaths
