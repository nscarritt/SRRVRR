# A fake ComfyUI for the AI server tests (test plan section 6.13, asset FCU; v0.10.0 plan, Task 10). A TcpListener on
# 127.0.0.1, port 0, in its own runspace, writing raw HTTP/1.1 replies from tests\fixtures\workstation, so a test sees
# exactly what a reader sent (an HttpListener would apply its own address and Host rules first). It listens only on
# the loopback address and never forwards anything.
#
#   $fake = Start-FakeComfyUi -Mode answer -Queue 0
#   Read-LocalHttp -Port $fake.Port -Path '/prompt'
#   & $fake.SetQueue 2          # what GET /prompt reports from now on
#   @($fake.Requests)           # one record per request: @{ Line; Host; ContentLength; TransferEncoding; BodyBytes; Headers }
#   & $fake.Stop                # closes the listener and the runspace; safe to call twice
#
# Modes (every path, unless said):
#   answer     200: /system_stats is system_stats.json, /prompt is prompt.json with the queue set; any other path 404
#   slow       as answer, after waiting DelayMs (default 3000) without sending a byte
#   junk       200 with an HTML page, not JSON
#   huge       200 with a JSON body of exactly Bytes bytes (default 262145, one over the reader's cap), no
#              Content-Length, so a reader has to count what it reads
#   trickle    200 with the headers at once and no Content-Length, then one byte every 100 ms for DelayMs (default
#              3000), so a reader's per-Read timeout never fires but its whole-request deadline should
#   status500  500 with a small JSON body
#   redirect   302 to /history on this same fake, so a reader that followed it would show a second request

function Start-FakeComfyUi {
    param(
        [ValidateSet('answer', 'slow', 'trickle', 'junk', 'huge', 'status500', 'redirect')][string]$Mode = 'answer',
        [int]$Queue = 0,
        [int]$DelayMs = 3000,
        [ValidateRange(10, 16777216)][int]$Bytes = 262145
    )
    $fixtures = Join-Path (Split-Path -Parent $PSScriptRoot) 'fixtures\workstation'
    $stats = [IO.File]::ReadAllText((Join-Path $fixtures 'system_stats.json'))
    $prompt = [IO.File]::ReadAllText((Join-Path $fixtures 'prompt.json'))

    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $shared = [hashtable]::Synchronized(@{
        Queue    = $Queue
        Stopping = $false
        Stopped  = $false
        Requests = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
        Errors   = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    })

    $serve = {
        param($Listener, $Shared, $Mode, $DelayMs, $Bytes, $Stats, $Prompt, $Port)
        $ascii = [Text.Encoding]::ASCII
        $utf8 = New-Object Text.UTF8Encoding($false)
        while (-not $Shared.Stopping) {
            try { $client = $Listener.AcceptTcpClient() } catch { break }   # Stop() ends the wait with an exception
            try {
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 5000
                $stream = $client.GetStream()
                # The request head: everything up to the first blank line (at most 64 KB).
                $buffer = New-Object byte[] 8192
                $got = New-Object IO.MemoryStream
                $text = ''
                $end = -1
                while ($end -lt 0 -and $got.Length -lt 65536) {
                    $n = $stream.Read($buffer, 0, $buffer.Length)
                    if ($n -le 0) { break }
                    $got.Write($buffer, 0, $n)
                    $text = $ascii.GetString($got.ToArray())
                    $end = $text.IndexOf("`r`n`r`n")
                }
                if ($end -lt 0) { [void]$Shared.Errors.Add('no complete request head'); continue }
                $lines = @($text.Substring(0, $end) -split "`r`n")
                $headerLines = @($lines | Select-Object -Skip 1)
                $headers = @{}
                foreach ($h in $headerLines) {
                    $i = $h.IndexOf(':')
                    if ($i -gt 0) { $headers[$h.Substring(0, $i).Trim().ToLowerInvariant()] = $h.Substring($i + 1).Trim() }
                }
                [void]$Shared.Requests.Add(@{
                    Line             = $lines[0]
                    Host             = $headers['host']
                    ContentLength    = $headers['content-length']
                    TransferEncoding = $headers['transfer-encoding']
                    BodyBytes        = [int]($got.Length - ($end + 4))
                    Headers          = $headerLines
                })
                $parts = @($lines[0] -split ' ') + @('', '')
                $path = ([string]$parts[1] -split '\?')[0]

                $status = '200 OK'
                $type = 'application/json; charset=utf-8'
                $body = ''
                $withLength = $true
                $extra = @()
                switch ($Mode) {
                    'junk' { $type = 'text/html; charset=utf-8'; $body = '<html><body>This is not ComfyUI.</body></html>' }
                    'trickle' { $withLength = $false }
                    'huge' { $body = '{"pad":"' + ('x' * ($Bytes - 10)) + '"}'; $withLength = $false }
                    'status500' { $status = '500 Internal Server Error'; $body = '{"error":"fake failure"}' }
                    'redirect' { $status = '302 Found'; $extra = @("Location: http://127.0.0.1:$Port/history") }
                    default {
                        if ($Mode -eq 'slow') { Start-Sleep -Milliseconds $DelayMs }
                        if ($path -eq '/system_stats') { $body = $Stats }
                        elseif ($path -eq '/prompt') { $body = $Prompt -replace '("queue_remaining"\s*:\s*)-?\d+', ('${1}' + [int]$Shared.Queue) }
                        else { $status = '404 Not Found'; $body = '{"error":"not found"}' }
                    }
                }
                $bodyBytes = $utf8.GetBytes($body)
                $head = @("HTTP/1.1 $status", "Content-Type: $type", 'Connection: close') + $extra
                if ($withLength) { $head += "Content-Length: $($bodyBytes.Length)" }
                $headBytes = $ascii.GetBytes(($head -join "`r`n") + "`r`n`r`n")
                $stream.Write($headBytes, 0, $headBytes.Length)
                if ($Mode -eq 'trickle') {
                    $stream.Flush()
                    $until = [DateTime]::UtcNow.AddMilliseconds($DelayMs)
                    while ([DateTime]::UtcNow -lt $until -and -not $Shared.Stopping) { $stream.WriteByte(32); $stream.Flush(); Start-Sleep -Milliseconds 100 }
                    continue
                }
                if ($bodyBytes.Length) { $stream.Write($bodyBytes, 0, $bodyBytes.Length) }
                $stream.Flush()
            } catch {
                # A reader that gave up (a timeout, the size cap) closes its end while this writes: expected.
                [void]$Shared.Errors.Add($_.Exception.Message)
            } finally {
                try { $client.Close() } catch { $null = $_ }
            }
        }
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($serve).AddArgument($listener).AddArgument($shared).AddArgument($Mode).AddArgument($DelayMs).
        AddArgument($Bytes).AddArgument($stats).AddArgument($prompt).AddArgument($port)
    $handle = $ps.BeginInvoke()

    $setQueue = { param([int]$n) $shared.Queue = $n }.GetNewClosure()
    $stop = {
        if ($shared.Stopped) { return }
        $shared.Stopped = $true
        $shared.Stopping = $true
        try { $listener.Stop() } catch { $null = $_ }
        # A slow reply in progress finishes its wait first; Stop() interrupts it if it takes too long.
        if (-not $handle.AsyncWaitHandle.WaitOne(10000)) { try { $ps.Stop() } catch { $null = $_ } }
        try { $ps.Dispose() } catch { $null = $_ }
        try { $runspace.Close(); $runspace.Dispose() } catch { $null = $_ }
    }.GetNewClosure()

    @{ Port = $port; Mode = $Mode; SetQueue = $setQueue; Requests = $shared.Requests; Errors = $shared.Errors; Stop = $stop }
}

Export-ModuleMember -Function Start-FakeComfyUi
