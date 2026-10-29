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
