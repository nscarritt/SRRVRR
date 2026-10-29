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
    It 'T48-55 a missing module stops the sampler with a plain error in /stats, not a page stuck on Starting' {
        $port = Get-FreePort
        $folder = New-Build 'HEAD' $port
        Remove-Item (Join-Path $folder 'modules\Counters.psm1')
        $p = Start-Process $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$folder\SRRVRR.ps1`"" -WindowStyle Minimized -PassThru
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(90); $s = $null
            while ([DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 500
                try { $s = (Invoke-TestRequest -Url "http://localhost:$port/stats").Body | ConvertFrom-Json; if ($s.error) { break } } catch { $null = $_ }
            }
            $s.error | Should -Match 'Counters\.psm1'
            $s.ready | Should -BeFalse
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
