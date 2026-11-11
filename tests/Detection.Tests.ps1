# modules\Events.psm1: events decided on the server from one state to the next (spec section 4, the starting set).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    # Canary names: they may reach banners, never a log.
    $script:Canaries = @('CanaryVikingQx', 'CanaryShieldZq', 'CanaryUserWv', 'CanaryTvKj', 'CanaryFilmYp')
    function New-Valheim([int]$Players, [string[]]$Names = @()) { @{ activity = @{ Valheim = @{ players = $Players; maxPlayers = 10; replyMs = 20; names = @($Names | ForEach-Object { @{ name = $_; minutes = 3 } }) } } } }
    function New-Stream([string]$Key, [string]$Playback = 'direct play') {
        @{ key = $Key; user = 'CanaryUserWv'; title = 'CanaryFilmYp'; device = 'CanaryTvKj'; app = 'Plex for Roku'; playback = $Playback; source = '1080'; target = ''; hardware = $false; kbps = 8000; transcoding = $false }
    }
    function New-Plex([object[]]$Items) { @{ activity = @{ Plex = @{ streams = @($Items).Count; transcoding = 0; items = @($Items) } } } }
    function New-Services([bool]$Valheim, [bool]$Plex) { @{ services = @(@{ name = 'Valheim'; online = $Valheim }, @{ name = 'Plex'; online = $Plex }) } }
    function New-Drive([string]$Letter, [string]$Health) { @{ letter = $Letter; health = $Health; label = 'Data' } }
    function Get-Types($Old, $New) { @(Get-StateEvents -Old $Old -New $New | ForEach-Object type) }
}

Describe 'T50-07 Valheim players' {
    It 'T50-07 a join and a leave are info, bannered, not logged, with names in memory only' {
        $join = @(Get-StateEvents -Old (New-Valheim 1 'CanaryVikingQx') -New (New-Valheim 2 'CanaryVikingQx', 'CanaryShieldZq'))
        $join.Count | Should -Be 1
        $join[0].type | Should -Be 'player-join'
        $join[0].severity | Should -Be 'info'
        $join[0].banner | Should -BeTrue
        $join[0].logged | Should -BeFalse
        $join[0].data.who | Should -Be @('CanaryShieldZq')
        $join[0].data.players | Should -Be 2
        $join[0].data.change | Should -Be 1
        $leave = @(Get-StateEvents -Old (New-Valheim 2 'CanaryVikingQx', 'CanaryShieldZq') -New (New-Valheim 1 'CanaryVikingQx'))
        $leave[0].type | Should -Be 'player-leave'
        $leave[0].data.who | Should -Be @('CanaryShieldZq')
        (ConvertTo-LoggedEvent $leave[0] | ConvertTo-Json -Depth 5) | Should -Not -Match 'Canary'
    }
    It 'T50-07 nothing on the first observation or when the count is unchanged' {
        Get-Types $null (New-Valheim 3) | Should -BeNullOrEmpty
        Get-Types @{} (New-Valheim 3) | Should -BeNullOrEmpty
        Get-Types (New-Valheim 2 'a', 'b') (New-Valheim 2 'a', 'b') | Should -BeNullOrEmpty
    }
}

Describe 'T50-08 Plex streams' {
    # Plex stream alerts were turned off in #57 (a banner for every short episode was constant): a new stream, a pause
    # and a resume raise nothing. Plex going offline or not answering still does (T50-09, T50-10).
    It 'T50-08 a new stream, a pause and a resume raise no event' {
        Get-Types (New-Plex @()) (New-Plex @()) | Should -BeNullOrEmpty
        Get-Types (New-Plex @()) (New-Plex @(New-Stream 's1')) | Should -BeNullOrEmpty
        Get-Types (New-Plex @(New-Stream 's1')) (New-Plex @(New-Stream 's1' 'direct stream')) | Should -BeNullOrEmpty
        Get-Types $null (New-Plex @(New-Stream 's1')) | Should -BeNullOrEmpty
        Get-Types @{ activity = @{} } (New-Plex @(New-Stream 's1')) | Should -BeNullOrEmpty
    }
}

Describe 'T50-09 Valheim and Plex offline and back' {
    It 'T50-09 warn events, bannered and logged, both ways, for each service' {
        $off = @(Get-StateEvents -Old (New-Services $true $true) -New (New-Services $false $true))
        $off[0].type | Should -Be 'service-offline'
        $off[0].severity | Should -Be 'warn'
        $off[0].banner | Should -BeTrue
        $off[0].logged | Should -BeTrue
        $off[0].data.name | Should -Be 'Valheim'
        $back = @(Get-StateEvents -Old (New-Services $false $true) -New (New-Services $true $true))
        $back[0].type | Should -Be 'service-back'
        (@(Get-StateEvents -Old (New-Services $true $true) -New (New-Services $true $false)))[0].data.name | Should -Be 'Plex'
        Get-Types (New-Services $true $true) (New-Services $true $true) | Should -BeNullOrEmpty
    }
}

Describe 'T50-10 a status query stops answering' {
    It 'T50-10 Valheim answering, then an alert error, then answering: stopped, then back; Plex didn''t answer too' {
        $err = @{ activity = @{ Valheim = @{ error = 'stopped answering the status query'; alert = $true } } }
        $stop = @(Get-StateEvents -Old (New-Valheim 1) -New $err)
        $stop.Count | Should -Be 1
        $stop[0].type | Should -Be 'query-stopped'
        $stop[0].severity | Should -Be 'warn'
        $stop[0].logged | Should -BeTrue
        $stop[0].data.name | Should -Be 'Valheim'
        (@(Get-StateEvents -Old $err -New (New-Valheim 1)))[0].type | Should -Be 'query-back'
        $plexErr = @{ activity = @{ Plex = @{ error = "Plex didn't answer"; alert = $true } } }
        (@(Get-StateEvents -Old (New-Plex @()) -New $plexErr))[0].data.name | Should -Be 'Plex'
    }
    It 'T50-10 an error with no alert (the query is off, no token yet) raises nothing' {
        $off = @{ activity = @{ Valheim = @{ error = 'status query off' } } }
        Get-Types (New-Valheim 1) $off | Should -BeNullOrEmpty
        Get-Types $off (New-Valheim 1) | Should -BeNullOrEmpty
    }
}

Describe 'T50-11 Windows waiting to restart' {
    It 'T50-11 false to true is one info event, not bannered, logged; true to true is nothing' {
        $e = @(Get-StateEvents -Old @{ restartPending = $false } -New @{ restartPending = $true; restartReason = 'Windows Update' })
        $e.Count | Should -Be 1
        $e[0].type | Should -Be 'restart-pending'
        $e[0].severity | Should -Be 'info'
        $e[0].banner | Should -BeFalse
        $e[0].logged | Should -BeTrue
        $e[0].data.reason | Should -Be 'Windows Update'
        Get-Types @{ restartPending = $true } @{ restartPending = $true } | Should -BeNullOrEmpty
    }
    It 'T50-11 not read yet ($null, before the slow sampler''s first check) to true is a first observation: nothing' {
        Get-Types @{ restartPending = $null } @{ restartPending = $true } | Should -BeNullOrEmpty
    }
}

Describe 'T50-12 drive health' {
    It 'T50-12 a health change and the data drive going missing are flags; Unknown to Unknown and a new drive are not' {
        $e = @(Get-StateEvents -Old @{ drives = @(New-Drive 'C:' 'Healthy') } -New @{ drives = @(New-Drive 'C:' 'Warning') })
        $e[0].type | Should -Be 'drive-health'
        $e[0].severity | Should -Be 'flag'
        $e[0].banner | Should -BeTrue
        $e[0].logged | Should -BeTrue
        $e[0].data.letter | Should -Be 'C:'
        $e[0].data.health | Should -Be 'Warning'
        $e[0].data.was | Should -Be 'Healthy'
        (@(Get-StateEvents -Old @{ drives = @(New-Drive 'H:' 'Healthy') } -New @{ drives = @(New-Drive 'H:' 'Missing') }))[0].type | Should -Be 'data-drive-missing'
        Get-Types @{ drives = @(New-Drive 'C:' 'Unknown') } @{ drives = @(New-Drive 'C:' 'Unknown') } | Should -BeNullOrEmpty
        Get-Types @{ drives = @(New-Drive 'C:' 'Healthy') } @{ drives = @((New-Drive 'C:' 'Healthy'), (New-Drive 'E:' 'Healthy')) } | Should -BeNullOrEmpty
    }
}

Describe 'T50-13 the data folder' {
    It 'T50-13 the fallback and a share found on the data folder are flags, bannered and logged' {
        foreach ($t in 'data-fallback', 'share-found') {
            $e = New-TypedEvent -Type $t -Data @{ reason = 'test' }
            $e.severity | Should -Be 'flag'
            $e.banner | Should -BeTrue
            $e.logged | Should -BeTrue
        }
    }
}

Describe 'T50-14 history saves, sampler errors and workers' {
    It 'T50-14 a failed history save is bannered; sampler errors and a stopped worker are status-line only; all logged' {
        $h = New-TypedEvent -Type 'history-save-failed' -Data @{ error = 'disk full' }
        $h.severity | Should -Be 'warn'; $h.banner | Should -BeTrue; $h.logged | Should -BeTrue
        foreach ($t in 'sampler-error', 'worker-stopped') {
            $e = New-TypedEvent -Type $t -Data @{ error = 'x' }
            $e.severity | Should -Be 'warn'; $e.banner | Should -BeFalse; $e.logged | Should -BeTrue
        }
    }
}

Describe 'T50-15 Maintenance, start and stop' {
    It 'T50-15 info, not bannered, logged, with the reason' {
        foreach ($t in 'maintenance-on', 'maintenance-off', 'started', 'stopped') {
            $e = New-TypedEvent -Type $t -Data @{ reason = 'requested' }
            $e.severity | Should -Be 'info'; $e.banner | Should -BeFalse; $e.logged | Should -BeTrue
            $e.data.reason | Should -Be 'requested'
        }
    }
}

Describe 'T50-16 the spec''s table' {
    It 'T50-16 every event type the module defines matches the spec, and none is missing' {
        # Copied from the spec, section 4: type, severity, banner, logged (less Plex streams, turned off in #57).
        $spec = @{
            'player-join' = 'info', $true, $false; 'player-leave' = 'info', $true, $false
            'service-offline' = 'warn', $true, $true; 'service-back' = 'warn', $true, $true
            'query-stopped' = 'warn', $true, $true; 'query-back' = 'warn', $true, $true
            'restart-pending' = 'info', $false, $true
            'drive-health' = 'flag', $true, $true; 'data-drive-missing' = 'flag', $true, $true
            'data-fallback' = 'flag', $true, $true; 'share-found' = 'flag', $true, $true
            'history-save-failed' = 'warn', $true, $true
            'sampler-error' = 'warn', $false, $true; 'worker-stopped' = 'warn', $false, $true
            'maintenance-on' = 'info', $false, $true; 'maintenance-off' = 'info', $false, $true
            # The v0.9.0 design, section 4: unknown PCs.
            'unknown-pc' = 'warn', $false, $true; 'unknown-pc-write' = 'flag', $true, $true
            'started' = 'info', $false, $true; 'stopped' = 'info', $false, $true
            # The v0.8.0 design, section 3: drive space.
            'drive-filling' = 'warn', $true, $true; 'drive-full' = 'flag', $true, $true
            'drive-space-ok' = 'info', $false, $true
            # The v0.9.0 design, section 4: write bursts (the unknown-PC events are #78's).
            'write-burst' = 'flag', $true, $true; 'write-burst-ended' = 'flag', $false, $true
        }
        $types = Get-EventTypes
        @($types.Keys | Sort-Object) | Should -Be @($spec.Keys | Sort-Object)
        foreach ($k in $spec.Keys) {
            $types[$k].Severity | Should -Be $spec[$k][0] -Because $k
            $types[$k].Banner | Should -Be $spec[$k][1] -Because $k
            $types[$k].Logged | Should -Be $spec[$k][2] -Because $k
        }
        { New-TypedEvent -Type 'no-such-type' } | Should -Throw
    }
}

Describe 'T50-17 events without a page open' {
    It 'T50-17 state moving through the activity fixtures writes today''s events log with no request' {
        $dir = New-TestDataPath
        try {
            $clock = { [DateTimeOffset]::Now }
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $clock
            $q = New-SrrQueue; $store = New-EventStore -Clock $clock
            $writers = @{ Event = (New-EventLogWriter -Log $log) }
            $states = @((New-Services $true $true), (New-Services $false $true), (New-Services $true $true))
            $old = $null
            foreach ($s in $states) {
                foreach ($e in Get-StateEvents -Old $old -New $s) { Add-SrrQueueItem -Queue $q -Item $e }
                $old = $s
                Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $clock | Out-Null
            }
            $file = Join-Path $dir ('events-{0}.jsonl' -f [DateTimeOffset]::Now.ToString('yyyy-MM-dd'))
            $types = @([IO.File]::ReadAllLines($file) | ForEach-Object { ($_ | ConvertFrom-Json).type })
            $types | Should -Be @('service-offline', 'service-back')
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T50-19 names never reach a log' {
    It 'T50-19 joins, leaves and streams with canary names log counts only' {
        $dir = New-TestDataPath
        try {
            $clock = { [DateTimeOffset]::Now }
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $clock
            $write = New-EventLogWriter -Log $log
            $events = @(Get-StateEvents -Old (New-Valheim 0) -New (New-Valheim 2 'CanaryVikingQx', 'CanaryShieldZq')) +
                @(Get-StateEvents -Old (New-Plex @()) -New (New-Plex @(New-Stream 's9')))
            foreach ($e in $events) { $e.id = 1; & $write $e }   # written even though these types aren't logged
            $text = (Get-ChildItem $dir -Recurse -File | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
            $text | Should -Match '"players":2'
            foreach ($c in $Canaries) { $text | Should -Not -Match $c }
        } finally { Remove-TestDataPath $dir }
    }
}
