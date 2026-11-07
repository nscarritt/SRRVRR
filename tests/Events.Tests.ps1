# modules\Events.psm1: event ids, the shared queue, repeat suppression and the one writer (spec section 4).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Events.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Logging.psm1') -Force
    $script:T0 = [DateTimeOffset]::new(2026, 1, 5, 12, 0, 0, [TimeSpan]::Zero)
    $script:Box = @{ Now = $T0 }
    $script:Clock = { $script:Box.Now }
    function Set-Now([DateTimeOffset]$Time) { $script:Box.Now = $Time }
    function New-Logged([string]$Key) { New-SrrEvent -Type 'test' -Severity 'warn' -Key $Key -Data @{} -Logged $true }
}

Describe 'T50-01 event ids' {
    It 'T50-01 two events in the same millisecond get increasing ids' {
        $a = New-EventId -NowMs 1000 -LastId 0
        $b = New-EventId -NowMs 1000 -LastId $a
        $a | Should -Be 1000
        $b | Should -Be 1001
    }
    It 'T50-01 ten in a row with the clock frozen keep counting' {
        $last = 0L; $ids = foreach ($i in 1..10) { $last = New-EventId -NowMs 5000 -LastId $last; $last }
        $ids | Should -Be (5000..5009)
    }
    It 'T50-01 a clock stepped back an hour keeps counting from the last id' {
        $last = New-EventId -NowMs 10000000 -LastId 0
        New-EventId -NowMs (10000000 - 3600000) -LastId $last | Should -Be 10000001
    }
    It 'T50-01 a restart seeded with a last id ahead of the clock stays ahead' {
        New-EventId -NowMs 500 -LastId 9000 | Should -Be 9001
    }
}

Describe 'T50-02 an event' {
    It 'T50-02 has id, time, type, severity, key, data and maintenance, for each severity' {
        foreach ($sev in 'info', 'warn', 'flag') {
            $e = New-SrrEvent -Type 'test' -Severity $sev -Key 'k' -Data @{ n = 1 }
            $names = @($e.PSObject.Properties.Name)
            foreach ($f in 'id', 'time', 'type', 'severity', 'key', 'data', 'maintenance') { $names | Should -Contain $f }
            $e.severity | Should -Be $sev
            $e.maintenance | Should -BeFalse
            $e.data.n | Should -Be 1
        }
    }
    It 'T50-02 a bad severity throws' {
        { New-SrrEvent -Type 'test' -Severity 'error' -Key 'k' -Data @{} } | Should -Throw
    }
    It 'T50-02 a missing key throws' {
        { New-SrrEvent -Type 'test' -Severity 'info' -Key '' -Data @{} } | Should -Throw
        { New-SrrEvent -Type 'test' -Severity 'info' -Data @{} } | Should -Throw
    }
}

Describe 'T50-03 repeat suppression' {
    It 'T50-03 keeps the same key at 0 and 10:00, suppresses 5 and 9:59, and keys are independent' {
        Set-Now $T0
        $q = New-SrrQueue; $store = New-EventStore -Clock $Clock
        $logged = New-Object System.Collections.Generic.List[object]
        $writers = @{ Event = { param($e) $logged.Add($e) }.GetNewClosure() }
        foreach ($at in 0, 5, 9.99, 10) {
            Set-Now ($T0.AddMinutes($at))
            Add-SrrQueueItem -Queue $q -Item (New-Logged 'a')
            Add-SrrQueueItem -Queue $q -Item (New-Logged 'b')
            Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $Clock | Out-Null
        }
        @($store.Published | Where-Object key -eq 'a').Count | Should -Be 2
        @($store.Published | Where-Object key -eq 'b').Count | Should -Be 2
        @($store.Published | Where-Object key -eq 'a' | ForEach-Object time) | Should -Be @($T0.ToUnixTimeMilliseconds(), $T0.AddMinutes(10).ToUnixTimeMilliseconds())
        $logged.Count | Should -Be 4
    }
}

Describe 'T50-03 a second change of the same thing is not a repeat' {
    It 'T50-03 offline, back, offline again within 10 minutes: all three kept; the same alert twice in a row is still suppressed' {
        Set-Now $T0
        $q = New-SrrQueue; $store = New-EventStore -Clock $Clock
        $steps = @(
            @{ At = 0; Type = 'service-offline' }, @{ At = 2; Type = 'service-back' }, @{ At = 4; Type = 'service-offline' },
            @{ At = 5; Type = 'service-offline' })
        foreach ($s in $steps) {
            Set-Now ($T0.AddMinutes($s.At))
            Add-SrrQueueItem -Queue $q -Item (New-TypedEvent -Type $s.Type -Data @{ name = 'Valheim' } -Key "$($s.Type)|Valheim" -Group 'service|Valheim')
            Invoke-QueueDrain -Queue $q -Store $store -Clock $Clock | Out-Null
        }
        @($store.Published | ForEach-Object type) | Should -Be @('service-offline', 'service-back', 'service-offline')
    }
    It 'T50-03 detection puts each service, status query and drive in its own group' {
        $e = @(Get-StateEvents -Old @{ services = @(@{ name = 'Plex'; online = $true }) } -New @{ services = @(@{ name = 'Plex'; online = $false }) })
        $e[0].group | Should -Be 'service|Plex'
        $d = @(Get-StateEvents -Old @{ drives = @(@{ letter = 'H:'; health = 'Healthy' }) } -New @{ drives = @(@{ letter = 'H:'; health = 'Missing' }) })
        $d[0].group | Should -Be 'drive|H:'
    }
}

Describe 'T50-04 the store' {
    It 'T50-04 keeps the newest 200 and publishes a new array each drain' {
        Set-Now $T0
        $q = New-SrrQueue; $store = New-EventStore -Clock $Clock
        foreach ($i in 1..205) { Add-SrrQueueItem -Queue $q -Item (New-Logged "k$i") }
        Invoke-QueueDrain -Queue $q -Store $store -Writers @{} -Clock $Clock | Should -Be 205
        $held = $store.Published
        $held.Count | Should -Be 200
        $held[0].key | Should -Be 'k6'
        $firstId = $held[0].id
        Add-SrrQueueItem -Queue $q -Item (New-Logged 'k206')
        Invoke-QueueDrain -Queue $q -Store $store -Writers @{} -Clock $Clock | Out-Null
        [object]::ReferenceEquals($held, $store.Published) | Should -BeFalse
        $held.Count | Should -Be 200
        $held[0].id | Should -Be $firstId
        $held[199].key | Should -Be 'k205'
        $store.Published[199].key | Should -Be 'k206'
        $store.LastId | Should -Be $store.Published[199].id
    }
    It 'T50-04 errors go to the error writer, not the store' {
        $q = New-SrrQueue; $store = New-EventStore -Clock $Clock
        $seen = New-Object System.Collections.Generic.List[string]
        Add-SrrQueueItem -Queue $q -Item (New-SrrError -Source 'slow-sampler' -Message 'boom')
        Invoke-QueueDrain -Queue $q -Store $store -Writers @{ Error = { param($s, $m) $seen.Add("${s}: $m") }.GetNewClosure() } -Clock $Clock | Out-Null
        $seen | Should -Be @('slow-sampler: boom')
        $store.Published.Count | Should -Be 0
    }
}

Describe 'T50-05 many threads, one writer' {
    It 'T50-05 three runspaces add 300 each while the main runspace drains and serializes' {
        $dir = New-TestDataPath
        try {
            $realClock = { [DateTimeOffset]::Now }
            $log = New-DailyLog -Folder $dir -Prefix 'events' -Extension 'jsonl' -Clock $realClock
            $q = New-SrrQueue; $store = New-EventStore -Clock $realClock -Size 1000
            $writers = @{ Event = { param($e) $log.Write((ConvertTo-Json -InputObject $e -Compress -Depth 5), $false) }.GetNewClosure() }
            $module = Join-Path (Get-RepoRoot) 'modules\Events.psm1'
            $jobs = foreach ($r in 1..3) {
                $ps = [PowerShell]::Create()
                [void]$ps.AddScript({
                    param($Queue, $Module, $R)
                    Import-Module $Module
                    foreach ($i in 1..300) { Add-SrrQueueItem -Queue $Queue -Item (New-SrrEvent -Type 'test' -Severity 'warn' -Key "r$R-$i" -Data @{ i = $i } -Logged $true) }
                }).AddArgument($q).AddArgument($module).AddArgument($r)
                @{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            $drained = 0
            while ($drained -lt 900) {
                $drained += Invoke-QueueDrain -Queue $q -Store $store -Writers $writers -Clock $realClock
                ConvertTo-Json -InputObject $store.Published -Depth 5 -Compress | Out-Null
            }
            foreach ($j in $jobs) { $j.PS.EndInvoke($j.Handle); $j.PS.HadErrors | Should -BeFalse; $j.PS.Dispose() }
            $lines = @(Get-ChildItem $dir -Filter 'events-*.jsonl' | Sort-Object Name | ForEach-Object { [IO.File]::ReadAllLines($_.FullName) })
            $lines.Count | Should -Be 900
            $ids = @($lines | ForEach-Object { [long]($_ | ConvertFrom-Json).id })
            for ($i = 1; $i -lt $ids.Count; $i++) { $ids[$i] | Should -BeGreaterThan $ids[$i - 1] }
        } finally { Remove-TestDataPath $dir }
    }
}

Describe 'T50-06 one writer for the logs' {
    It 'T50-06 the samplers and Web.psm1 never write a log file; they raise through the queue' {
        $root = Get-RepoRoot
        $writes = 'AppendAllText|Add-Content|Out-File|StreamWriter|New-DailyLog|Write-SrrLog|Write-SrrError'
        foreach ($m in 'Web.psm1', 'Counters.psm1', 'History.psm1', 'DataFolder.psm1') {
            (Get-Content (Join-Path $root "modules\$m") -Raw) | Should -Not -Match $writes -Because "$m must raise through the queue"
        }
        $ast = Get-ScriptAst (Join-Path $root 'SRRVRR.ps1')
        foreach ($name in 'sampler', 'slowChecks') {
            $assign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$name" }, $true)
            $assign | Should -Not -BeNullOrEmpty
            $assign.Right.Extent.Text | Should -Not -Match $writes -Because "the $name runspace must raise through the queue"
        }
        $events = Get-Content (Join-Path $root 'modules\Events.psm1') -Raw
        $events | Should -Not -Match 'AppendAllText|Add-Content|Out-File|StreamWriter' -Because 'the drain writes only through the writers it is given'
    }
}

# Drive space levels and their events (story #65, test plan section 6.9).
Describe 'T65 drive space' {
    BeforeAll {
        # A drive of 100 GB with the given percent used.
        function New-Drive([string]$Letter, [double]$Used, [string]$Level, [string]$Health = 'Healthy') {
            $d = @{ letter = $Letter; label = 'Secret label'; size = 100GB; free = (100GB * (100 - $Used) / 100); health = $Health }
            if ($Level) { $d.level = $Level }
            $d
        }
        function Get-DriveEvents($OldDrives, $NewDrives) {
            $old = if ($null -eq $OldDrives) { $null } else { @{ drives = @($OldDrives) } }
            , @(Get-StateEvents -Old $old -New @{ drives = @($NewDrives) })
        }
    }
    It 'T65-01 <used> from <was> is <level>' -ForEach @(
        @{ used = 84; was = 'ok'; level = 'ok' }, @{ used = 85; was = 'ok'; level = 'filling' }, @{ used = 94; was = 'ok'; level = 'filling' }, @{ used = 95; was = 'ok'; level = 'full' }
        @{ used = 83; was = 'filling'; level = 'filling' }, @{ used = 82.9; was = 'filling'; level = 'ok' }
        @{ used = 93; was = 'full'; level = 'full' }, @{ used = 92.9; was = 'full'; level = 'filling' }
        @{ used = 10; was = $null; level = 'ok' }, @{ used = 96; was = $null; level = 'full' }
    ) {
        Get-DriveLevel -UsedPercent $used -Previous $was -Warn 85 -Full 95 | Should -Be $level
    }
    It 'T65-01 from full a big drop skips filling, and the margin follows the settings' {
        Get-DriveLevel -UsedPercent 50 -Previous 'full' -Warn 85 -Full 95 | Should -Be 'ok'
        Get-DriveLevel -UsedPercent 70 -Previous 'full' -Warn 80 -Full 90 | Should -Be 'ok'
        Get-DriveLevel -UsedPercent 78 -Previous 'full' -Warn 80 -Full 90 | Should -Be 'filling'
        Get-DriveLevel -UsedPercent 88 -Previous 'full' -Warn 80 -Full 90 | Should -Be 'full'
    }
    It 'T65-02 ok to filling raises drive-filling' {
        $e = Get-DriveEvents (New-Drive 'D:' 50 'ok') (New-Drive 'D:' 87 'filling')
        $e.Count | Should -Be 1
        $e[0].type | Should -Be 'drive-filling'
        $e[0].key | Should -Be 'drive-filling|D:'
        $e[0].group | Should -Be 'drive-space|D:'
    }
    It 'T65-02 filling to full raises drive-full' {
        $e = Get-DriveEvents (New-Drive 'D:' 90 'filling') (New-Drive 'D:' 96 'full')
        $e.Count | Should -Be 1
        $e[0].type | Should -Be 'drive-full'
    }
    It 'T65-02 ok to full raises drive-full' {
        $e = Get-DriveEvents (New-Drive 'D:' 50 'ok') (New-Drive 'D:' 97 'full')
        @($e | ForEach-Object type) | Should -Be @('drive-full')
    }
    It 'T65-02 filling to ok and full to ok raise drive-space-ok' {
        @((Get-DriveEvents (New-Drive 'D:' 84 'filling') (New-Drive 'D:' 60 'ok')) | ForEach-Object type) | Should -Be @('drive-space-ok')
        @((Get-DriveEvents (New-Drive 'D:' 96 'full') (New-Drive 'D:' 60 'ok')) | ForEach-Object type) | Should -Be @('drive-space-ok')
    }
    It 'T65-02 full to filling and an unchanged level raise nothing' {
        (Get-DriveEvents (New-Drive 'D:' 96 'full') (New-Drive 'D:' 92 'filling')).Count | Should -Be 0
        (Get-DriveEvents (New-Drive 'D:' 96 'full') (New-Drive 'D:' 97 'full')).Count | Should -Be 0
        (Get-DriveEvents (New-Drive 'D:' 50 'ok') (New-Drive 'D:' 51 'ok')).Count | Should -Be 0
    }
    It 'T65-02 each drive is compared by its own letter' {
        $e = Get-DriveEvents @((New-Drive 'C:' 50 'ok'), (New-Drive 'D:' 90 'filling')) @((New-Drive 'D:' 96 'full'), (New-Drive 'C:' 87 'filling'))
        @($e | ForEach-Object { "$($_.type) $($_.data.letter)" } | Sort-Object) | Should -Be @('drive-filling C:', 'drive-full D:')
    }
    It 'T65-03 a first reading with one drive full and one ok raises one drive-full' {
        $e = Get-DriveEvents $null @((New-Drive 'C:' 40 'ok'), (New-Drive 'D:' 97 'full'))
        $e.Count | Should -Be 1
        $e[0].type | Should -Be 'drive-full'
        $e[0].data.letter | Should -Be 'D:'
    }
    It 'T65-03 a reading that follows one with no drives yet counts as the first' {
        $e = @(Get-StateEvents -Old @{ services = @() } -New @{ drives = @((New-Drive 'D:' 97 'full')) })
        @($e | ForEach-Object type) | Should -Be @('drive-full')
    }
    It 'T65-04 a Missing drive has no event, and none when it was full before' {
        (Get-DriveEvents $null @((New-Drive 'E:' 0 $null 'Missing'))).Count | Should -Be 0
        $e = Get-DriveEvents (New-Drive 'E:' 96 'full') (New-Drive 'E:' 0 $null 'Missing')
        @($e | ForEach-Object type) | Should -Not -Contain 'drive-space-ok'
        @($e | ForEach-Object type) | Should -Not -Contain 'drive-full'
        # A Missing drive that still carries a level is skipped too.
        (Get-DriveEvents $null @((New-Drive 'E:' 99 'full' 'Missing'))).Count | Should -Be 0
    }
    It 'T65-04 a drive with no level has no event' {
        (Get-DriveEvents (New-Drive 'D:' 50 'ok') (New-Drive 'D:' 99 $null)).Count | Should -Be 0
    }
    It 'T65-05 the new events carry only letter, usedPercent and freeGB' {
        foreach ($case in @(@('ok', 87, 'filling'), @('filling', 96, 'full'), @('full', 50, 'ok'))) {
            $e = Get-DriveEvents (New-Drive 'D:' 50 $case[0]) (New-Drive 'D:' $case[1] $case[2])
            $e.Count | Should -Be 1
            @($e[0].data.Keys | Sort-Object) | Should -Be @('freeGB', 'letter', 'usedPercent')
            $e[0].data.letter | Should -Be 'D:'
            $e[0].data.usedPercent | Should -BeOfType [int]
            $e[0].data.usedPercent | Should -Be $case[1]
            $e[0].data.freeGB | Should -Be ([Math]::Round(100 * (100 - $case[1]) / 100, 1))
            (ConvertTo-Json -InputObject $e[0].data -Compress) | Should -Not -Match 'Secret|label'
            (ConvertTo-Json -InputObject (ConvertTo-LoggedEvent $e[0]) -Compress) | Should -Not -Match 'Secret|label'
        }
    }
    It 'T65-05 the used percent is rounded to a whole number' {
        $e = Get-DriveEvents (New-Drive 'D:' 50 'ok') (New-Drive 'D:' 87.6 'filling')
        $e[0].data.usedPercent | Should -Be 88
    }
    It 'T65-07 the three types are in the table with their severity, banner and logged values' {
        $t = Get-EventTypes
        $t['drive-filling'].Severity | Should -Be 'warn'; $t['drive-filling'].Banner | Should -BeTrue; $t['drive-filling'].Logged | Should -BeTrue
        $t['drive-full'].Severity | Should -Be 'flag'; $t['drive-full'].Banner | Should -BeTrue; $t['drive-full'].Logged | Should -BeTrue
        $t['drive-space-ok'].Severity | Should -Be 'info'; $t['drive-space-ok'].Banner | Should -BeFalse; $t['drive-space-ok'].Logged | Should -BeTrue
    }
    It 'T65-07 the events take their flags from the table' {
        $e = Get-DriveEvents (New-Drive 'D:' 90 'filling') (New-Drive 'D:' 96 'full')
        $e[0].severity | Should -Be 'flag'; $e[0].banner | Should -BeTrue; $e[0].logged | Should -BeTrue
        $e = Get-DriveEvents (New-Drive 'D:' 96 'full') (New-Drive 'D:' 60 'ok')
        $e[0].severity | Should -Be 'info'; $e[0].banner | Should -BeFalse; $e[0].logged | Should -BeTrue
    }
}