# Smoke tests on real test builds started unelevated from their own folders (tag Smoke: tools\Invoke-Checks.ps1 -Smoke).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    $script:Root = Get-RepoRoot
    $script:Exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    function New-Build([string]$Ref, [int]$Port) {
        $dest = Join-Path (New-TestDataPath) 'copy'
        $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', $Ref, '-Destination', $dest, '-Port', "$Port")
        if ($r.ExitCode -ne 0) { throw "New-TestBuild failed: $($r.Output)" }
        $dest
    }
    # Starts a copy the way Start SRRVRR.bat does, without administrator; waits until /stats says ready.
    function Start-Build([string]$Folder, [int]$Port, [hashtable]$Environment = @{}) {
        $saved = @{}
        foreach ($k in $Environment.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
        try {
            $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Folder\SRRVRR.ps1`"" -WindowStyle Minimized -PassThru
        } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            try { $s = Invoke-TestRequest -Url "http://localhost:$Port/stats"; if ($s.Status -eq 200 -and ($s.Body | ConvertFrom-Json).ready) { return $p } } catch { $null = $_ }
            if ($p.HasExited) { throw "the copy exited early with code $($p.ExitCode)" }
        }
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        throw 'the copy never became ready'
    }
    function Stop-Build($Process) { if ($Process) { Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue } }
}

Describe 'Test builds' -Tag 'Smoke' {
    BeforeAll {
        # An elevated test copy shares the live copy's firewall rule and network trace until #48 gives each copy its own.
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated -and -not $env:GITHUB_ACTIONS) { throw 'Run the smoke tests without administrator: an elevated test copy would change the live SRRVRR''s firewall rule.' }
    }
    It 'T48-55 a module the sampler can''t load stops SRRVRR with a crash code, and the log says which' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        # Main loads Counters too, so break only the copy the sampler loads: an unreadable file would stop both.
        [IO.File]::WriteAllText((Join-Path $folder 'modules\Counters.psm1'), "function Invoke-FastTick { }`r`nthrow 'broken module'")
        $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Minimized -PassThru
        $null = $p.Handle
        try {
            $p.WaitForExit(90000) | Should -BeTrue
            $p.ExitCode | Should -Not -Be 0
            $log = (Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            $log | Should -Match 'broken module|Counters\.psm1'
            $log | Should -Match 'stopped: (crash|refused).*\(exit [13]\)'
        } finally { Stop-Build $p }
    }
    It 'T48-25 a settings error exits 2 with one plain line, a log line and the stopped line' {
        foreach ($bad in "@{ ValheimPort = 0 }", "@{ FirewallScope = 'Open' }", "@{ ValheimPort = ", "@{ LogRetentionDays = 3 }") {
            $port = Get-FreePort
            $folder = New-Build 'HEAD' $port
            [IO.File]::WriteAllText((Join-Path $folder 'SRRVRR.config.psd1'), $bad)
            $out = Join-Path $folder 'console.txt'
            $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError (Join-Path $folder 'err.txt')
            $null = $p.Handle
            $p.WaitForExit(60000) | Should -BeTrue
            $p.ExitCode | Should -Be 2 -Because $bad
            @(Get-Content $out | Where-Object { $_ -match '^SRRVRR stopped:' }).Count | Should -Be 1
            [IO.File]::ReadAllText((Join-Path $folder 'err.txt')) | Should -Not -Match 'CategoryInfo'
            $lines = @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)
            $lines[-1] | Should -Match 'stopped: settings error \(exit 2\)$'
        }
    }
    It 'T48-56 a crash exits 1, with the exception''s type, message, line and stack in the log' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        # Take every address SRRVRR could listen on (elevated, it tries http://+ first and falls back to localhost).
        $taken = New-Object Net.HttpListener; $taken.Prefixes.Add("http://localhost:$port/")
        if ($elevated) { $taken.Prefixes.Add("http://+:$port/") }
        $taken.Start()
        try {
            $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru
            $null = $p.Handle
            $p.WaitForExit(90000) | Should -BeTrue
            $p.ExitCode | Should -Be 1
            $lines = @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)
            ($lines -join "`n") | Should -Match 'ERROR srrvrr: System\.[\w.]+Exception: .+ \| at SRRVRR\.ps1:\d+ \| stack: '
            $lines[-1] | Should -Match 'stopped: crash: System\.[\w.]+ \(exit 1\)$'
        } finally { $taken.Stop(); $taken.Close() }
    }
    It 'T48-17 a second copy pointed at a running copy''s data folder exits 3, and the first keeps running' {
        $data = Join-Path (New-TestDataPath) 'shared-data'
        New-Item -ItemType Directory $data | Out-Null
        $portA = Get-FreePort; $portB = Get-FreePort
        $a = Join-Path (New-TestDataPath) 'a'; $b = Join-Path (New-TestDataPath) 'b'
        foreach ($x in @(@($a, $portA), @($b, $portB))) {
            $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $x[0], '-Port', "$($x[1])", '-DataPath', $data)
            if ($r.ExitCode -ne 0) { throw $r.Output }
        }
        $pa = Start-Build $a $portA
        try {
            $pb = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$b\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru
            $null = $pb.Handle
            $pb.WaitForExit(90000) | Should -BeTrue
            $pb.ExitCode | Should -Be 3
            (Invoke-TestRequest -Url "http://localhost:$portA/stats").Status | Should -Be 200
            $last = @(Get-ChildItem (Join-Path $b 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1]
            $last | Should -Match 'stopped: refused: another SRRVRR is using the data folder .* \(exit 3\)$'
        } finally { Stop-Build $pa }
    }
    It 'T48-52 Stop SRRVRR.bat stops the copy cleanly: marker, exit 0 within 10 s, "stopped: requested"' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        $null = $p.Handle
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & cmd /c "`"$folder\Stop SRRVRR.bat`"" | Out-Null
        $LASTEXITCODE | Should -Be 0
        $p.WaitForExit(10000) | Should -BeTrue
        $p.ExitCode | Should -Be 0
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
        Test-Path (Join-Path $folder 'state\stop-requested') | Should -BeTrue
        @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1] | Should -Match 'INFO srrvrr: stopped: requested \(exit 0\)$'
    }
    It 'T50-53 a start and a -Stop log "started" and "stopped" (requested) as events, and the crash log ends "stopped: requested (exit 0)"' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        $null = $p.Handle
        Start-Sleep -Seconds 2   # the drain runs once a second
        & cmd /c "`"$folder\Stop SRRVRR.bat`"" | Out-Null
        $p.WaitForExit(10000) | Should -BeTrue
        $events = @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'events-*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
        @($events | ForEach-Object type) | Should -Contain 'started'
        $stopped = @($events | Where-Object type -eq 'stopped')
        $stopped.Count | Should -Be 1
        $stopped[0].data.reason | Should -Be 'requested'
        $events[-1].type | Should -Be 'stopped'
        @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1] | Should -Match 'INFO srrvrr: stopped: requested \(exit 0\)$'
    }
    It 'T50-52 Maintenance turned on stays on across a restart, with the same untilMs' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        try {
            $headers = @{ Origin = "http://localhost:$port"; 'X-SRRVRR' = '1' }
            $r = Invoke-WebRequest -Uri "http://localhost:$port/maintenance" -Method Post -Headers $headers -ContentType 'application/json' -Body '{"on":true}' -UseBasicParsing
            $r.StatusCode | Should -Be 200
            $until = ($r.Content | ConvertFrom-Json).untilMs
            $until | Should -BeGreaterThan 0
            & cmd /c "`"$folder\Stop SRRVRR.bat`"" | Out-Null
            $p.WaitForExit(10000) | Should -BeTrue
            $p = Start-Build $folder $port
            $doc = (Invoke-TestRequest -Url "http://localhost:$port/stats").Body | ConvertFrom-Json
            $doc.maintenance.on | Should -BeTrue
            $doc.maintenance.untilMs | Should -Be $until
        } finally { Stop-Build $p }
    }
    It 'T48-53 one copy''s -Stop never stops another copy' {
        $pa = Get-FreePort; $pb = Get-FreePort
        $a = New-Build 'HEAD' $pa; $b = New-Build 'HEAD' $pb
        $procA = Start-Build $a $pa; $procB = Start-Build $b $pb
        try {
            $null = $procA.Handle
            & $Exe -NoProfile -ExecutionPolicy Bypass -File "$a\SRRVRR.ps1" -Stop | Out-Null
            $procA.WaitForExit(10000) | Should -BeTrue
            (Invoke-TestRequest -Url "http://localhost:$pb/stats").Status | Should -Be 200
            Test-Path (Join-Path $b 'state\stop-requested') | Should -BeFalse
        } finally { Stop-Build $procA; Stop-Build $procB }
    }
    It 'T48-54 a stop sent during the startup takes effect at the next step' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        Import-Module (Join-Path $Root 'modules\Control.psm1') -Force
        $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru
        $null = $p.Handle
        $name = Get-StopEventName -Folder $folder -Elevated $elevated
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Send-StopSignal -Name $name) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        $p.WaitForExit(30000) | Should -BeTrue
        $p.ExitCode | Should -Be 0
        $lines = @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)
        $lines[-1] | Should -Match 'stopped: requested \(exit 0\)$'
        ($lines -join "`n") | Should -Not -Match 'serving at'
    }
    It 'T48-57 Ctrl+C is a clean stop: exit 0 and "stopped: Ctrl+C"' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        $null = $p.Handle
        $sender = Join-Path (New-TestDataPath) 'send-ctrlc.ps1'
        Copy-Item (Join-Path $PSScriptRoot 'fakes\Send-CtrlC.ps1') $sender
        $s = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$sender`" -TargetId $($p.Id)" -WindowStyle Hidden -PassThru
        $s.WaitForExit(20000) | Out-Null
        $p.WaitForExit(15000) | Should -BeTrue
        $p.ExitCode | Should -Be 0
        @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1] | Should -Match 'stopped: Ctrl\+C \(exit 0\)$'
    }
    It 'T48-58 a forced kill leaves a crash-looking exit code, no "stopped:" line and no marker' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        $null = $p.Handle
        Stop-Process -Id $p.Id -Force
        $p.WaitForExit(10000) | Should -BeTrue
        $p.ExitCode | Should -Not -BeIn @(0, 2, 3)
        @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1] | Should -Not -Match 'stopped:'
        Test-Path (Join-Path $folder 'state\stop-requested') | Should -BeFalse
    }
    It 'T48-36 a stop event name someone else took first refuses the start (exit 3)' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        Import-Module (Join-Path $Root 'modules\Control.psm1') -Force
        $open = New-Object System.Security.AccessControl.EventWaitHandleSecurity
        $open.AddAccessRule((New-Object System.Security.AccessControl.EventWaitHandleAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'), 'FullControl', 'Allow')))
        $made = $false
        $squat = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', (Get-StopEventName -Folder $folder -Elevated $elevated), [ref]$made, $open)
        try {
            $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru
            $null = $p.Handle
            $p.WaitForExit(60000) | Should -BeTrue
            $p.ExitCode | Should -Be 3
            @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content)[-1] | Should -Match 'stopped: refused: The stop event name .* \(exit 3\)$'
        } finally { $squat.Dispose() }
    }
    It 'T49-23 the history survives a clean restart, with a gap for the time it was stopped' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        Start-Sleep -Seconds 20
        $null = Invoke-InChildPowerShell -File (Join-Path $folder 'SRRVRR.ps1') -Arguments @('-Stop')
        $p.WaitForExit(30000) | Should -BeTrue
        Test-Path (Join-Path $folder 'state\history.json') | Should -BeTrue
        Start-Sleep -Seconds 10
        $p = Start-Build $folder $port
        try {
            $cpu = @(((Invoke-TestRequest -Url "http://localhost:$port/history").Body | ConvertFrom-Json).lines.cpu)
            $kinds = (($cpu | ForEach-Object { if ($null -eq $_) { 'g' } else { 'd' } }) -join '') -replace '(.)\1*', '$1'
            $kinds | Should -Match 'dgd?$' -Because 'the earlier readings, then a gap, then (soon) new readings'
            @($cpu | Where-Object { $null -ne $_ }).Count | Should -BeGreaterThan 10
        } finally { Stop-Build $p }
    }
    It 'T49-24 a damaged history.json is renamed .bad, logged once, and the copy serves' {
        $port = Get-FreePort; $folder = New-Build 'HEAD' $port
        New-Item -ItemType Directory -Force (Join-Path $folder 'state') | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'state\history.json'), '{"version":1,"newe')
        $p = Start-Build $folder $port
        try {
            Test-Path (Join-Path $folder 'state\history.json.bad') | Should -BeTrue
            (Invoke-TestRequest -Url "http://localhost:$port/history").Status | Should -Be 200
            @(Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content | Select-String 'ERROR history: history.json not used \(damaged\)').Count | Should -Be 1
        } finally { Stop-Build $p }
    }
    It 'T48-21 the log holds the settings source, every startup step in order and the serving line' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        try {
            $text = (Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            $text | Should -Match 'INFO startup: Settings loaded from .*SRRVRR\.config\.psd1'
            $steps = @([regex]::Matches($text, 'INFO startup: \[(\d+)/(\d+)\]') | ForEach-Object { [int]$_.Groups[1].Value })
            $steps | Should -Be (1..$steps.Count)
            $text | Should -Match "INFO startup: serving at http://(localhost|$env:COMPUTERNAME):$port"   # elevated (as in CI) it serves by name
        } finally { Stop-Build $p }
    }
    It 'T47-18 v0.6.0 and HEAD side by side: the same /stats shape apart from tickMs and #50''s event fields, and the same headers' {
        $oldPort = Get-FreePort; $newPort = Get-FreePort
        $old = Start-Build (New-Build 'v0.6.0' $oldPort) $oldPort
        try {
            $new = Start-Build (New-Build 'HEAD' $newPort) $newPort
            try {
                Start-Sleep -Seconds 12   # both have read Plex, Valheim and the drives at least once
                $a = Invoke-TestRequest -Url "http://localhost:$oldPort/stats"; $b = Invoke-TestRequest -Url "http://localhost:$newPort/stats"
                $pa = @(Get-JsonPaths ($a.Body | ConvertFrom-Json) | Where-Object { $_ -notmatch '^diskIO\.' } | Sort-Object -Unique)
                $pb = @(Get-JsonPaths ($b.Body | ConvertFrom-Json) | Where-Object { $_ -notmatch '^diskIO\.' } | Sort-Object -Unique)
                @($pa | Where-Object { $pb -notcontains $_ }) | Should -BeNullOrEmpty
                # Added on purpose: tickMs (#47), and the events, Maintenance and log retention (#50, T50-39), the version (#62), each drive's level (#65), and the host's name and role (#90).
                @($pb | Where-Object { $pa -notcontains $_ }) | Should -Be @('drives[].level', 'events', 'hostName', 'lastEventId', 'logRetentionDays', 'maintenance', 'maintenance.on', 'maintenance.untilMs', 'role', 'tickMs', 'version')
                foreach ($path in '/', '/stats') {
                    $x = Invoke-TestRequest -Url "http://localhost:$oldPort$path"; $y = Invoke-TestRequest -Url "http://localhost:$newPort$path"
                    $y.Headers['Content-Type'] | Should -Be $x.Headers['Content-Type']
                    $y.Headers['Cache-Control'] | Should -Be 'no-store'
                }
            } finally { Stop-Build $new }
        } finally { Stop-Build $old }
    }
    It 'T47-10 a decoy Counters module on PSModulePath is never loaded' {
        $decoy = Join-Path (New-TestDataPath) 'decoy'
        $canary = Join-Path $decoy 'loaded.txt'
        New-Item -ItemType Directory -Force (Join-Path $decoy 'Counters') | Out-Null
        [IO.File]::WriteAllText((Join-Path $decoy 'Counters\Counters.psm1'), "Set-Content -LiteralPath '$canary' 'loaded'`r`nfunction Invoke-FastTick { }")
        $port = Get-FreePort
        $p = Start-Build (New-Build 'HEAD' $port) $port -Environment @{ PSModulePath = "$decoy;$env:PSModulePath" }
        try {
            (Invoke-TestRequest -Url "http://localhost:$port/stats").Status | Should -Be 200
            Test-Path $canary | Should -BeFalse
        } finally { Stop-Build $p }
    }
    It 'T47-40 a build whose files carry the downloaded mark still loads every module' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        Get-ChildItem $folder -Recurse -File | ForEach-Object { Set-Content -LiteralPath $_.FullName -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" }
        $p = Start-Build $folder $port
        try {
            $s = (Invoke-TestRequest -Url "http://localhost:$port/stats").Body | ConvertFrom-Json
            $s.ready | Should -BeTrue
            $s.error | Should -BeNullOrEmpty
            (Invoke-TestRequest -Url "http://localhost:$port/app.js").Status | Should -Be 200
        } finally { Stop-Build $p }
    }
}

#region 90 Roles and the host name (#90)
Describe 'T90-07 to T90-09 roles on a test build' -Tag 'Smoke' {
    BeforeAll {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated -and -not $env:GITHUB_ACTIONS) { throw 'Run the smoke tests without administrator: an elevated test copy would change the live SRRVRR''s firewall rule.' }
        # A HEAD test build with these settings (Port is added).
        function New-RoleBuild([int]$Port, [string]$Settings = '') {
            $folder = New-Build 'HEAD' $Port
            [IO.File]::WriteAllText((Join-Path $folder 'SRRVRR.config.psd1'), "@{ Port = $Port; $Settings }")
            $folder
        }
        # Starts a copy with its console going to console.txt; waits until /stats says ready.
        function Start-LoggedBuild([string]$Folder, [int]$Port) {
            $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Folder\SRRVRR.ps1`"" -WindowStyle Hidden -PassThru `
                -RedirectStandardOutput (Join-Path $Folder 'console.txt') -RedirectStandardError (Join-Path $Folder 'console-err.txt')
            $null = $p.Handle
            $deadline = [DateTime]::UtcNow.AddSeconds(90)
            while ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 500
                try { $s = Invoke-TestRequest -Url "http://localhost:$Port/stats"; if ($s.Status -eq 200 -and ($s.Body | ConvertFrom-Json).ready) { return $p } } catch { $null = $_ }
                if ($p.HasExited) { throw "the copy exited early with code $($p.ExitCode)" }
            }
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            throw 'the copy never became ready'
        }
        # /stats once the slow sampler has finished its first pass (the drives, then the restart check, then Valheim
        # and Plex; the first drive health read can take over a minute unelevated).
        function Get-SettledStats([int]$Port) {
            $deadline = [DateTime]::UtcNow.AddSeconds(180)
            while ([DateTime]::UtcNow -lt $deadline) {
                $doc = (Invoke-TestRequest -Url "http://localhost:$Port/stats").Body | ConvertFrom-Json
                if ($doc.PSObject.Properties.Name -contains 'restartPending') { Start-Sleep -Seconds 6; return (Invoke-TestRequest -Url "http://localhost:$Port/stats").Body | ConvertFrom-Json }
                Start-Sleep -Seconds 2
            }
            throw 'the slow sampler never finished its first pass'
        }
        function Get-LogText([string]$Folder) { (Get-ChildItem (Join-Path $Folder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n" }
    }
    It 'T90-07 a Workstation runs no Processes readers and no tracer: no services, no activity, no Valheim, Plex or tracker lines' {
        $port = Get-FreePort
        $folder = New-RoleBuild $port "Role = 'Workstation'; Processes = @{ Valheim = `$true; Plex = `$true }"
        $p = Start-LoggedBuild $folder $port
        try {
            $doc = Get-SettledStats $port
            $doc.PSObject.Properties.Name | Should -Contain 'services'
            @($doc.services).Count | Should -Be 0
            $doc.PSObject.Properties.Name | Should -Not -Contain 'activity'
        } finally { Stop-Build $p; $null = $p.WaitForExit(10000) }
        $console = [IO.File]::ReadAllText((Join-Path $folder 'console.txt'))
        $log = Get-LogText $folder
        foreach ($text in @(@{ Name = 'console'; Text = $console }, @{ Name = 'log'; Text = $log })) {
            $lines = @($text.Text -split '\r?\n')
            $text.Text | Should -Match 'Per-program network tracking: not used on a workstation' -Because "the $($text.Name) says the tracer isn't used"
            $text.Text | Should -Match ([regex]::Escape('Role: Workstation. Off: Processes. On: video memory, top programs, AI server')) -Because "the $($text.Name) names the role"
            $text.Text | Should -Match ([regex]::Escape('Not used on a workstation: Processes, ValheimPort')) -Because "the $($text.Name) says the server-only settings are ignored"
            # The one line allowed to name them is the one saying they're not used.
            @($lines | Where-Object { $_ -match 'Valheim|Plex' -and $_ -notmatch 'Not used on a workstation: Processes, ValheimPort' }) | Should -BeNullOrEmpty -Because "the $($text.Name) has no Valheim or Plex reader lines"
            @($lines | Where-Object { $_ -match 'network tracking is (on|off)' }) | Should -BeNullOrEmpty -Because "the $($text.Name) shows the tracer never started"
        }
    }
    It 'T90-08 with no Role, /stats has v0.8.0''s key paths plus hostName and role only; hostName SRRVRR, role server' {
        $old = @((Get-Content -Raw (Join-Path $PSScriptRoot 'fixtures\stats\v0.8.0-shape.json') | ConvertFrom-Json).paths)
        # Keys that come and go with the machine, not the version (the fixture's source says which).
        $varies = '^(diskIO\.|activity\.|services\[\]\.|memSticks\[\]\.|(cpu|mem)Temps?$|gpuTemp$)'
        $port = Get-FreePort
        $p = Start-Build (New-RoleBuild $port) $port
        try {
            $doc = Get-SettledStats $port
            $new = @(Get-JsonPaths $doc | Sort-Object -Unique)
            @($old | Where-Object { $_ -notmatch $varies -and $new -notcontains $_ }) | Should -BeNullOrEmpty -Because 'every v0.8.0 key path stays'
            @($new | Where-Object { $_ -notmatch $varies -and $old -notcontains $_ }) | Should -Be @('hostName', 'role') -Because 'only hostName and role are new on the Server'
            foreach ($k in 'activity', 'services', 'memSticks') { $new | Should -Contain $k }
            $doc.hostName | Should -BeExactly 'SRRVRR'
            $doc.role | Should -BeExactly 'server'
        } finally { Stop-Build $p }
    }
    It 'T90-09 a Workstation named TEST-PC: hostName TEST-PC, role workstation, /history lines cpu to vramShared' {
        $port = Get-FreePort
        $p = Start-Build (New-RoleBuild $port "Role = 'Workstation'; DisplayName = 'TEST-PC'") $port
        try {
            $doc = (Invoke-TestRequest -Url "http://localhost:$port/stats").Body | ConvertFrom-Json
            $doc.hostName | Should -BeExactly 'TEST-PC'
            $doc.role | Should -BeExactly 'workstation'
            $history = (Invoke-TestRequest -Url "http://localhost:$port/history").Body | ConvertFrom-Json
            @($history.lines.PSObject.Properties.Name) | Should -BeExactly @('cpu', 'mem', 'gpu', 'rx', 'tx', 'vram', 'vramShared')
        } finally { Stop-Build $p }
    }
}
#endregion 90
#region 91
# Video memory and GPU detail on a Workstation test build (test plan 6.11). What it can check depends on the PC:
# a GPU (the CI runner has none) and nvidia-smi (NVIDIA cards only).
Describe 'T91 a Workstation test build' -Tag 'Smoke' {
    BeforeAll {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated -and -not $env:GITHUB_ACTIONS) { throw 'Run the smoke tests without administrator: an elevated test copy would change the live SRRVRR''s firewall rule.' }
        function Get-Stats([int]$Port) { (Invoke-TestRequest -Url "http://localhost:$Port/stats").Body | ConvertFrom-Json }
    }
    It 'T91-16 /stats has gpuMemTotal, gpuShared and gpuSpill; with nvidia-smi the detail fields and their log line; with a GPU the Video memory line' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        [IO.File]::WriteAllText((Join-Path $folder 'SRRVRR.config.psd1'), "@{`r`n    Port = $port`r`n    Role = 'Workstation'`r`n}`r`n")
        $p = Start-Build $folder $port
        try {
            $s = Get-Stats $port
            $names = @($s.PSObject.Properties.Name)
            foreach ($k in 'gpuMemTotal', 'gpuShared', 'gpuSpill') { $names | Should -Contain $k }
            $s.role | Should -Be 'workstation' -Because 'the build runs the Workstation role (#90)'
            $s.gpuSpill | Should -BeOfType [bool]
            $s.gpuShared | Should -BeGreaterOrEqual 0
            $log = (Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            if ($s.gpuLabel) {
                $s.gpuMemTotal | Should -BeGreaterThan 0 -Because 'it is the picked GPU''s dedicated size'
                $log | Should -Match ('INFO startup: Video memory: ' + [regex]::Escape($s.gpuLabel) + '.*, watching for spill \(95% full and 1 GB shared\)')
            } else {
                $s.gpuMemTotal | Should -Be 0 -Because 'no GPU was picked'
                $log | Should -Not -Match 'watching for spill'
            }
            if ($log -match 'INFO startup: Temperature from ') {   # SRRVRR found nvidia-smi for the picked card
                $log | Should -Match 'INFO startup: nvidia-smi detail fields: (clocks_event_reasons|clocks_throttle_reasons|none)'
                if ($log -notmatch 'nvidia-smi detail fields: none') {
                    $deadline = [DateTime]::UtcNow.AddSeconds(20)   # the slow sampler reads nvidia-smi every 5 s
                    while (@($s.PSObject.Properties.Name) -notcontains 'gpuPState' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 500; $s = Get-Stats $port }
                    $names = @($s.PSObject.Properties.Name)
                    foreach ($k in 'gpuPower', 'gpuPowerLimit', 'gpuClock', 'gpuClockMax', 'gpuFan', 'gpuPState', 'gpuLimits') { $names | Should -Contain $k }
                    $s.gpuPState | Should -Match '^P\d+$'
                }
            } else {
                $log | Should -Not -Match 'nvidia-smi detail fields:'
            }
        } finally { Stop-Build $p }
    }
}
#endregion 91
#region 92
Describe 'T92-12 memory detail and top programs on test builds' -Tag 'Smoke' {
    BeforeAll {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated -and -not $env:GITHUB_ACTIONS) { throw 'Run the smoke tests without administrator: an elevated test copy would change the live SRRVRR''s firewall rule.' }
        $script:Fields92 = @('memCommit', 'memCommitLimit', 'memPageIn', 'wsl', 'top')
        $script:CapLine = 'WSL VM: memory cap [\d.]+ GB \((from \.wslconfig|default: half of RAM)\)'
    }
    It 'T92-12 a Workstation build serves memCommit, memCommitLimit, memPageIn, wsl and top and logs the WSL VM cap; a Server build has none of them' {
        $wsPort = Get-FreePort; $ws = New-Build 'HEAD' $wsPort
        [IO.File]::WriteAllText((Join-Path $ws 'SRRVRR.config.psd1'), "# Test copy settings (T92-12).`r`n@{`r`n    Port = $wsPort`r`n    Role = 'Workstation'`r`n}`r`n")
        $svPort = Get-FreePort; $sv = New-Build 'HEAD' $svPort
        $pWs = $null; $pSv = $null
        try {
            $pWs = Start-Build $ws $wsPort
            $pSv = Start-Build $sv $svPort
            # The slow sampler fills these every 5 s, so top waits for its first pass.
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            do {
                Start-Sleep -Seconds 1
                $s = (Invoke-TestRequest -Url "http://localhost:$wsPort/stats").Body | ConvertFrom-Json
            } while (-not @($s.top | Where-Object { $_ }).Count -and [DateTime]::UtcNow -lt $deadline)
            $names = @($s.PSObject.Properties.Name)
            foreach ($k in $Fields92) { $names | Should -Contain $k -Because 'the Workstation''s /stats' }
            @($s.top).Count | Should -BeGreaterThan 0
            $s.memCommit | Should -BeGreaterThan 0
            $s.memCommitLimit | Should -BeGreaterThan 0
            foreach ($k in 'running', 'mem', 'cap', 'capSource') { @($s.wsl.PSObject.Properties.Name) | Should -Contain $k -Because 'wsl' }
            $wsLog = (Get-ChildItem (Join-Path $ws 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            $wsLog | Should -Match $CapLine
            $v = (Invoke-TestRequest -Url "http://localhost:$svPort/stats").Body | ConvertFrom-Json
            $svNames = @($v.PSObject.Properties.Name)
            foreach ($k in $Fields92) { $svNames | Should -Not -Contain $k -Because 'the Server''s /stats is unchanged' }
            $svLog = (Get-ChildItem (Join-Path $sv 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            $svLog | Should -Not -Match 'WSL VM: memory cap'
        } finally { Stop-Build $pWs; Stop-Build $pSv }
    }
}
#endregion 92
#region 93 The AI server on test builds (#93, test plan 6.13): the fake ComfyUI (tests\fakes\FakeComfyUi.psm1) on a
# random port, never the real AI server. These need #90's Role and #92's workstation tick under #93.
Describe 'T93 the AI server on test builds' -Tag 'Smoke' {
    BeforeAll {
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated -and -not $env:GITHUB_ACTIONS) { throw 'Run the smoke tests without administrator: an elevated test copy would change the live SRRVRR''s firewall rule.' }
        Import-Module (Join-Path $Root 'tests\fakes\FakeComfyUi.psm1') -Force
        $comfy = [IO.File]::ReadAllText((Join-Path $Root 'tests\fixtures\workstation\system_stats.json')) | ConvertFrom-Json
        $script:ComfyVersion = $comfy.system.comfyui_version
        $script:ComfyHolds = $comfy.devices[0].torch_vram_total
        function Write-BuildConfig([string]$Folder, [string[]]$Lines) {
            [IO.File]::WriteAllText((Join-Path $Folder 'SRRVRR.config.psd1'), "@{`r`n" + (($Lines | ForEach-Object { "    $_" }) -join "`r`n") + "`r`n}`r`n")
        }
        function Get-LogText([string]$DataFolder) { (Get-ChildItem (Join-Path $DataFolder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n" }
        function Get-Stats([int]$Port) { (Invoke-TestRequest -Url "http://localhost:$Port/stats").Body | ConvertFrom-Json }
        function Get-AiRow([int]$Port, [string]$Name) { @((Get-Stats $Port).ai) | Where-Object { $_ -and $_.name -eq $Name } | Select-Object -First 1 }
        # Polls /stats until entry Name is in State; throws with the last state seen.
        function Wait-AiState([int]$Port, [string]$Name, [string]$State, [int]$TimeoutSeconds) {
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
            $last = '(no ai row)'
            while ([DateTime]::UtcNow -lt $deadline) {
                try { $row = Get-AiRow $Port $Name; if ($row) { $last = $row.state; if ($row.state -eq $State) { return $row } } } catch { $last = $_.Exception.Message }
                Start-Sleep -Milliseconds 500
            }
            throw "'$Name' never reached '$State' within $TimeoutSeconds s; last seen: $last"
        }
    }

    It 'T93-02 a Server test build with a ComfyUi entry logs that it is ignored, never asks the AI server, and has no ai in /stats' {
        $fake = Start-FakeComfyUi -Mode answer
        $p = $null
        try {
            $port = Get-FreePort
            $folder = New-Build 'HEAD' $port
            Write-BuildConfig $folder @("Port = $port", "ComfyUi = @(@{ Name = 'Main'; Port = $($fake.Port) })")
            $p = Start-Build $folder $port
            Start-Sleep -Seconds 7   # past the slow sampler's first passes, so any reader would have asked by now
            $stats = Get-Stats $port
            @($stats.PSObject.Properties.Name) | Should -Not -Contain 'ai'
            Get-LogText $folder | Should -Match ('(?m) (INFO|WARN) startup: ' + [regex]::Escape('ComfyUi is used only on a workstation; ignored.') + '$')
            @($fake.Requests).Count | Should -Be 0 -Because 'the Server role never reads the AI server'
        } finally { Stop-Build $p; & $fake.Stop }
    }

    Context 'a Workstation test build with Main on the fake and Second on a closed port' {
        BeforeAll {
            $script:Fake = Start-FakeComfyUi -Mode answer -Queue 0
            $script:ClosedPort = Get-FreePort
            $script:WsPort = Get-FreePort
            $script:WsData = Join-Path (New-TestDataPath) 'data'
            New-Item -ItemType Directory $WsData | Out-Null
            $script:WsFolder = Join-Path (New-TestDataPath) 'copy'
            $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $WsFolder, '-Port', "$WsPort", '-DataPath', $WsData)
            if ($r.ExitCode -ne 0) { throw "New-TestBuild failed: $($r.Output)" }
            Write-BuildConfig $WsFolder @("Port = $WsPort", "DataPath = '$($WsData.Replace("'", "''"))'", "Role = 'Workstation'",
                "ComfyUi = @(@{ Name = 'Main'; Port = $($Fake.Port) }, @{ Name = 'Second'; Port = $ClosedPort })")
            $script:WsProcess = Start-Build $WsFolder $WsPort
        }
        AfterAll {
            Stop-Build $WsProcess
            if ($Fake) { & $Fake.Stop }
        }

        It 'T93-17 the startup log has the probe line of each entry: answering (ComfyUI and its version) and not answering (off or starting)' {
            $log = Get-LogText $WsData
            $log | Should -Match ('(?m) (INFO|WARN) startup: ' + [regex]::Escape("AI server 'Main': ComfyUI on 127.0.0.1:$($Fake.Port), answering (ComfyUI $ComfyVersion)") + '$')
            $log | Should -Match ('(?m) (INFO|WARN) startup: ' + [regex]::Escape("AI server 'Second': ComfyUI on 127.0.0.1:$ClosedPort, not answering (off or starting)") + '$')
        }

        It 'T93-14 idle, working at queue 1, idle at 0, not-answering within 30 s of the fake stopping; only the two GETs; no CANARY anywhere' {
            $row = Wait-AiState $WsPort 'Main' 'idle' 30
            $row.queue | Should -Be 0
            $row.holds | Should -Be $ComfyHolds
            $row.version | Should -BeExactly $ComfyVersion
            (Get-AiRow $WsPort 'Second').state | Should -BeIn @('off', 'starting') -Because 'Second has never answered'
            & $Fake.SetQueue 1
            (Wait-AiState $WsPort 'Main' 'working' 20).queue | Should -Be 1
            & $Fake.SetQueue 0
            $null = Wait-AiState $WsPort 'Main' 'idle' 20
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & $Fake.Stop
            $null = Wait-AiState $WsPort 'Main' 'not-answering' 40
            $sw.Elapsed.TotalSeconds | Should -BeLessOrEqual 30 -Because 'three missed passes, 5 s apart, each up to about 2 s for Windows to give up on the closed port (no VM on the runner, so the miss rule)'
            # The boundary, end to end: every request the fake saw was a plain GET of one of the two paths.
            $seen = @($Fake.Requests)
            @($seen | Where-Object { $_.Line -ceq 'GET /prompt HTTP/1.1' }).Count | Should -BeGreaterThan 0
            $odd = @($seen | Where-Object {
                $_.Line -cnotmatch '^GET /(system_stats|prompt) HTTP/1\.1$' -or $_.Host -cne "127.0.0.1:$($Fake.Port)" -or $_.ContentLength -or $_.TransferEncoding -or $_.BodyBytes -ne 0
            } | ForEach-Object { "$($_.Line) [Host $($_.Host)]" })
            $odd | Should -BeNullOrEmpty
            # Nothing the reader drops reaches /stats, the logs or any file under DataPath (after a clean stop, so every file is written and closed).
            (Invoke-TestRequest -Url "http://localhost:$WsPort/stats").Body | Should -Not -Match 'CANARY'
            $null = $WsProcess.Handle
            & cmd /c "`"$WsFolder\Stop SRRVRR.bat`"" | Out-Null
            $WsProcess.WaitForExit(15000) | Should -BeTrue
            $files = @(Get-ChildItem $WsData -Recurse -File)
            $files.Count | Should -BeGreaterThan 0
            @($files | Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'CANARY' } | ForEach-Object { $_.FullName }) | Should -BeNullOrEmpty
        }
    }

    Context 'a Workstation test build whose AI server stops answering during a job' {
        BeforeAll {
            $script:JobFake = Start-FakeComfyUi -Mode answer -Queue 1
            $script:JobPort = Get-FreePort
            $script:JobData = Join-Path (New-TestDataPath) 'data'
            New-Item -ItemType Directory $JobData | Out-Null
            $script:JobFolder = Join-Path (New-TestDataPath) 'copy'
            $r = Invoke-InChildPowerShell -File (Join-Path $Root 'tools\New-TestBuild.ps1') -Arguments @('-Ref', 'HEAD', '-Destination', $JobFolder, '-Port', "$JobPort", '-DataPath', $JobData)
            if ($r.ExitCode -ne 0) { throw "New-TestBuild failed: $($r.Output)" }
            Write-BuildConfig $JobFolder @("Port = $JobPort", "DataPath = '$($JobData.Replace("'", "''"))'", "Role = 'Workstation'",
                "ComfyUi = @(@{ Name = 'Main'; Port = $($JobFake.Port) })")
            $script:JobProcess = Start-Build $JobFolder $JobPort
        }
        AfterAll {
            Stop-Build $JobProcess
            if ($JobFake) { & $JobFake.Stop }
        }

        It 'T93-11 working, then the fake stops: not-answering, and one ai-stopped-answering event reaches /stats events and the event log' {
            $null = Wait-AiState $JobPort 'Main' 'working' 30
            # A page asks for events with ?since=<the last id it has seen>; the first request gets none.
            $since = (Get-Stats $JobPort).lastEventId
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & $JobFake.Stop
            $null = Wait-AiState $JobPort 'Main' 'not-answering' 40
            $rowSeconds = $sw.Elapsed.TotalSeconds
            $event = $null
            while (-not $event -and $sw.Elapsed.TotalSeconds -lt 60) {
                $event = @((Invoke-TestRequest -Url "http://localhost:$JobPort/stats?since=$since").Body | ConvertFrom-Json | ForEach-Object events) | Where-Object { $_ -and $_.type -eq 'ai-stopped-answering' } | Select-Object -First 1
                if (-not $event) { Start-Sleep -Milliseconds 250 }
            }
            Write-Host ("not-answering row after {0:N1} s; event in /stats after {1:N1} s" -f $rowSeconds, $sw.Elapsed.TotalSeconds)
            $event | Should -Not -BeNullOrEmpty -Because 'working to not-answering raises ai-stopped-answering'
            $event.data.name | Should -BeExactly 'Main'
            $event.banner | Should -BeTrue
            $event.logged | Should -BeTrue
            @(((Invoke-TestRequest -Url "http://localhost:$JobPort/stats?since=$since").Body | ConvertFrom-Json).events | Where-Object { $_.type -eq 'ai-stopped-answering' }).Count | Should -Be 1
            $logged = @(Get-ChildItem (Join-Path $JobData 'logs') -Filter 'events-*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object type -eq 'ai-stopped-answering')
            $logged.Count | Should -Be 1
        }
    }
}
#endregion 93
