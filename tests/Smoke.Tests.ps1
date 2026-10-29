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
        $taken = New-Object Net.HttpListener; $taken.Prefixes.Add("http://localhost:$port/"); $taken.Start()
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
    It 'T48-21 the log holds the settings source, every startup step in order and the serving line' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        $p = Start-Build $folder $port
        try {
            $text = (Get-ChildItem (Join-Path $folder 'logs') -Filter 'srrvrr-*.log' | Get-Content) -join "`n"
            $text | Should -Match 'INFO startup: Settings loaded from .*SRRVRR\.config\.psd1'
            $steps = @([regex]::Matches($text, 'INFO startup: \[(\d+)/(\d+)\]') | ForEach-Object { [int]$_.Groups[1].Value })
            $steps | Should -Be (1..$steps.Count)
            $text | Should -Match "INFO startup: serving at http://localhost:$port"
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
