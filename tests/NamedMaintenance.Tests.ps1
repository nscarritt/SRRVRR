# Maintenance limited to named PCs (#79, spec 0.9.0 section 5, Q9 and Q10): the named-PC check on POST /maintenance,
# the refusal counter, and /stats viewer. The named index is built directly with New-NamedPcIndex (the NamedPCs
# setting's validation is #78's). Fixture addresses are from the documentation ranges.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $root = Get-RepoRoot
    Import-Module (Join-Path $root 'modules\Maintenance.psm1') -Force
    Import-Module (Join-Path $root 'modules\Web.psm1') -Force
    Import-Module (Join-Path $root 'modules\Transfers.psm1') -Force
    $script:Root = $root
    $script:T0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
    $fakeTime = @{ Now = $T0 }
    $script:Fake = $fakeTime
    $script:Clock = { $fakeTime.Now }.GetNewClosure()
    $script:Identity = @{ Names = @('SRRVRR', 'SRRVRR.local'); Addresses = @('192.0.2.1', 'fe80::1%4', '2001:db8::1') }
    $script:Index = New-NamedPcIndex -NamedPCs @(
        @{ Name = 'Desk PC'; Addresses = @('192.0.2.10', 'fe80::5') },
        @{ Name = 'Laptop'; Addresses = @('192.0.2.20') })
    function Get-GoodHeader([hashtable]$Change = @{}) {
        $h = @{ 'Host' = 'SRRVRR:8091'; 'X-SRRVRR' = '1'; 'Content-Type' = 'application/json'; 'Origin' = 'http://SRRVRR:8091' }
        foreach ($k in $Change.Keys) { if ($null -eq $Change[$k]) { $h.Remove($k) } else { $h[$k] = $Change[$k] } }
        $h
    }
    # A limiter that records every ask, so a test can prove it was never asked.
    function New-SpyLimiter {
        $l = [pscustomobject]@{ Asked = 0 }
        $l | Add-Member ScriptMethod Allow { param([string]$Address) $this.Asked++; $true }
        $l
    }
    # The web context as SRRVRR.ps1 builds it: HandleMaintenance decides -Named from the address alone.
    function New-NamedContext([hashtable]$NamedIndex = $Index, [switch]$NoViewer) {
        $c = @{
            State = @{ ready = $true; cpu = 3 }; WebRoot = (Join-Path (New-TestDataPath) 'web'); Identity = $Identity
            BootTime = [DateTimeOffset]::new(2026, 1, 5, 11, 0, 0, [TimeSpan]::Zero)
            Clock = { [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero) }
            LogError = { param($message) }
            NamedIndex = $NamedIndex
        }
        $c.Maintenance = New-MaintenanceState -Clock $Clock -Hours 2 -MaxHours 8
        $c.Limiter = New-RateLimiter -Clock $Clock
        $c.Refusals = New-RefusalCounter
        $ctx = $c
        $c.HandleMaintenance = {
            param($headers, $body, $address)
            $named = (Find-NamedPC -Address $address -Index $ctx.NamedIndex -ServerAddresses $ctx.Identity.Addresses).Known
            Invoke-MaintenanceChange -Headers $headers -Body $body -Address $address -State $ctx.Maintenance -Limiter $ctx.Limiter -Identity $ctx.Identity -Port 8091 -Named $named -Refusals $ctx.Refusals
        }.GetNewClosure()
        if (-not $NoViewer) {
            $c.Viewer = { param($address) Find-NamedPC -Address $address -Index $ctx.NamedIndex -ServerAddresses $ctx.Identity.Addresses }.GetNewClosure()
        }
        $c
    }
    function Send-Maint($Context, [string]$From, [hashtable]$Headers = (Get-GoodHeader), [string]$Body = '{"on":true}') {
        Invoke-SrrRoute -Method 'POST' -Path '/maintenance' -Query @{} -Headers $Headers -Body $Body -RemoteAddress $From -LocalPort 8091 -Context $Context
    }
    function Get-Stats($Context, [string]$From, [hashtable]$Headers = @{ Host = 'localhost:8091' }) {
        $r = Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{} -Headers $Headers -Body '' -RemoteAddress $From -LocalPort 8091 -Context $Context
        $r.Body | ConvertFrom-Json
    }
}

Describe 'T79-01 an address that is not a named PC is refused' {
    It 'T79-01 a good request with -Named $false is 403 not a named PC, changes nothing, never asks the limiter, counts one refusal with the address' {
        $state = New-MaintenanceState -Clock $Clock -Hours 2
        $spy = New-SpyLimiter
        $refusals = New-RefusalCounter
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":true}' -Address '192.0.2.99' -State $state -Limiter $spy -Identity $Identity -Port 8091 -Named $false -Refusals $refusals
        $r.Status | Should -Be 403
        ($r.Body | ConvertTo-Json -Compress) | Should -Be '{"error":"not a named PC"}'
        $r.Change | Should -BeNullOrEmpty
        $state.IsOn() | Should -BeFalse
        $spy.Asked | Should -Be 0
        $taken = $refusals.Take()
        $taken.Count | Should -Be 1
        @($taken.Addresses) | Should -Be @('192.0.2.99')
    }
    It 'T79-01 an unnamed request is refused for turning Maintenance off too, and the state stays on' {
        $state = New-MaintenanceState -Clock $Clock -Hours 2
        $null = $state.SetOn('127.0.0.1')
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":false}' -Address '192.0.2.99' -State $state -Limiter (New-SpyLimiter) -Identity $Identity -Port 8091 -Named $false -Refusals (New-RefusalCounter)
        $r.Status | Should -Be 403
        $state.IsOn() | Should -BeTrue
    }
    It 'T79-01 named (the default) still changes Maintenance, so the existing callers are unchanged' {
        $state = New-MaintenanceState -Clock $Clock -Hours 2
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":true}' -Address '192.0.2.10' -State $state -Limiter (New-RateLimiter -Clock $Clock) -Identity $Identity -Port 8091
        $r.Status | Should -Be 200
        $state.IsOn() | Should -BeTrue
        $explicit = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":false}' -Address '192.0.2.10' -State $state -Limiter (New-RateLimiter -Clock $Clock) -Identity $Identity -Port 8091 -Named $true
        $explicit.Status | Should -Be 200
    }
    It 'T79-01 a refusal with no Refusals counter given is still the 403 (nothing to count into)' {
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":true}' -Address '192.0.2.99' -State (New-MaintenanceState -Clock $Clock) -Limiter (New-SpyLimiter) -Identity $Identity -Port 8091 -Named $false
        $r.Status | Should -Be 403
    }
}

Describe 'T79-02 the order of the checks' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T79-02 an unnamed address with no X-SRRVRR, a wrong content type or a bad Origin gets the guard''s 403 refused, and is not counted as a named-PC refusal' {
        foreach ($change in @{ 'X-SRRVRR' = $null }, @{ 'Content-Type' = 'text/plain' }, @{ Origin = 'http://evil.example:8091' }, @{ Origin = $null }, @{ 'X-SRRVRR' = '2' }) {
            $refusals = New-RefusalCounter
            $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader $change) -Body '{"on":true}' -Address '192.0.2.99' -State (New-MaintenanceState -Clock $Clock) -Limiter (New-SpyLimiter) -Identity $Identity -Port 8091 -Named $false -Refusals $refusals
            $r.Status | Should -Be 403
            ($r.Body | ConvertTo-Json -Compress) | Should -Be '{"error":"refused"}' -Because ($change.Keys -join ',')
            $refusals.Take().Count | Should -Be 0 -Because 'the guard answers first'
        }
    }
    It 'T79-02 an unnamed address with a bad body is 403 not a named PC, not 400: the check comes before the body' {
        foreach ($body in '', 'not json', '{"on":"yes"}', ('{"on":true,"x":"' + ('a' * 2000) + '"}')) {
            $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body $body -Address '192.0.2.99' -State (New-MaintenanceState -Clock $Clock) -Limiter (New-SpyLimiter) -Identity $Identity -Port 8091 -Named $false -Refusals (New-RefusalCounter)
            $r.Status | Should -Be 403
            $r.Body.error | Should -Be 'not a named PC'
        }
    }
    It 'T79-02 a named address with a bad body is 400: the body check still runs after the named check' {
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body 'not json' -Address '192.0.2.10' -State (New-MaintenanceState -Clock $Clock) -Limiter (New-SpyLimiter) -Identity $Identity -Port 8091 -Named $true
        $r.Status | Should -Be 400
    }
    It 'T79-02 an unnamed address is refused before the rate limit: 20 refusals never use up a named PC''s turn, and the limiter holds nothing for them' {
        $c = New-NamedContext
        for ($i = 0; $i -lt 20; $i++) { (Send-Maint $c '192.0.2.99').Status | Should -Be 403 }
        $c.Limiter.Refused | Should -Be 0
        (Send-Maint $c '192.0.2.99').Body | Should -Match 'not a named PC'
        $c.Limiter.Counts.Count | Should -Be 0
        $c.Limiter.Last.Count | Should -Be 0
        (Send-Maint $c '192.0.2.10').Status | Should -Be 200
    }
    It 'T79-02 a named address''s second change within 10 s is 429, not 403' {
        $c = New-NamedContext
        (Send-Maint $c '192.0.2.10').Status | Should -Be 200
        $Fake.Now = $T0.AddSeconds(3)
        $r = Send-Maint $c '192.0.2.10' -Body '{"on":false}'
        $r.Status | Should -Be 429
        $Fake.Now = $T0.AddSeconds(11)
        (Send-Maint $c '192.0.2.10' -Body '{"on":false}').Status | Should -Be 200
    }
    It 'T79-02 the Host check still comes first: a foreign Host from an unnamed address is 421 and not counted' {
        $c = New-NamedContext
        $r = Send-Maint $c '192.0.2.99' -Headers (Get-GoodHeader @{ Host = 'evil.example:8091' })
        $r.Status | Should -Be 421
        $c.Refusals.Take().Count | Should -Be 0
    }
    It 'T79-02 Invoke-MaintenanceChange checks in the order guard, named, body, limiter (source order)' {
        $text = (Get-Command Invoke-MaintenanceChange).ScriptBlock.ToString()
        $guard = $text.IndexOf('Test-MaintenanceRequest'); $named = $text.IndexOf('-not $Named')
        $body = $text.IndexOf('ConvertFrom-MaintenanceBody'); $limit = $text.IndexOf('Limiter.Allow')
        $guard | Should -BeGreaterThan -1
        $named | Should -BeGreaterThan $guard
        $body | Should -BeGreaterThan $named
        $limit | Should -BeGreaterThan $body
    }
}

Describe 'T79-03 which addresses may change Maintenance, through the route' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T79-03 with NamedPCs: ::ffff:192.0.2.20 and fe80::5%3 (listed) 200, 192.0.2.99 403, 127.0.0.1, ::1 and a server address 200' {
        $expected = [ordered]@{ '::ffff:192.0.2.20' = 200; 'fe80::5%3' = 200; '192.0.2.99' = 403; '127.0.0.1' = 200; '::1' = 200; '192.0.2.1' = 200 }
        foreach ($from in $expected.Keys) {
            $c = New-NamedContext
            (Send-Maint $c $from).Status | Should -Be $expected[$from] -Because $from
        }
    }
    It 'T79-03 with no NamedPCs only the server itself (loopback and its own addresses) can change Maintenance' {
        $expected = [ordered]@{ '::ffff:192.0.2.20' = 403; 'fe80::5%3' = 403; '192.0.2.99' = 403; '127.0.0.1' = 200; '::1' = 200; '192.0.2.1' = 200; 'fe80::1' = 200; '2001:db8::1' = 200 }
        foreach ($from in $expected.Keys) {
            $c = New-NamedContext -NamedIndex @{}
            (Send-Maint $c $from).Status | Should -Be $expected[$from] -Because $from
        }
    }
    It 'T79-03 a refusal through the route is 403 JSON {"error":"not a named PC"} and the state is unchanged' {
        $c = New-NamedContext
        $r = Send-Maint $c '192.0.2.99'
        $r.Status | Should -Be 403
        $r.Body | Should -Be '{"error":"not a named PC"}'
        $c.Maintenance.IsOn() | Should -BeFalse
    }
    It 'T79-03 a named PC changes Maintenance, a change by it is recorded with its address' {
        $c = New-NamedContext
        $r = Invoke-MaintenanceChange -Headers (Get-GoodHeader) -Body '{"on":true}' -Address '192.0.2.10' -State $c.Maintenance -Limiter $c.Limiter -Identity $Identity -Port 8091 -Named $true
        $r.Change.data.address | Should -Be '192.0.2.10'
    }
}

Describe 'T79-03 bypass attempts' {
    BeforeEach { $Fake.Now = $T0 }
    It 'T79-03 an empty, null, whitespace or malformed address is refused' {
        foreach ($from in '', ' ', 'not-an-ip', '192.0.2.10.5', '192.0.2.256', '192.0.2', 'localhost', '::g', '[', '%', '%3', '192.0.2.10,127.0.0.1', '127.0.0.1, 192.0.2.10') {
            $c = New-NamedContext
            (Send-Maint $c $from).Status | Should -Be 403 -Because "'$from'"
            $c.Maintenance.IsOn() | Should -BeFalse
        }
    }
    It 'T79-03 an IPv6 form that merely contains a named IPv4 is refused (only the IPv4-mapped form is the same address)' {
        foreach ($from in '64:ff9b::192.0.2.10', '::192.0.2.10', '2001:db8:c000:20a::', '::ffff:0:192.0.2.10', '2001:db8::c000:20a', '::ffff:192.0.2.11') {
            $c = New-NamedContext
            (Send-Maint $c $from).Status | Should -Be 403 -Because $from
        }
    }
    It 'T79-03 near misses of a named address are refused: a longer or shorter one, a neighbour, another zone-less IPv6' {
        foreach ($from in '192.0.2.100', '192.0.2.1000', '192.0.2.2', '198.51.100.10', '192.0.2.11', 'fe80::50', 'fe80::', 'fe80::6', '10.0.0.10') {
            $c = New-NamedContext -NamedIndex (New-NamedPcIndex -NamedPCs @(@{ Name = 'Desk PC'; Addresses = @('192.0.2.10', 'fe80::5') }))
            (Send-Maint $c $from).Status | Should -Be 403 -Because $from
        }
    }
    It 'T79-03 the unspecified addresses 0.0.0.0 and :: are not the server and not named' {
        foreach ($from in '0.0.0.0', '::') { (Send-Maint (New-NamedContext) $from).Status | Should -Be 403 -Because $from }
    }
    It 'T79-03 an IPv4-mapped loopback and the long form of ::1 are the server itself' {
        foreach ($from in '::ffff:127.0.0.1', '0:0:0:0:0:0:0:1', '[::1]', '127.0.0.2') { (Send-Maint (New-NamedContext -NamedIndex @{}) $from).Status | Should -Be 200 -Because $from }
    }
    It 'T79-03 upper case, brackets and a zone id on a named address all match the same PC' {
        $c = New-NamedContext -NamedIndex (New-NamedPcIndex -NamedPCs @(@{ Name = 'Desk PC'; Addresses = @('2001:DB8::AB') }))
        foreach ($from in '2001:db8::ab', '2001:DB8::AB', '[2001:db8::ab]', '2001:db8::ab%7') {
            (Send-Maint $c $from -Headers (Get-GoodHeader)).Status | Should -BeIn 200, 429 -Because $from
            $Fake.Now = $Fake.Now.AddSeconds(11)
        }
    }
    It 'T79-03 a named PC listed by its IPv4-mapped IPv6 address matches its IPv4 address' {
        $c = New-NamedContext -NamedIndex (New-NamedPcIndex -NamedPCs @(@{ Name = 'Desk PC'; Addresses = @('::ffff:192.0.2.30') }))
        (Send-Maint $c '192.0.2.30').Status | Should -Be 200
    }
    It 'T79-03 an entry in NamedPCs that is not an address, or a Name with no Addresses, lets nobody in' {
        foreach ($entry in @{ Name = 'Bad'; Addresses = @('') }, @{ Name = 'Bad'; Addresses = @('*') }, @{ Name = 'Bad'; Addresses = @('0.0.0.0/0') }, @{ Name = 'Bad'; Addresses = @('192.0.2.0/24') }, @{ Name = 'Bad' }, @{ Name = 'Bad'; Addresses = @($null) }) {
            $c = New-NamedContext -NamedIndex (New-NamedPcIndex -NamedPCs @($entry))
            (Send-Maint $c '192.0.2.99').Status | Should -Be 403
            (Send-Maint $c '192.0.2.5').Status | Should -Be 403
        }
    }
    It 'T79-03 a named PC''s turn is not used by another address: the limiter keys on the real address' {
        $c = New-NamedContext
        (Send-Maint $c '192.0.2.10').Status | Should -Be 200
        (Send-Maint $c '192.0.2.99' -Body '{"on":false}').Status | Should -Be 403
        (Send-Maint $c '192.0.2.20' -Body '{"on":false}').Status | Should -Be 200
    }
}

Describe 'T79-05 the refusal counter' {
    It 'T79-05 7 refusals from 6 addresses: Take gives Count 7 and 5 addresses, then Count 0 and none' {
        $rc = New-RefusalCounter
        foreach ($a in '192.0.2.1', '192.0.2.2', '192.0.2.2', '192.0.2.3', '192.0.2.4', '192.0.2.5', '192.0.2.6') { $rc.Add($a) }
        $first = $rc.Take()
        $first.Count | Should -Be 7
        @($first.Addresses).Count | Should -Be 5
        @($first.Addresses | Select-Object -Unique).Count | Should -Be 5
        $again = $rc.Take()
        $again.Count | Should -Be 0
        @($again.Addresses).Count | Should -Be 0
    }
    It 'T79-05 counts after a Take start again, and one address refused many times is listed once' {
        $rc = New-RefusalCounter
        1..50 | ForEach-Object { $rc.Add('192.0.2.9') }
        $t = $rc.Take()
        $t.Count | Should -Be 50
        @($t.Addresses) | Should -Be @('192.0.2.9')
        $rc.Add('192.0.2.8')
        (($rc.Take()).Addresses -join ',') | Should -Be '192.0.2.8'
    }
    It 'T79-05 a flood from many addresses holds only 5 of them (memory stays small)' {
        $rc = New-RefusalCounter
        1..2000 | ForEach-Object { $rc.Add("198.51.100.$($_ % 250)") }
        $rc.Addresses.Count | Should -Be 5
        $rc.Take().Count | Should -Be 2000
    }
    It 'T79-05 an empty address is counted as unknown' {
        $rc = New-RefusalCounter
        $rc.Add('')
        $rc.Add($null)
        $t = $rc.Take()
        $t.Count | Should -Be 2
        @($t.Addresses) | Should -Be @('unknown')
    }
    It 'T79-05 the minute line in SRRVRR.ps1 counts the rate-limit and the named refusals and names the addresses' {
        $text = Get-Content -Raw (Join-Path $Root 'SRRVRR.ps1')
        $text | Should -Match 'TakeRefused\(\)'
        $text | Should -Match '\$maintenanceRefusals\.Take\(\)'
        $text | Should -Match 'from PCs that are not named'
        $text | Should -Match 'Addresses -join'
        $text | Should -Match 'New-RefusalCounter'
    }
}

Describe 'T79-04 the startup line' {
    It 'T79-04 SRRVRR.ps1 says Maintenance can be changed only at the server itself when NamedPCs is empty' {
        $text = Get-Content -Raw (Join-Path $Root 'SRRVRR.ps1')
        $text | Should -Match "No NamedPCs set: Maintenance can be changed only at the server itself\."
        $text | Should -Match "(?m)^if \(\(New-NamedPcIndex -NamedPCs @\(\`$settings\['NamedPCs'\]\)\)\.Count -eq 0\) \{ Write-Status 'No NamedPCs set"
    }
}

Describe 'T79-07 only the connection''s own address counts' {
    It 'T79-07 spoofed X-Forwarded-For, Forwarded, X-Real-IP, Client-IP, X-Originating-IP and a Host naming a listed address from an unnamed address are still 403' {
        $spoof = @{
            'X-Forwarded-For' = '192.0.2.10'; 'Forwarded' = 'for=192.0.2.10'; 'X-Real-IP' = '192.0.2.10'; 'Client-IP' = '192.0.2.10'
            'X-Originating-IP' = '192.0.2.10'; 'X-Forwarded-Host' = '192.0.2.10:8091'; 'True-Client-IP' = '127.0.0.1'; 'X-Client-IP' = '::1'
            'X-Remote-Addr' = '127.0.0.1'; 'X-Forwarded' = '127.0.0.1'; 'X-Cluster-Client-IP' = '192.0.2.20'; 'CF-Connecting-IP' = '192.0.2.10'
        }
        $c = New-NamedContext
        $h = Get-GoodHeader $spoof
        $r = Send-Maint $c '192.0.2.99' -Headers $h
        $r.Status | Should -Be 403
        $r.Body | Should -Be '{"error":"not a named PC"}'
        $c.Maintenance.IsOn() | Should -BeFalse
        foreach ($name in $spoof.Keys) {
            $one = Get-GoodHeader @{ $name = $spoof[$name] }
            (Send-Maint (New-NamedContext) '192.0.2.99' -Headers $one).Status | Should -Be 403 -Because $name
        }
    }
    It 'T79-07 a Host and an Origin that name a listed server address do not make the sender the server' {
        $c = New-NamedContext
        $h = Get-GoodHeader @{ Host = '192.0.2.1:8091'; Origin = 'http://192.0.2.1:8091' }
        (Send-Maint $c '192.0.2.99' -Headers $h).Status | Should -Be 403
        $h2 = Get-GoodHeader @{ Host = '127.0.0.1:8091'; Origin = 'http://localhost:8091' }
        (Send-Maint $c '192.0.2.99' -Headers $h2).Status | Should -Be 403
    }
    It 'T79-07 the same spoofed headers from a named address change nothing either way: the named address is what counts' {
        $c = New-NamedContext
        $h = Get-GoodHeader @{ 'X-Forwarded-For' = '203.0.113.5' }
        (Send-Maint $c '192.0.2.10' -Headers $h).Status | Should -Be 200
    }
    It 'T79-07 /stats viewer is unnamed for an unnamed address whatever the headers say' {
        $c = New-NamedContext
        $h = @{ Host = '192.0.2.1:8091'; 'X-Forwarded-For' = '192.0.2.10'; Forwarded = 'for=127.0.0.1'; 'X-Real-IP' = '::1' }
        $v = (Get-Stats $c '192.0.2.99' $h).viewer
        $v.name | Should -BeNullOrEmpty
        $v.canChangeMaintenance | Should -BeFalse
        $v.address | Should -Be '192.0.2.99'
    }
    It 'T79-07 SRRVRR.ps1 takes the address from the connection (RemoteEndPoint) and never reads a forwarding header' {
        $web = Get-Content -Raw (Join-Path $Root 'modules\Web.psm1')
        $main = Get-Content -Raw (Join-Path $Root 'SRRVRR.ps1')
        $web | Should -Match 'RemoteAddress = \[string\]\$r\.RemoteEndPoint\.Address'
        foreach ($t in $web, $main, (Get-Content -Raw (Join-Path $Root 'modules\Maintenance.psm1'))) {
            $t | Should -Not -Match '(?i)x-forwarded|x-real-ip|client-ip|\bForwarded\b'
        }
    }
}

Describe 'T79-06 /stats viewer' {
    It 'T79-06 a named address: name, canChangeMaintenance true, the address the server saw' {
        $v = (Get-Stats (New-NamedContext) '192.0.2.10').viewer
        $v.name | Should -Be 'Desk PC'
        $v.canChangeMaintenance | Should -BeTrue
        $v.address | Should -Be '192.0.2.10'
    }
    It 'T79-06 an unnamed address: name null, false, and its address' {
        $v = (Get-Stats (New-NamedContext) '192.0.2.99').viewer
        $v.name | Should -BeNullOrEmpty
        $v.canChangeMaintenance | Should -BeFalse
        $v.address | Should -Be '192.0.2.99'
    }
    It 'T79-06 the server itself: no name, true' {
        foreach ($from in '127.0.0.1', '::1', '192.0.2.1') {
            $v = (Get-Stats (New-NamedContext) $from).viewer
            $v.name | Should -BeNullOrEmpty
            $v.canChangeMaintenance | Should -BeTrue -Because $from
        }
    }
    It 'T79-06 an IPv4-mapped IPv6 address is shown and matched as the IPv4 address' {
        $v = (Get-Stats (New-NamedContext) '::ffff:192.0.2.20').viewer
        $v.name | Should -Be 'Laptop'
        $v.address | Should -Be '192.0.2.20'
    }
    It 'T79-06 an empty or malformed address is unnamed and cannot change Maintenance' {
        foreach ($from in '', 'junk') {
            $v = (Get-Stats (New-NamedContext) $from).viewer
            $v.canChangeMaintenance | Should -BeFalse -Because "'$from'"
            $v.name | Should -BeNullOrEmpty
        }
    }
    It 'T79-06 with no Viewer in the context there is no viewer field, and every other field is unchanged' {
        $without = Get-Stats (New-NamedContext -NoViewer) '192.0.2.10'
        $with = Get-Stats (New-NamedContext) '192.0.2.10'
        $without.PSObject.Properties.Name | Should -Not -Contain 'viewer'
        $with.PSObject.Properties.Name | Should -Contain 'viewer'
        $a = $without.PSObject.Properties.Name | Sort-Object
        $b = $with.PSObject.Properties.Name | Where-Object { $_ -ne 'viewer' } | Sort-Object
        ($a -join ',') | Should -Be ($b -join ',')
        foreach ($k in $a) { ($with.$k | ConvertTo-Json -Compress) | Should -Be ($without.$k | ConvertTo-Json -Compress) -Because $k }
    }
    It 'T79-06 a Viewer that throws gives a viewer that cannot change Maintenance, and /stats still answers' {
        $c = New-NamedContext
        $c.Viewer = { param($address) throw 'boom' }
        $r = Invoke-SrrRoute -Method 'GET' -Path '/stats' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '127.0.0.1' -LocalPort 8091 -Context $c
        $r.Status | Should -Be 200
        $v = ($r.Body | ConvertFrom-Json).viewer
        $v.canChangeMaintenance | Should -BeFalse
    }
    It 'T79-06 Get-SrrViewer from a Find-NamedPC match, a missing match and a malformed one' {
        $m = Find-NamedPC -Address '192.0.2.10' -Index $Index
        $v = Get-SrrViewer -Match $m
        $v.name | Should -Be 'Desk PC'; $v.canChangeMaintenance | Should -BeTrue; $v.address | Should -Be '192.0.2.10'
        $none = Get-SrrViewer -Match $null -Address '192.0.2.99'
        $none.canChangeMaintenance | Should -BeFalse; $none.address | Should -Be '192.0.2.99'
        $bad = Get-SrrViewer -Match @(1, 2) -Address 'x'
        $bad.canChangeMaintenance | Should -BeFalse
        (Get-SrrViewer -Match @{ Known = 'yes'; Address = '203.0.113.4' }).canChangeMaintenance | Should -BeFalse
    }
    It 'T79-06 GET /maintenance, other paths and other methods are unaffected by who is asking' {
        $c = New-NamedContext
        (Invoke-SrrRoute -Method 'GET' -Path '/maintenance' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '192.0.2.99' -LocalPort 8091 -Context $c).Status | Should -Be 405
        (Invoke-SrrRoute -Method 'PUT' -Path '/stats' -Query @{} -Headers @{ Host = 'localhost:8091' } -Body '' -RemoteAddress '192.0.2.99' -LocalPort 8091 -Context $c).Status | Should -Be 405
    }
}

Describe 'T79-08 SRRVRR.ps1 wiring' {
    BeforeAll { $script:Main = Get-Content -Raw (Join-Path $Root 'SRRVRR.ps1') }
    It 'T79-08 Invoke-MaintenanceRequest passes -Named from the request''s own address through Find-NamedPC, and the refusal counter' {
        $Main | Should -Match 'Find-NamedPC -Address \$Address -Index \$webContext\.NamedIndex -ServerAddresses \$webContext\.Identity\.Addresses'
        $Main | Should -Match '-Named \$named -Refusals \$maintenanceRefusals'
    }
    It 'T79-08 $webContext has NamedIndex (from NamedPCs) and Viewer' {
        $Main | Should -Match 'NamedIndex = New-NamedPcIndex -NamedPCs @\(\$settings\[''NamedPCs''\]\)'
        $Main | Should -Match '(?m)^\s+Viewer = \{ param\(\$address\) Find-NamedPC -Address \$address -Index \$webContext\.NamedIndex -ServerAddresses \$webContext\.Identity\.Addresses \}'
    }
    It 'T79-08 the named check cannot be skipped: no call to Invoke-MaintenanceChange without -Named in SRRVRR.ps1' {
        $calls = [regex]::Matches($Main, '(?m)^.*Invoke-MaintenanceChange .*$')
        $calls.Count | Should -BeGreaterThan 0
        foreach ($m in $calls) { $m.Value | Should -Match '-Named \$named' }
    }
    It 'T79-08 the whole script still parses' {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Root 'SRRVRR.ps1'), [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
}

Describe 'T79-11 the docs' {
    BeforeAll {
        $script:Readme = Get-Content -Raw (Join-Path $Root 'README.md')
        $script:Changelog = Get-Content -Raw (Join-Path $Root 'CHANGELOG.md')
        $i = $Changelog.IndexOf('## [Unreleased]'); $j = $Changelog.IndexOf('## [', $i + 5)
        $script:Unreleased = $Changelog.Substring($i, $j - $i)
    }
    It 'T79-11 README no longer says any device can tick Maintenance' {
        $Readme | Should -Not -Match 'Any device that can open the\s+page can tick it'
        $Readme | Should -Not -Match 'Any device that can open'
    }
    It 'T79-11 README Alerts describes named PCs, the server itself, the disabled box and the 403; How it works has the 403 and viewer' {
        $Readme | Should -Match 'named PC'
        $Readme | Should -Match 'the server itself'
        $Readme | Should -Match 'is disabled'
        $Readme | Should -Match 'NamedPCs'
        $Readme | Should -Match '403'
        $Readme | Should -Match '"error":"not a named PC"'
        $Readme | Should -Match '`viewer`'
    }
    It 'T79-11 the changelog''s Unreleased Changed section tells the owner to add NamedPCs before installing' {
        $Unreleased | Should -Match '(?s)### Changed.*#79.*add `NamedPCs` to the live config before\s+installing'
    }
    It 'T79-11 the new files hold no private details (no drive paths, share or host names)' {
        foreach ($p in 'docs\uat\79-named-maintenance.md', 'tests\NamedMaintenance.Tests.ps1', 'tests\js\viewer.test.js') {
            (Get-Content -Raw (Join-Path $Root $p)) | Should -Not -Match '(?i)\b[A-Z]:\\(?!\.)|\\\\[a-z0-9]+\\'
        }
    }
}