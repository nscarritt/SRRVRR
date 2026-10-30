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
    It 'T47-18 v0.6.0 and HEAD side by side: the same /stats shape apart from tickMs, and the same headers' {
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
                @($pb | Where-Object { $pa -notcontains $_ }) | Should -Be @('tickMs')
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
