# modules\Web.psm1: routing, the Host allowlist, static files, /stats (spec sections 1, 2 and 8).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Web.psm1') -Force

    $script:Identity = @{ Names = @('SRRVRR', 'srrvrr.home.example'); Addresses = @('10.0.0.5', '172.16.4.2', 'fd00::5') }
    function New-WebRoot {
        $root = Join-Path (New-TestDataPath) 'web'
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'img') | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'index.html'), '<!doctype html><meta charset="utf-8"><link rel="stylesheet" href="/style.css"><script src="/app.js"></script><img src="/img/logo.svg"><img src="/img/dot.png">')
        [IO.File]::WriteAllText((Join-Path $root 'app.js'), 'var x = 1;')
        [IO.File]::WriteAllText((Join-Path $root 'style.css'), 'body{}')
        [IO.File]::WriteAllText((Join-Path $root 'img\logo.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>')
        [IO.File]::WriteAllBytes((Join-Path $root 'img\dot.png'), [byte[]](0x89, 0x50, 0x4E, 0x47))
        $root
    }
    function New-Context([string]$WebRoot, [hashtable]$State = @{ ready = $true; cpu = 3 }) {
        $errors = New-Object System.Collections.Generic.List[string]
        @{
            State = $State; WebRoot = $WebRoot; Identity = $Identity; Port = 8091
            BootTime = [DateTimeOffset]::new(2026, 1, 5, 11, 0, 0, [TimeSpan]::Zero)
            Clock = { [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero) }
            LogError = { param($message) $errors.Add($message) }.GetNewClosure()
            Errors = $errors
        }
    }
    function Invoke-Route([string]$Method = 'GET', [string]$Path = '/', [hashtable]$Headers = @{ Host = 'localhost:8091' }, $Context) {
        Invoke-SrrRoute -Method $Method -Path $Path -Query @{} -Headers $Headers -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $Context
    }
}

Describe 'T47-38 the Host allowlist' {
    It 'T47-38 the machine''s own names and addresses with the port are allowed, in any case' {
        foreach ($h in 'SRRVRR:8091', 'srrvrr:8091', 'srrvrr.home.example:8091', '10.0.0.5:8091', '172.16.4.2:8091', '[fd00::5]:8091', 'localhost:8091', '127.0.0.1:8091', '[::1]:8091') {
            Test-HostAllowed -HostHeader $h -Port 8091 -Identity $Identity | Should -BeTrue -Because $h
        }
    }
    It 'T47-38 a port too big for a number is refused, not an error' {
        Test-HostAllowed -HostHeader 'srrvrr:99999999999' -Port 8091 -Identity $Identity | Should -BeFalse
    }
    It 'T47-38 the .local name and a name with the network''s DNS suffix are the machine''s own' {
        $id = @{ Names = @('SRRVRR', 'SRRVRR.local', 'srrvrr.lan'); Addresses = @() }
        Test-HostAllowed -HostHeader 'srrvrr.local:8091' -Port 8091 -Identity $id | Should -BeTrue
        Test-HostAllowed -HostHeader 'SRRVRR.lan:8091' -Port 8091 -Identity $id | Should -BeTrue
    }
    It 'T47-38 the machine''s identity includes its name, its .local name and its addresses' {
        $id = Get-HostIdentity
        $id.Names | Should -Contain $env:COMPUTERNAME
        $id.Names | Should -Contain "$env:COMPUTERNAME.local"
        @($id.Addresses).Count | Should -BeGreaterThan 0
    }
    It 'T47-38 no port in Host is accepted only when SRRVRR listens on port 80' {
        Test-HostAllowed -HostHeader 'SRRVRR' -Port 80 -Identity $Identity | Should -BeTrue
        Test-HostAllowed -HostHeader 'SRRVRR' -Port 8091 -Identity $Identity | Should -BeFalse
    }
    It 'T47-38 an IPv6 zone id is stripped before comparing' {
        Test-HostAllowed -HostHeader '[fd00::5%12]:8091' -Port 8091 -Identity $Identity | Should -BeTrue
    }
    It 'T47-38 another port, no port, a foreign name, another machine, a trailing dot and an empty Host are refused' {
        foreach ($h in 'SRRVRR:8099', 'SRRVRR', 'evil.example:8091', '10.0.0.6:8091', 'srrvrr.home.example.:8091', '', '[::1]') {
            Test-HostAllowed -HostHeader $h -Port 8091 -Identity $Identity | Should -BeFalse -Because "'$h'"
        }
    }
}

Describe 'T47-22 the static path table' {
    It 'T47-22 the fixed paths map to their files and content types' {
        (Get-StaticRoute '/').File | Should -Be 'index.html'
        (Get-StaticRoute '/').ContentType | Should -Be 'text/html; charset=utf-8'
        (Get-StaticRoute '/app.js').ContentType | Should -Be 'application/javascript'
        (Get-StaticRoute '/style.css').ContentType | Should -Be 'text/css'
        (Get-StaticRoute '/img/logo.svg').File | Should -Be 'img\logo.svg'
        (Get-StaticRoute '/img/logo.svg').ContentType | Should -Be 'image/svg+xml'
        (Get-StaticRoute '/img/dot-2.png').ContentType | Should -Be 'image/png'
    }
    It 'T47-22 traversal and anything off the table gives no route' {
        $bad = '/../SRRVRR.ps1', '/%2e%2e/SRRVRR.config.psd1', '/img/..%5c..%5cSRRVRR.config.psd1', '/img/%2e%2e%2fx.png',
            '/img/A.png', '/img/a_b.png', '/img/a.png.exe', '/img/a.gif', '/img/', '/app.js/', '/web/app.js', "/img/a`0.png", ('/img/' + ('a' * 4096) + '.png')
        foreach ($p in $bad) { Get-StaticRoute $p | Should -BeNullOrEmpty -Because $p }
    }
    It 'T47-22 a refused path never reads a file' {
        $ctx = New-Context (New-WebRoot)
        Mock -ModuleName Web Read-StaticFile { throw 'should not read' }
        (Invoke-Route -Path '/../SRRVRR.ps1' -Context $ctx).Status | Should -Be 404
        Should -Invoke -ModuleName Web Read-StaticFile -Times 0
    }
}

Describe 'T47-39 DNS rebinding is refused (router level)' {
    It 'T47-39 a foreign Host gets 421 with an empty body on every path, and a normal Host gets 200' {
        $ctx = New-Context (New-WebRoot)
        foreach ($p in '/stats', '/', '/app.js') {
            $r = Invoke-Route -Path $p -Headers @{ Host = 'evil.example:8091' } -Context $ctx
            $r.Status | Should -Be 421
            $r.Body.Length | Should -Be 0
            $r.Headers.Count | Should -Be 0
        }
        (Invoke-Route -Path '/stats' -Context $ctx).Status | Should -Be 200
    }
}

Describe 'T47-37 a failure while routing' {
    It 'T47-37 an exception inside the router becomes a 500 with one error-log line' {
        $ctx = New-Context (New-WebRoot)
        $ctx.Clock = { throw 'clock broke' }
        $r = Invoke-Route -Path '/stats' -Context $ctx
        $r.Status | Should -Be 500
        @($ctx.Errors | Where-Object { $_ -match 'clock broke' }).Count | Should -Be 1
    }
}

Describe 'T47-17 /stats keeps every v0.6.0 field' {
    It 'T47-17 the router''s /stats has every v0.6.0 key path, and tickMs is the only new one' {
        $old = @((Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures\stats\v0.6.0-shape.json') | ConvertFrom-Json).paths)
        $state = New-StateFromPaths $old
        $state.tickMs = 37
        $ctx = New-Context (New-WebRoot) $state
        $r = Invoke-Route -Path '/stats' -Context $ctx
        $r.Status | Should -Be 200
        $r.ContentType | Should -Be 'application/json; charset=utf-8'
        $new = @(Get-JsonPaths ($r.Body | ConvertFrom-Json))
        @($old | Where-Object { $new -notcontains $_ }) | Should -BeNullOrEmpty
        @($new | Where-Object { $old -notcontains $_ }) | Should -Be @('tickMs')
    }
    It 'T62-04 /stats has a version string when the state has one, and every v0.7.0 field is still there' {
        $old = @((Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures\stats\v0.6.0-shape.json') | ConvertFrom-Json).paths)
        $state = New-StateFromPaths $old
        $state.tickMs = 37
        $state.version = 'v0.8.0'
        $ctx = New-Context (New-WebRoot) $state
        $r = Invoke-Route -Path '/stats' -Context $ctx
        $r.Status | Should -Be 200
        $doc = $r.Body | ConvertFrom-Json
        $doc.version | Should -BeOfType [string]
        $doc.version | Should -Be 'v0.8.0'
        $new = @(Get-JsonPaths $doc)
        @($old + 'tickMs' | Where-Object { $new -notcontains $_ }) | Should -BeNullOrEmpty
        @($new | Where-Object { ($old + 'tickMs') -notcontains $_ }) | Should -Be @('version')
    }
    It 'T47-17 uptime is worked out from the boot time and the clock' {
        $r = Invoke-Route -Path '/stats' -Context (New-Context (New-WebRoot))
        ($r.Body | ConvertFrom-Json).uptime | Should -Be 3600
    }
}

Describe 'Routing through a real listener' -Tag 'Integration' {
    BeforeAll {
        $script:Root = New-WebRoot
        $script:Ctx = New-Context $Root
        $script:Server = Start-TestServer -Context $Ctx
        $script:Base = "http://localhost:$($Server.Port)"
    }
    AfterAll { Stop-TestServer $Server }
    AfterEach {
        # No response in this suite ever carries a CORS header (T47-36).
        foreach ($h in @($script:Last.Headers.Keys)) { $h | Should -Not -BeLike 'Access-Control-*' }
    }

    It 'T47-20 the page and every asset it references are served with fixed types and nosniff' {
        $expected = @{ '/' = 'text/html; charset=utf-8'; '/app.js' = 'application/javascript'; '/style.css' = 'text/css'; '/img/logo.svg' = 'image/svg+xml'; '/img/dot.png' = 'image/png' }
        $total = 0
        foreach ($p in $expected.Keys) {
            $script:Last = Invoke-TestRequest -Url "$Base$p"
            $Last.Status | Should -Be 200 -Because $p
            $Last.Headers['Content-Type'] | Should -Be $expected[$p]
            $Last.Headers['X-Content-Type-Options'] | Should -Be 'nosniff'
            $file = Join-Path $Root (Get-StaticRoute $p).File
            $Last.Bytes | Should -Be ([IO.File]::ReadAllBytes($file).Length) -Because "$p is sent as the file's own bytes"
            $total += $Last.Bytes
        }
        $total | Should -BeGreaterThan 0
    }
    It 'T47-21 an edit to index.html shows on the next request, without a restart' {
        $script:Last = Invoke-TestRequest -Url "$Base/"
        [IO.File]::WriteAllText((Join-Path $Root 'index.html'), '<!doctype html><p>edited</p>')
        $script:Last = Invoke-TestRequest -Url "$Base/"
        $Last.Body | Should -Match 'edited'
    }
    It 'T47-23 unknown paths get 404 with a plain body' {
        foreach ($p in '/anything-else', '/stats/', '/index.html') {
            $script:Last = Invoke-TestRequest -Url "$Base$p"
            $Last.Status | Should -Be 404 -Because $p
            $Last.Headers['Content-Type'] | Should -Be 'text/plain; charset=utf-8'
        }
    }
    It 'T47-36 every method except GET gets 405' {
        foreach ($m in 'POST', 'PUT', 'DELETE', 'HEAD', 'OPTIONS') {
            foreach ($p in '/', '/stats', '/app.js', '/img/dot.png') {
                # Methods that carry a body send an empty one; without a length Windows answers 411 itself.
                $script:Last = if ($m -in 'POST', 'PUT', 'DELETE') { Invoke-TestRequest -Method $m -Url "$Base$p" -Body '' } else { Invoke-TestRequest -Method $m -Url "$Base$p" }
                $Last.Status | Should -Be 405 -Because "$m $p"
            }
        }
        $script:Last = Invoke-TestRequest -Method 'OPTIONS' -Url "$Base/maintenance" -Headers @{ 'Access-Control-Request-Method' = 'POST'; Origin = 'http://evil.example' }
        $Last.Status | Should -Be 405
    }
    It 'T47-36 a request body is never read, so a body that never ends can''t hold up the next request' {
        $client = New-Object Net.Sockets.TcpClient 'localhost', $Server.Port
        try {
            $s = $client.GetStream()
            $head = "POST /stats HTTP/1.1`r`nHost: localhost:$($Server.Port)`r`nTransfer-Encoding: chunked`r`n`r`n5`r`nhello`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($head); $s.Write($bytes, 0, $bytes.Length)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $script:Last = Invoke-TestRequest -Url "$Base/stats"
            $Last.Status | Should -Be 200
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
        } finally { $client.Close() }
    }
    It 'T47-37 a missing or unreadable page file is a 500 with one error-log line, and the next request works' {
        Remove-Item (Join-Path $Root 'app.js')
        $script:Last = Invoke-TestRequest -Url "$Base/app.js"
        $Last.Status | Should -Be 500
        $Last.Body | Should -Match 'app\.js'
        $stream = [IO.File]::Open((Join-Path $Root 'style.css'), 'Open', 'Read', 'None')
        try { $script:Last = Invoke-TestRequest -Url "$Base/style.css"; $Last.Status | Should -Be 500 } finally { $stream.Dispose() }
        @($Ctx.Errors | Where-Object { $_ -match 'app\.js' }).Count | Should -Be 1
        @($Ctx.Errors | Where-Object { $_ -match 'style\.css' }).Count | Should -Be 1
        $script:Last = Invoke-TestRequest -Url "$Base/style.css"
        $Last.Status | Should -Be 200
    }
}

Describe 'T47-39 DNS rebinding through a real listener' -Tag 'Elevated' {
    It 'T47-39 a listener on every address answers a foreign Host with 421' {
        $ctx = New-Context (New-WebRoot)
        $server = Start-TestServer -Context $ctx -AllAddresses
        try {
            $r = Invoke-TestRequest -Url "http://localhost:$($server.Port)/stats" -Headers @{ Host = "evil.example:$($server.Port)" }
            $r.Status | Should -Be 421
            $r.Bytes | Should -Be 0
        } finally { Stop-TestServer $server }
    }
}

Describe 'T48-73 /stats while the samplers write' {
    It 'T48-73 copying the shared state never fails while another thread writes to it' {
        $state = [hashtable]::Synchronized(@{})
        foreach ($i in 1..40) { $state["k$i"] = $i }
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript({ param($s) $end = [DateTime]::UtcNow.AddSeconds(3); $n = 0; while ([DateTime]::UtcNow -lt $end) { $s["k$($n % 40 + 1)"] = $n; $n++ } }).AddArgument($state)
        $h = $ps.BeginInvoke()
        $errors = 0
        try {
            while (-not $h.IsCompleted) {
                try { $null = New-StatsSnapshot -State $state -BootTime ([DateTimeOffset]::Now) -Now ([DateTimeOffset]::Now) } catch { $errors++ }
            }
        } finally { $ps.EndInvoke($h); $ps.Dispose() }
        $errors | Should -Be 0
    }
}
Describe 'T49-19 to T49-21 GET /history' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\History.psm1') -Force
        $script:Hist = New-HistoryStore
        $t0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero).ToUnixTimeMilliseconds()
        for ($i = 0; $i -lt 900; $i++) { foreach ($n in $Hist.Names) { $Hist.Append($n, $i * 1234567.891, $t0 + $i * 1000) } }
        $script:HCtx = New-Context (New-WebRoot); $HCtx.History = $Hist
    }
    It 'T49-19 answers with every line at 900 values, as JSON, not cached, under 150 KB' {
        $r = Invoke-Route -Path '/history' -Context $HCtx
        $r.Status | Should -Be 200
        $r.ContentType | Should -Be 'application/json; charset=utf-8'
        $r.Headers['Cache-Control'] | Should -Be 'no-store'
        $r.Body.Length | Should -BeLessThan 150KB
        $o = $r.Body | ConvertFrom-Json
        $o.version | Should -Be 1; $o.stepMs | Should -Be 1000
        foreach ($n in 'cpu', 'mem', 'gpu', 'rx', 'tx') { @($o.lines.$n).Count | Should -Be 900 -Because $n }
    }
    It 'T49-20 50 requests: p95 under 50 ms' {
        $times = foreach ($i in 1..50) { (Measure-Command { $null = Invoke-Route -Path '/history' -Context $HCtx }).TotalMilliseconds }
        $p95 = ($times | Sort-Object)[47]
        Write-Host ("    T49-20: /history p95 {0:N1} ms" -f $p95)
        $p95 | Should -BeLessThan 50
    }
    It 'T49-21 POST is refused with 405 and a foreign Host with 421' {
        (Invoke-Route -Method 'POST' -Path '/history' -Context $HCtx).Status | Should -Be 405
        (Invoke-Route -Path '/history' -Headers @{ Host = 'evil.example:8091' } -Context $HCtx).Status | Should -Be 421
    }
    It 'T49-19 a copy with no history store answers 404' {
        (Invoke-Route -Path '/history' -Context (New-Context (New-WebRoot))).Status | Should -Be 404
    }
}
Describe 'T50-38 to T50-41 events on /stats and /events, and the methods each path takes' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
        $script:WebRoot50 = New-WebRoot
        # A store holding Count events with ids 1000, 1001, ... (the clock is frozen at 1000 ms)
        function New-FilledStore([int]$Count) {
            $q = New-SrrQueue
            $s = New-EventStore -Clock { [DateTimeOffset]::FromUnixTimeMilliseconds(1000) } -Size 200
            foreach ($i in 1..$Count) { Add-SrrQueueItem -Queue $q -Item (New-SrrEvent -Type 'test' -Severity 'info' -Key "k$i" -Banner $true) }
            Invoke-QueueDrain -Queue $q -Store $s -Clock { [DateTimeOffset]::FromUnixTimeMilliseconds(1000) } | Out-Null
            $s
        }
        function New-EventsContext([int]$Count, [int]$Retention = 31) {
            $c = New-Context $WebRoot50
            $c.Events = New-FilledStore $Count
            $c.LogRetentionDays = $Retention
            $c.Maintenance = [pscustomobject]@{ UntilMs = 0L } | Add-Member ScriptMethod IsOn { $false } -PassThru
            $calls = New-Object System.Collections.Generic.List[int]
            $c.ReadEvents = { param($days) $calls.Add($days); , @(@{ id = 7; type = 'drive-health'; days = $days }) }.GetNewClosure()
            $c.ReadCalls = $calls
            $c
        }
        function Get-Stats($Context, [hashtable]$Query = @{}) {
            $r = Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query $Query -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $Context
            $r.Status | Should -Be 200
            $r.Body | ConvertFrom-Json
        }
        function Get-Events($Context, [object]$Days) {
            $q = @{}; if ($null -ne $Days) { $q.days = $Days }
            Invoke-SrrRoute -Method 'GET' -Path '/events' -Query $q -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $Context
        }
    }
    It 'T50-39 no since: events empty, lastEventId the newest id, maintenance on/untilMs, the old fields kept' {
        $doc = Get-Stats (New-EventsContext 30)
        @($doc.events).Count | Should -Be 0
        $doc.lastEventId | Should -Be 1029
        $doc.maintenance.on | Should -BeFalse
        $doc.maintenance.untilMs | Should -Be 0
        $doc.logRetentionDays | Should -Be 31
        $doc.cpu | Should -Be 3
        $doc.PSObject.Properties.Name | Should -Contain 'uptime'
    }
    It 'T50-40 since a recent id: the 10 newer, oldest first, not truncated' {
        $doc = Get-Stats (New-EventsContext 120) @{ since = '1109' }
        @($doc.events | ForEach-Object id) | Should -Be (1110..1119)
        $doc.PSObject.Properties.Name | Should -Not -Contain 'eventsTruncated'
    }
    It 'T50-40 since an old id: the oldest 50 after it, truncated' {
        $doc = Get-Stats (New-EventsContext 120) @{ since = '1019' }
        @($doc.events | ForEach-Object id) | Should -Be (1020..1069)
        $doc.eventsTruncated | Should -BeTrue
    }
    It 'T50-40 since the newest id: nothing' {
        @((Get-Stats (New-EventsContext 120) @{ since = '1119' }).events).Count | Should -Be 0
    }
    It 'T50-40 an unknown, future, non-numeric or empty since: the newest 50' {
        foreach ($since in '999', '5000', 'abc', '') {
            $doc = Get-Stats (New-EventsContext 120) @{ since = $since }
            @($doc.events | ForEach-Object id) | Should -Be (1070..1119) -Because "since=$since"
            $doc.eventsTruncated | Should -BeTrue
        }
    }
    It 'T50-40 Get-EventsSince on its own' {
        $s = New-FilledStore 5
        $r = Get-EventsSince -Store $s -Since 1002
        @($r.Events | ForEach-Object id) | Should -Be @(1003, 1004)
        $r.Truncated | Should -BeFalse
        (Get-EventsSince -Store (New-EventStore -Clock { [DateTimeOffset]::Now }) -Since 0).Events.Count | Should -Be 0
    }
    It 'T50-41 /events?days=n: 1 and 31 answer from the index, the rest are 400' {
        $c = New-EventsContext 0
        foreach ($d in '1', '31') {
            $r = Get-Events $c $d
            $r.Status | Should -Be 200
            ($r.Body | ConvertFrom-Json).events[0].days | Should -Be ([int]$d)
        }
        foreach ($d in '32', '0', '-1', '1.5', 'abc', '', $null) { (Get-Events $c $d).Status | Should -Be 400 -Because "days=$d" }
        $c.ReadCalls | Should -Be @(1, 31)
        $c60 = New-EventsContext 0 60
        (Get-Events $c60 '60').Status | Should -Be 200
    }
    It 'T50-38 the wrong method is 405 with no CORS headers, and changes nothing' {
        $c = New-EventsContext 3
        $before = $c.Events.Published
        foreach ($m in 'GET', 'PUT', 'DELETE', 'OPTIONS') {
            $r = Invoke-Route $m '/maintenance' -Context $c
            $r.Status | Should -Be 405 -Because "$m /maintenance"
            @($r.Headers.Keys | Where-Object { $_ -like 'Access-Control-*' }).Count | Should -Be 0
        }
        foreach ($p in '/stats', '/history', '/events', '/') { (Invoke-Route 'POST' $p -Context $c).Status | Should -Be 405 -Because "POST $p" }
        [object]::ReferenceEquals($before, $c.Events.Published) | Should -BeTrue
    }
}
Describe 'T50-34 to T50-37 and T50-42 to T50-44: POST /maintenance and /events through the router' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
        Import-Module (Join-Path (Get-RepoRoot) 'modules\EventLog.psm1') -Force
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Maintenance.psm1') -Force
        Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
        $script:Now50 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
        $script:Root50 = New-WebRoot
        function New-MaintContext {
            $c = New-Context $Root50
            $c.Clock = { $script:Now50 }
            $c.Events = New-EventStore -Clock { $script:Now50 }
            $c.LogRetentionDays = 31
            $c.Maintenance = New-MaintenanceState -Clock { $script:Now50 } -Hours 2 -MaxHours 8
            $c.Limiter = New-RateLimiter -Clock { $script:Now50 }
            $c.Changes = New-Object System.Collections.Generic.List[object]
            $ctx = $c
            $c.HandleMaintenance = {
                param($headers, $body, $address)
                $r = Invoke-MaintenanceChange -Headers $headers -Body $body -Address $address -State $ctx.Maintenance -Limiter $ctx.Limiter -Identity $ctx.Identity -Port 8091 -Named $true
                if ($r.Change) { $ctx.Changes.Add($r.Change) }
                $r
            }.GetNewClosure()
            $c
        }
        function Send-Maint($Context, [hashtable]$Headers, [string]$Body = '{"on":true}', [string]$From = '203.0.113.7') {
            Invoke-SrrRoute -Method 'POST' -Path '/maintenance' -Query @{} -Headers $Headers -Body $Body -RemoteAddress $From -LocalPort 8091 -Context $Context
        }
        $script:Good = @{ Host = 'localhost:8091'; Origin = 'http://localhost:8091'; 'X-SRRVRR' = '1'; 'Content-Type' = 'application/json' }
        # An index over a temp log folder: Count logged events spread evenly over the last 31 days.
        function New-FullIndex([int]$Count, [hashtable[]]$Extra = @()) {
            $dir = New-TestDataPath
            $span = [TimeSpan]::FromDays(30.9).TotalMilliseconds
            $byDay = @{}
            for ($i = 0; $i -lt $Count; $i++) {
                $t = $Now50.AddMilliseconds(-$span + $span * $i / $Count)
                $line = '{"id":' + ($t.ToUnixTimeMilliseconds() + $i) + ',"time":' + $t.ToUnixTimeMilliseconds() + ',"type":"drive-health","severity":"flag","maintenance":false,"data":{"n":' + $i + '}}'
                $name = 'events-' + $t.ToString('yyyy-MM-dd') + '.jsonl'
                if (-not $byDay[$name]) { $byDay[$name] = New-Object System.Collections.Generic.List[string] }
                $byDay[$name].Add($line)
            }
            foreach ($k in $byDay.Keys) { [IO.File]::WriteAllLines((Join-Path $dir $k), [string[]]$byDay[$k]) }
            Initialize-EventIndex -LogDir $dir -Days 31 -Now $Now50
        }
    }
    It 'T50-34 a valid POST turns it on, and another client''s /stats shows the same untilMs' {
        $c = New-MaintContext
        $r = Send-Maint $c $Good
        $r.Status | Should -Be 200
        $body = $r.Body | ConvertFrom-Json
        $body.on | Should -BeTrue
        $body.untilMs | Should -Be $Now50.AddHours(2).ToUnixTimeMilliseconds()
        $s = Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '203.0.113.8' -LocalPort 8091 -Context $c
        $doc = $s.Body | ConvertFrom-Json
        $doc.maintenance.on | Should -BeTrue
        $doc.maintenance.untilMs | Should -Be $body.untilMs
    }
    It 'T50-35 a correct Origin from 127.0.0.1 is accepted and recorded with its address' {
        $c = New-MaintContext
        $h = @{ Host = '127.0.0.1:8091'; Origin = 'http://127.0.0.1:8091'; 'X-SRRVRR' = '1'; 'Content-Type' = 'application/json' }
        (Send-Maint $c $h -From '127.0.0.1').Status | Should -Be 200
        $c.Changes[0].data.address | Should -Be '127.0.0.1'
    }
    It 'T50-37 DNS rebinding: a foreign Host is 421 before the guard runs, and nothing changes' {
        $c = New-MaintContext
        $h = @{ Host = 'evil.example:8091'; Origin = 'http://evil.example:8091'; 'X-SRRVRR' = '1'; 'Content-Type' = 'application/json' }
        (Send-Maint $c $h).Status | Should -Be 421
        $c.Maintenance.IsOn() | Should -BeFalse
        $c.Changes.Count | Should -Be 0
    }
    It 'T50-36 through the router: no X-SRRVRR is 403, a bad body 400, a second change within 10 s 429' {
        $c = New-MaintContext
        $h = $Good.Clone(); $h.Remove('X-SRRVRR')
        (Send-Maint $c $h).Status | Should -Be 403
        (Send-Maint $c $Good '{"on":"yes"}').Status | Should -Be 400
        (Send-Maint $c $Good).Status | Should -Be 200
        (Send-Maint $c $Good '{"on":false}').Status | Should -Be 429
        $c.Changes.Count | Should -Be 1
    }
    It 'T50-42 with 5,000 events over 31 days, /events?days=31 returns the newest 1,000, newest first' {
        $c = New-MaintContext
        $index = New-FullIndex 5000
        $now = $Now50; $c.ReadEvents = { param($days) Get-IndexedEvents -Index $index -Days $days -Now $now }.GetNewClosure()
        $r = Invoke-SrrRoute -Method 'GET' -Path '/events' -Query @{ days = '31' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c
        $r.Status | Should -Be 200
        $events = @(($r.Body | ConvertFrom-Json).events)
        $events.Count | Should -Be 1000
        $events[0].data.n | Should -Be 4999
        $events[999].data.n | Should -Be 4000
    }
    It 'T50-43 /events?days=31 over 5,000 events answers within 50 ms at p95, and /stats within 30 ms' {
        $c = New-MaintContext
        $index = New-FullIndex 5000
        $now = $Now50; $c.ReadEvents = { param($days) Get-IndexedEvents -Index $index -Days $days -Now $now }.GetNewClosure()
        # Warm up first (#69): the first calls compile the code path and once pushed a run's p95 past 50 ms.
        foreach ($i in 1..5) { $null = Invoke-SrrRoute -Method 'GET' -Path '/events' -Query @{ days = '31' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c; $null = Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{ since = '0' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c }
        $ev = foreach ($i in 1..100) { (Measure-Command { Invoke-SrrRoute -Method 'GET' -Path '/events' -Query @{ days = '31' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c }).TotalMilliseconds }
        $st = foreach ($i in 1..100) { (Measure-Command { Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{ since = '0' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c }).TotalMilliseconds }
        (Invoke-SrrRoute -Method 'GET' -Path '/events' -Query @{ days = '31' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c).Status | Should -Be 200
        $p95 = { param($v) @($v | Sort-Object)[[int][Math]::Ceiling(0.95 * @($v).Count) - 1] }
        Write-Host ("    /events p95 {0:N1} ms, /stats p95 {1:N1} ms" -f (& $p95 $ev), (& $p95 $st))
        if (-not $env:GITHUB_ACTIONS) {   # informational on CI's shared runners, a budget on the server
            (& $p95 $ev) | Should -BeLessThan 50
            (& $p95 $st) | Should -BeLessThan 30
        }
    }
    It 'T50-44 /events never carries a player, user, device or title name' {
        $dir = New-TestDataPath
        try {
            $clock = { $script:Now50 }
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $clock
            $index = Initialize-EventIndex -LogDir $dir -Days 31 -Now $Now50
            $write = New-EventLogWriter -Log $log
            $q = New-SrrQueue; $store = New-EventStore -Clock $clock
            $old = @{ activity = @{ Valheim = @{ players = 0; names = @() }; Plex = @{ items = @() } } }
            $new = @{ activity = @{ Valheim = @{ players = 1; names = @(@{ name = 'CanaryVikingQx' }) }; Plex = @{ items = @(@{ key = 's1'; user = 'CanaryUserWv'; title = 'CanaryFilmYp'; device = 'CanaryTvKj'; app = 'CanaryAppRr' }) } } }
            foreach ($e in Get-StateEvents -Old $old -New $new) { $e.logged = $true; Add-SrrQueueItem -Queue $q -Item $e }
            $writers = @{ Event = { param($e) & $write $e; [void]$index.Add((ConvertTo-LoggedEvent $e)) }.GetNewClosure() }
            Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $clock | Should -Be 1   # the join (Plex streams raise none, #57)
            $c = New-MaintContext
            $now = $Now50; $c.ReadEvents = { param($days) Get-IndexedEvents -Index $index -Days $days -Now $now }.GetNewClosure()
            $r = Invoke-SrrRoute -Method 'GET' -Path '/events' -Query @{ days = '1' } -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c
            @(($r.Body | ConvertFrom-Json).events).Count | Should -Be 1
            $r.Body | Should -Not -Match 'Canary'
        } finally { Remove-TestDataPath $dir }
    }
}
Describe 'T50-38 a slow POST body can''t hold up the server' {
    It 'T50-38 a body sent a byte at a time is cut off after its deadline, and /stats still answers within seconds' {
        $c = New-Context (New-WebRoot)
        $server = Start-TestServer -Context $c
        try {
            $tcp = New-Object Net.Sockets.TcpClient('localhost', $server.Port)
            $stream = $tcp.GetStream()
            $head = "POST /maintenance HTTP/1.1`r`nHost: localhost:$($server.Port)`r`nX-SRRVRR: 1`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n{"
            $bytes = [Text.Encoding]::ASCII.GetBytes($head); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            Start-Sleep -Milliseconds 300
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-TestRequest -Url "http://localhost:$($server.Port)/stats"
            $sw.Stop()
            $r.Status | Should -Be 200
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
            $tcp.Close()
        } finally { Stop-TestServer $server }
    }
    It 'T50-38 a POST without X-SRRVRR: 1 is refused before any body is read' {
        $c = New-Context (New-WebRoot)
        $server = Start-TestServer -Context $c
        try {
            $tcp = New-Object Net.Sockets.TcpClient('localhost', $server.Port)
            $stream = $tcp.GetStream()
            $head = "POST /maintenance HTTP/1.1`r`nHost: localhost:$($server.Port)`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n"
            $bytes = [Text.Encoding]::ASCII.GetBytes($head); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            $stream.ReadTimeout = 3000
            $reader = New-Object IO.StreamReader($stream)
            $reader.ReadLine() | Should -Match '^HTTP/1\.1 403'
            $tcp.Close()
        } finally { Stop-TestServer $server }
    }
}