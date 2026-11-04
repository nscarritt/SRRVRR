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
