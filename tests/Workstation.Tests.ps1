# modules\Workstation.psm1 (#90 to #93, test plan 6.10 to 6.13). One region per story; add Describe blocks only
# inside your own. Every It starts with its test id.
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module "$PSScriptRoot\fakes\FakeCounterReader.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Workstation.psm1') -Force
    $script:Fixtures = Join-Path (Get-RepoRoot) 'tests\fixtures\workstation'
}

#region 90 Roles and the host name (#90)
Describe 'T90-01 and T90-02 the role plan' {
    It 'T90-01 Get-RolePlan <role> is the server plan: Processes and the tracer on, no Workstation part, five history lines' -ForEach @(
        @{ role = 'Server' }, @{ role = 'server' }, @{ role = 'SERVER' }
    ) {
        $plan = Get-RolePlan -Role $role
        $plan | Should -BeOfType [hashtable]
        @($plan.Keys | Sort-Object) | Should -Be @('HistoryLines', 'Processes', 'Role', 'Tracer', 'Workstation')
        $plan.Role | Should -BeExactly 'server'
        $plan.Processes | Should -BeOfType [bool]
        $plan.Processes | Should -BeTrue
        $plan.Tracer | Should -BeOfType [bool]
        $plan.Tracer | Should -BeTrue
        $plan.Workstation | Should -BeOfType [bool]
        $plan.Workstation | Should -BeFalse
        @($plan.HistoryLines) | Should -BeExactly @('cpu', 'mem', 'gpu', 'rx', 'tx')
    }
    It 'T90-02 Get-RolePlan <role> is the workstation plan: no Processes or tracer, the Workstation part, seven history lines' -ForEach @(
        @{ role = 'Workstation' }, @{ role = 'workstation' }, @{ role = 'WORKSTATION' }
    ) {
        $plan = Get-RolePlan -Role $role
        $plan | Should -BeOfType [hashtable]
        @($plan.Keys | Sort-Object) | Should -Be @('HistoryLines', 'Processes', 'Role', 'Tracer', 'Workstation')
        $plan.Role | Should -BeExactly 'workstation'
        $plan.Processes | Should -BeOfType [bool]
        $plan.Processes | Should -BeFalse
        $plan.Tracer | Should -BeOfType [bool]
        $plan.Tracer | Should -BeFalse
        $plan.Workstation | Should -BeOfType [bool]
        $plan.Workstation | Should -BeTrue
        @($plan.HistoryLines) | Should -BeExactly @('cpu', 'mem', 'gpu', 'rx', 'tx', 'vram', 'vramShared')
    }
}

Describe 'T90-04 the name on the page' {
    It 'T90-04 Resolve-DisplayName (''<setting>'', <role>, <computer>) is ''<expected>''' -ForEach @(
        @{ setting = ''; role = 'server'; computer = 'ANYPC'; expected = 'SRRVRR' }
        @{ setting = ''; role = 'workstation'; computer = 'DEV-PC'; expected = 'DEV-PC' }
        @{ setting = 'My PC'; role = 'server'; computer = 'X'; expected = 'My PC' }
        @{ setting = 'My PC'; role = 'workstation'; computer = 'X'; expected = 'My PC' }
    ) {
        $name = Resolve-DisplayName -Setting $setting -Role $role -ComputerName $computer
        $name | Should -BeOfType [string]
        $name | Should -BeExactly $expected
    }
}

Describe 'T90-06 the startup lines for each role' {
    It 'T90-06 Format-RoleLines gives exactly "Role: Server" for the server plan' {
        $lines = @(Format-RoleLines -Plan (Get-RolePlan -Role 'Server'))
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly 'Role: Server'
    }
    It 'T90-06 Format-RoleLines gives exactly the two workstation lines, in order' {
        $lines = @(Format-RoleLines -Plan (Get-RolePlan -Role 'Workstation'))
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'Role: Workstation. Off: Processes. On: video memory, top programs, AI server'
        $lines[1] | Should -BeExactly 'Not used on a workstation: Processes, ValheimPort'
    }
}
#endregion 90

#region 91 Video memory and GPU detail (#91)
# nvidia-smi detail (Get-SmiArguments, Select-SmiPrefix, ConvertFrom-SmiDetail) and the spill events
# (Get-WorkstationEvents); New-SpillWatch and Update-SpillWatch are tested in Counters.Tests.ps1.
Describe 'T91 nvidia-smi detail' {
    BeforeAll {
        # The lines of one [case] in tests\fixtures\workstation\smi-lines.txt.
        function Get-SmiCase([string]$Name) {
            $out = New-Object System.Collections.Generic.List[string]
            $in = $false
            foreach ($l in [IO.File]::ReadAllLines((Join-Path $Fixtures 'smi-lines.txt'))) {
                if ($l -match '^\[(.+)\]$') { $in = $Matches[1] -eq $Name; continue }
                if ($in -and $l.Trim() -and -not $l.StartsWith('#')) { $out.Add($l) }
            }
            if (-not $out.Count) { throw "smi-lines.txt has no case [$Name]" }
            , $out.ToArray()
        }
        $script:Gpu4090 = 'NVIDIA GeForce RTX 4090'
        $script:DetailKeys = @('gpuTemp', 'gpuPower', 'gpuPowerLimit', 'gpuClock', 'gpuClockMax', 'gpuFan', 'gpuPState', 'gpuLimits')
    }
    It 'T91-05 Get-SmiArguments gives exactly the two arguments, with the prefix <Prefix>' -ForEach @(
        @{ Prefix = 'clocks_event_reasons' }
        @{ Prefix = 'clocks_throttle_reasons' }
    ) {
        $a = @(Get-SmiArguments -Prefix $Prefix)
        $a.Count | Should -Be 2
        $a[0] | Should -BeExactly ('--query-gpu=name,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,fan.speed,pstate,' +
            "$Prefix.sw_power_cap,$Prefix.hw_slowdown,$Prefix.sw_thermal_slowdown,$Prefix.hw_thermal_slowdown,$Prefix.hw_power_brake_slowdown")
        $a[1] | Should -BeExactly '--format=csv,noheader,nounits'
    }
    It 'T91-05 Get-SmiArguments takes no other prefix (none means today''s call, made without it)' {
        { Get-SmiArguments -Prefix 'none' } | Should -Throw -ErrorId 'ParameterArgumentValidationError*'
    }
    It 'T91-06 ConvertFrom-SmiDetail reads a busy RTX 4090: whole watts, MHz, fan percent, the P-state and the power limit' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'busy') -GpuName $Gpu4090
        $r | Should -BeOfType [hashtable]
        @($r.Keys | Sort-Object) | Should -Be @($DetailKeys | Sort-Object)
        $r.gpuTemp | Should -BeOfType [int]
        $r.gpuTemp | Should -Be 34 -Because '[int] of 33.65, as today'
        $r.gpuPower | Should -Be 312
        $r.gpuPowerLimit | Should -Be 450
        $r.gpuClock | Should -Be 2610
        $r.gpuClockMax | Should -Be 3105
        $r.gpuFan | Should -Be 48
        $r.gpuPState | Should -BeExactly 'P2'
        ($r.gpuLimits -is [Collections.IList]) | Should -BeTrue -Because 'gpuLimits is a list'
        (@($r.gpuLimits) -join ',') | Should -BeExactly 'power'
    }
    It 'T91-07 <Case> alone gives gpuLimits <Expected>' -ForEach @(
        @{ Case = 'reason-sw-power-cap'; Expected = 'power' }
        @{ Case = 'reason-hw-slowdown'; Expected = 'slowed' }
        @{ Case = 'reason-sw-thermal'; Expected = 'thermal' }
        @{ Case = 'reason-hw-thermal'; Expected = 'thermal' }
        @{ Case = 'reason-hw-power-brake'; Expected = 'power' }
    ) {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase $Case) -GpuName $Gpu4090
        ($r.gpuLimits -is [Collections.IList]) | Should -BeTrue
        (@($r.gpuLimits) -join ',') | Should -BeExactly $Expected
    }
    It 'T91-07 all five reasons give power, thermal, slowed in that order, once each; none gives an empty list' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'reason-all') -GpuName $Gpu4090
        (@($r.gpuLimits) -join ',') | Should -BeExactly 'power,thermal,slowed'
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'reason-none') -GpuName $Gpu4090
        $r.ContainsKey('gpuLimits') | Should -BeTrue
        ($r.gpuLimits -is [Collections.IList]) | Should -BeTrue -Because 'an empty list, not $null'
        @($r.gpuLimits).Count | Should -Be 0
        $r.gpuFan | Should -Be 0 -Because 'a fan at 0% is a reading, not a missing field'
        $r.gpuPower | Should -Be 21
        $r.gpuPState | Should -BeExactly 'P8'
    }
    It 'T91-08 [N/A] fan and power limit are $null, the rest read' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'na-fan-and-limit') -GpuName $Gpu4090
        $r | Should -Not -BeNullOrEmpty
        $r.gpuFan | Should -Be $null
        $r.gpuPowerLimit | Should -Be $null
        $r.gpuTemp | Should -Be 41
        $r.gpuPower | Should -Be 75
        $r.gpuClock | Should -Be 1410
        $r.gpuClockMax | Should -Be 3105
        $r.gpuPState | Should -BeExactly 'P8'
    }
    It 'T91-08 empty fields are $null' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'empty-fields') -GpuName $Gpu4090
        $r.gpuPower | Should -Be $null
        $r.gpuClockMax | Should -Be $null
        $r.gpuPowerLimit | Should -Be 450
        $r.gpuFan | Should -Be 30
    }
    It 'T91-08 Not Supported (with or without brackets) is $null' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'not-supported') -GpuName $Gpu4090
        $r.gpuPower | Should -Be $null
        $r.gpuFan | Should -Be $null
        $r.gpuPowerLimit | Should -Be 450
        $r.gpuClock | Should -Be 1410
    }
    It 'T91-08 a line with 9 fields reads the fields it has, with no exception' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'nine-fields') -GpuName $Gpu4090
        $r | Should -Not -BeNullOrEmpty
        $r.gpuTemp | Should -Be 34
        $r.gpuPower | Should -Be 312
        $r.gpuFan | Should -Be 48
        $r.gpuPState | Should -BeExactly 'P2'
        (@($r.gpuLimits) -join ',') | Should -BeExactly 'power' -Because 'the one reason there is Active; the missing four count as not active'
    }
    It 'T91-08 with two cards, the named one is used even when it is second' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'two-cards-named-second') -GpuName $Gpu4090
        $r.gpuPower | Should -Be 312
        $r.gpuTemp | Should -Be 34
        $r.gpuClockMax | Should -Be 3105
    }
    It 'T91-08 one line is used whatever its name, as today' {
        $r = ConvertFrom-SmiDetail -Lines (Get-SmiCase 'busy') -GpuName 'NVIDIA GeForce RTX 4090 Laptop GPU'
        $r.gpuPower | Should -Be 312
    }
    It 'T91-08 two cards with no match, no lines, and the error text after a driver update give $null, with no exception' {
        ConvertFrom-SmiDetail -Lines (Get-SmiCase 'two-cards-no-match') -GpuName $Gpu4090 | Should -Be $null
        ConvertFrom-SmiDetail -Lines @() -GpuName $Gpu4090 | Should -Be $null
        ConvertFrom-SmiDetail -Lines (Get-SmiCase 'driver-error') -GpuName $Gpu4090 | Should -Be $null -Because 'one line, but not a reading'
        ConvertFrom-SmiDetail -Lines (Get-SmiCase 'driver-error-two-lines') -GpuName $Gpu4090 | Should -Be $null
    }
    It 'T91-09 Select-SmiPrefix picks the event prefix, the throttle prefix once, or none' {
        $ok = @{ ExitCode = 0; Lines = (Get-SmiCase 'busy') }
        $noEventField = @{ ExitCode = 2; Lines = @('Field "clocks_event_reasons.sw_power_cap" is not a valid field to query.') }
        $noThrottleField = @{ ExitCode = 2; Lines = @('Field "clocks_throttle_reasons.sw_power_cap" is not a valid field to query.') }
        $other = @{ ExitCode = 9; Lines = @('NVIDIA-SMI has failed because it couldn''t communicate with the NVIDIA driver. Make sure that the latest NVIDIA driver is installed and running.') }
        Select-SmiPrefix -Event $ok -Throttle $null | Should -BeExactly 'clocks_event_reasons'
        Select-SmiPrefix -Event $ok -Throttle $ok | Should -BeExactly 'clocks_event_reasons'
        Select-SmiPrefix -Event $noEventField -Throttle $ok | Should -BeExactly 'clocks_throttle_reasons'
        Select-SmiPrefix -Event $noEventField -Throttle $noThrottleField | Should -BeExactly 'none'
        Select-SmiPrefix -Event $noEventField -Throttle $null | Should -BeExactly 'none'
        Select-SmiPrefix -Event $other -Throttle $null | Should -BeExactly 'none'
        Select-SmiPrefix -Event $other -Throttle $ok | Should -BeExactly 'none' -Because 'the fallback is only for a field the driver does not know'
        Select-SmiPrefix -Event $null -Throttle $null | Should -BeExactly 'none'
    }
    It 'T91-09 the "not a valid field" line may be any line of the output' {
        $noEventField = @{ ExitCode = 2; Lines = @('', 'Field "clocks_event_reasons.sw_power_cap" is not a valid field to query.', '') }
        Select-SmiPrefix -Event $noEventField -Throttle @{ ExitCode = 0; Lines = (Get-SmiCase 'busy') } | Should -BeExactly 'clocks_throttle_reasons'
    }
}

Describe 'T91 the spill events' {
    BeforeAll {
        # A detection reading as SRRVRR.ps1's Get-DetectionReading makes it on the Workstation: gpuSpill (left out
        # when $Spill is $null) and the bytes the event's data is worked out from.
        function New-SpillReading($Spill, [double]$DedicatedGib = 23.1, [double]$SharedGib = 2.04) {
            $r = @{ gpuMem = $DedicatedGib * 1GB; gpuShared = $SharedGib * 1GB }
            if ($null -ne $Spill) { $r.gpuSpill = $Spill }
            $r
        }
    }
    It 'T91-11 gpuSpill $false to $true gives one vram-spill with dedicatedGb and sharedGb to one decimal' {
        $e = @(Get-WorkstationEvents -Old (New-SpillReading $false) -New (New-SpillReading $true))
        $e.Count | Should -Be 1
        $e[0].Type | Should -BeExactly 'vram-spill'
        $e[0].Key | Should -BeExactly 'vram-spill'
        $e[0].Data | Should -BeOfType [hashtable]
        @($e[0].Data.Keys | Sort-Object) | Should -Be @('dedicatedGb', 'sharedGb')
        $e[0].Data.dedicatedGb | Should -Be 23.1
        $e[0].Data.sharedGb | Should -Be 2.0
    }
    It 'T91-11 gpuSpill $true to $false gives one vram-spill-ended' {
        $e = @(Get-WorkstationEvents -Old (New-SpillReading $true) -New (New-SpillReading $false 20.0 0.3))
        $e.Count | Should -Be 1
        $e[0].Type | Should -BeExactly 'vram-spill-ended'
        $e[0].Key | Should -BeExactly 'vram-spill-ended'
    }
    It 'T91-11 Old $null, no change, or gpuSpill missing on either side gives nothing' {
        @(Get-WorkstationEvents -Old $null -New (New-SpillReading $true)).Count | Should -Be 0 -Because 'Old $null'
        @(Get-WorkstationEvents -Old (New-SpillReading $true) -New (New-SpillReading $true)).Count | Should -Be 0 -Because 'still spilling'
        @(Get-WorkstationEvents -Old (New-SpillReading $false) -New (New-SpillReading $false)).Count | Should -Be 0 -Because 'still not spilling'
        @(Get-WorkstationEvents -Old (New-SpillReading $null) -New (New-SpillReading $true)).Count | Should -Be 0 -Because 'missing in Old'
        @(Get-WorkstationEvents -Old (New-SpillReading $true) -New (New-SpillReading $null)).Count | Should -Be 0 -Because 'missing in New'
        @(Get-WorkstationEvents -Old @{} -New @{}).Count | Should -Be 0 -Because 'a reading with no GPU fields at all'
    }
}
#endregion 91

#region 92 Memory detail and top programs (#92)
Describe '92 memory detail, the WSL VM and top programs' {
    BeforeAll {
        $script:Luid = '0x00000000_0x0000a1b2'   # the chosen card; the fixtures' other card is 0x00000000_0x0000ffff
        $script:MiB = 1048576

        # The fixtures (memory.json, process.json, gpu-process-memory.json) hold each reading row by row (instance ->
        # counter -> raw value) with each counter's type, so they can be checked by hand. ConvertTo-WsCategory turns
        # one reading into what ReadCategory() returns: counter -> instance -> object with .Sample (a real
        # CounterSample, so CounterSample.Calculate works on it) and .RawValue. -ShiftSeconds moves the reading later.
        function Read-WsFixture([string]$Name) { [IO.File]::ReadAllText((Join-Path $Fixtures $Name)) | ConvertFrom-Json }
        function ConvertTo-WsCategory($Doc, [int]$Index, [double]$ShiftSeconds = 0) {
            $reading = $Doc.snapshots[$Index]
            $ts = [long]$reading.timeStamp + [long]($ShiftSeconds * $Doc.systemFrequency)
            $ts100 = [long]$reading.timeStamp100nSec + [long]($ShiftSeconds * 10000000)
            $cat = @{}
            foreach ($c in $Doc.counters.PSObject.Properties) {
                $type = [Diagnostics.PerformanceCounterType]$c.Value
                $cat[$c.Name] = @{}
                foreach ($i in $reading.instances.PSObject.Properties) {
                    $raw = [long]$i.Value.($c.Name)
                    $sample = New-Object Diagnostics.CounterSample $raw, ([long]0), ([long]$Doc.counterFrequency), ([long]$Doc.systemFrequency), $ts, $ts100, $type
                    $cat[$c.Name][$i.Name] = [pscustomobject]@{ InstanceName = $i.Name; Sample = $sample; RawValue = $raw }
                }
            }
            $cat
        }
        # One snapshot as the Counters reader returns it (category -> ReadCategory() shape), from reading $Index of the
        # three fixtures. -Without leaves categories out; -Docs replaces a fixture with a changed copy.
        function Get-WsSnapshot([int]$Index, [double]$ShiftSeconds = 0, [string[]]$Without = @(), [hashtable]$Docs = @{}) {
            $files = @{ 'Memory' = 'memory.json'; 'Process' = 'process.json'; 'GPU Process Memory' = 'gpu-process-memory.json' }
            $snap = @{}
            foreach ($cat in $files.Keys) {
                if ($Without -contains $cat) { continue }
                $doc = if ($Docs.ContainsKey($cat)) { $Docs[$cat] } else { Read-WsFixture $files[$cat] }
                $snap[$cat] = ConvertTo-WsCategory $doc $Index $ShiftSeconds
            }
            $snap
        }
        function Get-Row([object[]]$Rows, [string]$Name) { @($Rows | Where-Object { $_.name -ceq $Name })[0] }
        function Get-NameList([object[]]$Rows) { @($Rows | ForEach-Object { $_.name }) }
    }

    It 'T92-01 Get-MemoryDetail: commit and its limit from the current raw values, paging in bytes per second' {
        $prev = Get-WsSnapshot 0; $cur = Get-WsSnapshot 1
        $d = Get-MemoryDetail -Previous $prev -Current $cur
        $d.memCommit | Should -Be 33412345856
        $d.memCommit | Should -BeOfType [long]
        $d.memCommitLimit | Should -Be 103079219200 -Because 'the raw value (read through a float, as CounterSample.Calculate returns, it is 103079215104)'
        $d.memCommitLimit | Should -BeOfType [long]
        $d.memPageIn | Should -Be 491520 -Because '600 pages in 5 s, times 4096 bytes'
        $d.memPageIn | Should -BeOfType [long]
        $first = Get-MemoryDetail -Previous $null -Current $cur
        $null -eq $first.memPageIn | Should -BeTrue -Because 'there is no rate without a previous reading'
        $first.memCommit | Should -Be 33412345856
        $first.memCommitLimit | Should -Be 103079219200
    }

    It 'T92-02 ConvertFrom-WslConfig: memory= under [wsl2], else half of RAM' {
        $ram = [double]64GB
        $cases = @(
            @{ File = '01-memory-48gb.txt'; Cap = 48GB; Source = 'config' }
            @{ File = '02-memory-48000mb-spaces.txt'; Cap = 48000MB; Source = 'config' }
            @{ File = '03-memory-key-case.txt'; Cap = 48GB; Source = 'config' }
            @{ File = '04-memory-decimal.txt'; Cap = 1.5GB; Source = 'config' }
            @{ File = '05-memory-inline-comment.txt'; Cap = 48GB; Source = 'config' }
            @{ File = '06-memory-commented-out.txt'; Cap = $ram / 2; Source = 'default' }
            @{ File = '07-memory-other-section.txt'; Cap = $ram / 2; Source = 'default' }
            @{ File = '08-memory-word.txt'; Cap = $ram / 2; Source = 'default' }
            @{ File = '09-memory-negative.txt'; Cap = $ram / 2; Source = 'default' }
            @{ File = '10-memory-empty.txt'; Cap = $ram / 2; Source = 'default' }
            @{ File = $null; Cap = $ram / 2; Source = 'default' }   # no .wslconfig
        )
        foreach ($c in $cases) {
            $text = if ($c.File) { [IO.File]::ReadAllText((Join-Path $Fixtures "wslconfig\$($c.File)")) } else { $null }
            $name = if ($c.File) { $c.File } else { 'no file' }
            $r = ConvertFrom-WslConfig -Text $text -TotalRam $ram
            $r.Cap | Should -Be $c.Cap -Because $name
            $r.Cap | Should -BeOfType [double] -Because $name
            $r.Source | Should -BeExactly $c.Source -Because $name
        }
    }

    It 'T92-03 Get-WslReading: the vmmemWSL working set against the cap; not running; a working set that can''t be read' {
        $cap = @{ Cap = [double]48GB; Source = 'config' }
        $r = Get-WslReading -Process ([pscustomobject]@{ Id = 5500; ProcessName = 'vmmemWSL'; WorkingSet64 = [long]31e9 }) -Cap $cap
        $r.running | Should -BeTrue
        $r.mem | Should -Be 31e9
        $r.cap | Should -Be 48GB
        $r.capSource | Should -BeExactly 'config'
        $r = Get-WslReading -Process $null -Cap $cap
        $r.running | Should -BeFalse
        $null -eq $r.mem | Should -BeTrue
        # Reading a property that throws gives $null in PowerShell, and [long]$null would be 0: mem must stay $null.
        $p = [pscustomobject]@{ Id = 5500; ProcessName = 'vmmemWSL' }
        $p | Add-Member ScriptProperty WorkingSet64 { throw 'Access is denied' }
        { $script:Throwing = Get-WslReading -Process $p -Cap $cap } | Should -Not -Throw
        $Throwing.running | Should -BeTrue
        $null -eq $Throwing.mem | Should -BeTrue
    }

    It 'T92-04 Get-TopPrograms groups by program, drops _Total and Idle, names the WSL VM, counts the chosen card only, and keeps the top 5 by each' {
        $prev = Get-WsSnapshot 0; $cur = Get-WsSnapshot 1
        # Every program (limits raised), to see the grouping.
        $all = @(Get-TopPrograms -Previous $prev -Current $cur -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid -Count 50 -MaxRows 50)
        Get-NameList $all | Should -Be @('gameapp', 'browser', 'editor', 'my#app', 'alpha', 'bravo', 'WSL VM', 'charlie', 'delta', 'echo', 'foxtrot')
        $browser = Get-Row $all 'browser'
        $browser.count | Should -Be 3
        $browser.mem | Should -Be (1400 * $MiB) -Because '800 + 400 + 200 MiB in the current reading'
        $browser.vram | Should -Be (600 * $MiB) -Because 'Dedicated Usage 300 + 200 + 100 MiB, not Shared Usage'
        $myApp = Get-Row $all 'my#app'
        $myApp.count | Should -Be 2 -Because 'my#app#1 is my#app; only a final #<digits> is dropped'
        $myApp.mem | Should -Be (250 * $MiB)
        $myApp.vram | Should -Be (150 * $MiB)
        (Get-Row $all 'gameapp').vram | Should -Be (6000 * $MiB) -Because 'its 500 MiB on the other card is not counted'
        (Get-Row $all 'gameapp').count | Should -Be 1 -Because 'gameapp#1 exited before the current reading'
        (Get-Row $all 'bravo').vram | Should -Be (20 * $MiB) -Because 'its 9000 MiB on the other card is not counted'
        $wsl = Get-Row $all 'WSL VM'
        $wsl.mem | Should -Be (9000 * $MiB)
        $wsl.vram | Should -Be 0
        $names = Get-NameList $all
        foreach ($gone in '_Total', 'Idle', 'vmmemWSL') { $names | Should -Not -Contain $gone }
        # Defaults: video memory top 5 (gameapp, browser, editor, my#app, alpha) and RAM top 5 (WSL VM, charlie, delta,
        # echo, gameapp) make 9 programs; sorted by video memory then RAM and cut to 8, echo is the one left out.
        $top = @(Get-TopPrograms -Previous $prev -Current $cur -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid)
        Get-NameList $top | Should -Be @('gameapp', 'browser', 'editor', 'my#app', 'alpha', 'WSL VM', 'charlie', 'delta')
        foreach ($row in $top) { @($row.Keys | Sort-Object) | Should -Be @('count', 'cpu', 'mem', 'name', 'vram') }
    }

    It 'T92-05 CPU over 5 s on 24 cores, and $null for programs that came, went or changed process between readings' {
        $prev = Get-WsSnapshot 0; $cur = Get-WsSnapshot 1
        $rows = @(Get-TopPrograms -Previous $prev -Current $cur -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid -Count 50 -MaxRows 50)
        (Get-Row $rows 'editor').cpu | Should -Be 8.3 -Because '10 s of CPU in 5 s on 24 cores'
        (Get-Row $rows 'gameapp').cpu | Should -Be 25 -Because 'gameapp#1 exiting changes nothing for gameapp'
        (Get-Row $rows 'browser').cpu | Should -Be 2.9 -Because '2 + 1 + 0.5 s across its three processes'
        (Get-Row $rows 'WSL VM').cpu | Should -Be 10
        $null -eq (Get-Row $rows 'foxtrot').cpu | Should -BeTrue -Because 'its ID Process changed (6600 to 6601): a restart, not 0%'
        $null -eq (Get-Row $rows 'bravo').cpu | Should -BeTrue -Because 'it is only in the current reading'
        $first = @(Get-TopPrograms -Previous $null -Current $cur -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid -Count 50 -MaxRows 50)
        $first.Count | Should -Be 11
        @($first | Where-Object { $null -ne $_.cpu }).Count | Should -Be 0 -Because 'no previous reading'
        # Review Focus 5: browser#2 exits and Windows renames browser#3 to browser#2. The instance name is the same but
        # the process isn't, so its delta (2010% of a core) must never be used.
        $shifted = Read-WsFixture 'process.json'
        $now = $shifted.snapshots[1].instances
        foreach ($k in 'ID Process', 'Working Set - Private', '% Processor Time') { $now.'browser#2'.$k = $now.'browser#3'.$k }
        $now.PSObject.Properties.Remove('browser#3')
        $after = Get-WsSnapshot 1 -Docs @{ 'Process' = $shifted }
        $rows = @(Get-TopPrograms -Previous $prev -Current $after -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid -Count 50 -MaxRows 50)
        $browser = Get-Row $rows 'browser'
        $browser.count | Should -Be 2
        if ($null -ne $browser.cpu) { $browser.cpu | Should -Be 1.7 -Because 'only browser#1 (2 s) can be compared' }
        (Get-Row $rows 'editor').cpu | Should -Be 8.3
    }

    It 'T92-06 fewer than 5 programs; no GPU Process Memory category; video memory of a pid with no process' {
        $few = Read-WsFixture 'process.json'
        foreach ($r in $few.snapshots) {
            foreach ($n in @($r.instances.PSObject.Properties.Name)) { if ($n -notin 'gameapp', 'editor', 'browser#1') { $r.instances.PSObject.Properties.Remove($n) } }
        }
        $rows = @(Get-TopPrograms -Previous (Get-WsSnapshot 0 -Docs @{ 'Process' = $few }) -Current (Get-WsSnapshot 1 -Docs @{ 'Process' = $few }) `
            -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid)
        Get-NameList $rows | Should -Be @('gameapp', 'browser', 'editor')
        (Get-Row $rows 'browser').count | Should -Be 1
        $noGpu = @(Get-TopPrograms -Previous (Get-WsSnapshot 0 -Without 'GPU Process Memory') -Current (Get-WsSnapshot 1 -Without 'GPU Process Memory') `
            -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid)
        Get-NameList $noGpu | Should -Be @('WSL VM', 'charlie', 'delta', 'echo', 'gameapp') -Because 'the top 5 by RAM, in RAM order'
        foreach ($row in $noGpu) { $row.vram | Should -Be 0 -Because $row.name }
        # pid 9999 holds 7000 MiB on the chosen card but has no process: it adds to no row.
        $all = @(Get-TopPrograms -Previous (Get-WsSnapshot 0) -Current (Get-WsSnapshot 1) -ElapsedSeconds 5 -Cores 24 -GpuLuid $Luid -Count 50 -MaxRows 50)
        ($all | ForEach-Object { $_.vram } | Measure-Object -Sum).Sum | Should -Be (7060 * $MiB) -Because '6000 + 600 + 250 + 150 + 40 + 20 MiB'
    }

    It 'T92-07 Invoke-WorkstationTick sets every field each pass, reads .wslconfig every 60 s, and a failed part leaves the rest' {
        $calls = @{ Now = 0; Snap = $null; Throw = $false; Mem = [long]0; ConfigAt = New-Object 'System.Collections.Generic.List[long]' }
        $readers = @{
            Counters   = { if ($calls.Throw) { throw 'counter read failed' }; $calls.Snap }.GetNewClosure()
            WslProcess = { [pscustomobject]@{ Id = 5500; ProcessName = 'vmmemWSL'; WorkingSet64 = $calls.Mem } }.GetNewClosure()
            WslConfig  = { $calls.ConfigAt.Add($calls.Now); "[wsl2]`r`nmemory=48GB`r`n" }.GetNewClosure()
        }
        $ctx = New-WorkstationContext -GpuLuid $Luid -Cores 24 -TotalRam ([double]64GB) -Readers $readers
        $state = @{}
        $passes = @(@{ Ms = 0; Index = 0; Shift = 0 }, @{ Ms = 5000; Index = 1; Shift = 0 }, @{ Ms = 60000; Index = 1; Shift = 55 }, @{ Ms = 65000; Index = 1; Shift = 60 })
        foreach ($p in $passes) {
            $calls.Now = $p.Ms; $calls.Mem = [long](20GB + $p.Ms); $calls.Snap = Get-WsSnapshot $p.Index $p.Shift
            Invoke-WorkstationTick -State $state -Context $ctx -NowMs $p.Ms
            $at = "the pass at $($p.Ms) ms"
            foreach ($k in 'memCommit', 'memCommitLimit', 'memPageIn', 'wsl', 'top') { $state.ContainsKey($k) | Should -BeTrue -Because "$k, $at" }
            $state.memCommit | Should -Not -BeNullOrEmpty -Because $at
            $state.memCommitLimit | Should -Not -BeNullOrEmpty -Because $at
            @($state.top).Count | Should -BeGreaterThan 0 -Because $at
            $state.wsl.running | Should -BeTrue -Because $at
            $state.wsl.mem | Should -Be $calls.Mem -Because "the WSL VM is read every pass, $at"
            $state.wsl.cap | Should -Be 48GB -Because $at
            $state.wsl.capSource | Should -BeExactly 'config' -Because $at
            if ($p.Ms -gt 0) { $state.memPageIn | Should -Not -BeNullOrEmpty -Because $at }
            $state['workstationError'] | Should -BeNullOrEmpty -Because $at
        }
        $state.memPageIn | Should -Not -BeNullOrEmpty
        @($calls.ConfigAt) | Should -Be @(0, 60000)
        # The Counters reader fails: the memory part reports it, and the WSL VM is still read on that pass.
        $calls.Throw = $true; $calls.Now = 70000; $calls.Mem = [long]7GB
        Invoke-WorkstationTick -State $state -Context $ctx -NowMs 70000
        $state.workstationError | Should -Match '^memory: '
        $state.wsl.mem | Should -Be 7GB
        # A clean pass clears it.
        $calls.Throw = $false; $calls.Now = 75000; $calls.Snap = Get-WsSnapshot 1 70
        Invoke-WorkstationTick -State $state -Context $ctx -NowMs 75000
        $state['workstationError'] | Should -BeNullOrEmpty
    }
}
#endregion 92

#region 93 The AI server (#93)
# Spec section 6 and Q9; plan Shared interfaces, region 93; test plan 6.13. The values below come from the fixtures
# system_stats.json (ComfyUI 0.3.99, the first device) and prompt.json (queue 2).
Describe 'T93-04 the reader refuses anything but the two GETs on a local port' {
    It 'T93-04 Read-LocalHttp takes only Port, Path, TimeoutMs and MaxBytes: no host, URL, method, header or body' {
        $cmd = Get-Command Read-LocalHttp -ErrorAction Stop
        $common = @([Management.Automation.PSCmdlet]::CommonParameters) + @([Management.Automation.PSCmdlet]::OptionalCommonParameters)
        @($cmd.Parameters.Keys | Where-Object { $common -notcontains $_ } | Sort-Object) | Should -Be @('MaxBytes', 'Path', 'Port', 'TimeoutMs')
        $set = @($cmd.Parameters['Path'].Attributes | Where-Object { $_ -is [ValidateSet] })
        $set.Count | Should -Be 1
        @($set[0].ValidValues | Sort-Object) | Should -Be @('/prompt', '/system_stats')
        $range = @($cmd.Parameters['Port'].Attributes | Where-Object { $_ -is [ValidateRange] })
        $range.Count | Should -Be 1
        $range[0].MinRange | Should -Be 1024
        $range[0].MaxRange | Should -Be 65535
    }
    It 'T93-04 <what> is a parameter validation error, so no request is made' -ForEach @(
        @{ what = "Path '/queue'"; params = @{ Port = 8188; Path = '/queue' } }
        @{ what = "Path '/history'"; params = @{ Port = 8188; Path = '/history' } }
        @{ what = "Path '/interrupt'"; params = @{ Port = 8188; Path = '/interrupt' } }
        @{ what = "Path '/api/prompt'"; params = @{ Port = 8188; Path = '/api/prompt' } }
        @{ what = "Path '/prompt?clear=true'"; params = @{ Port = 8188; Path = '/prompt?clear=true' } }
        @{ what = "Path '/system_stats/../queue'"; params = @{ Port = 8188; Path = '/system_stats/../queue' } }
        @{ what = "Path ''"; params = @{ Port = 8188; Path = '' } }
        @{ what = 'Port 80'; params = @{ Port = 80; Path = '/system_stats' } }
        @{ what = 'Port 1023'; params = @{ Port = 1023; Path = '/system_stats' } }
        @{ what = 'Port 65536'; params = @{ Port = 65536; Path = '/system_stats' } }
        @{ what = 'Port 0'; params = @{ Port = 0; Path = '/prompt' } }
    ) {
        $err = $null
        try { Read-LocalHttp @params | Out-Null } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        # Binding fails before the function body runs, so the body can't have opened a connection.
        $err.FullyQualifiedErrorId | Should -BeExactly 'ParameterArgumentValidationError,Read-LocalHttp'
    }
}

Describe 'T93-06 the kept fields of /system_stats' {
    BeforeAll {
        $script:StatsText = [IO.File]::ReadAllText((Join-Path $Fixtures 'system_stats.json'))
        # The fixture changed by $Change (a scriptblock given the parsed reply), as JSON text.
        function Get-ChangedStats([scriptblock]$Change) {
            $o = $StatsText | ConvertFrom-Json
            & $Change $o
            ConvertTo-Json -InputObject $o -Depth 8
        }
    }
    It 'T93-06 the fixture gives exactly version, vramTotal, vramFree, holds and torchFree, and nothing with CANARY' {
        $r = ConvertFrom-ComfyStats -Body $StatsText
        $r | Should -Not -BeNullOrEmpty
        @($r.Keys | Sort-Object) | Should -Be @('holds', 'torchFree', 'version', 'vramFree', 'vramTotal')
        $r.version | Should -BeExactly '0.3.99'
        $r.vramTotal | Should -Be 25769803776
        $r.vramFree | Should -Be 8589934592
        $r.holds | Should -Be 16320875520
        $r.torchFree | Should -Be 536870912
        foreach ($k in 'vramTotal', 'vramFree', 'holds', 'torchFree') { $r[$k] | Should -Not -BeOfType [string] -Because "$k is a number" }
        (ConvertTo-Json -InputObject $r -Compress -Depth 5) | Should -Not -Match 'CANARY'
        foreach ($v in $r.Values) { [string]$v | Should -Not -Match 'CANARY|main\.py|--listen|posix|cuda|GCC|cu128' }
    }
    It 'T93-06 the numbers come from the first device when there are two' {
        $body = Get-ChangedStats {
            param($o)
            $second = $o.devices[0].PSObject.Copy()
            $second.name = 'cuda:1 Other GPU'; $second.index = 1
            $second.vram_total = 1; $second.vram_free = 2; $second.torch_vram_total = 3; $second.torch_vram_free = 4
            $o.devices = @($o.devices[0], $second)
        }
        $r = ConvertFrom-ComfyStats -Body $body
        $r.vramTotal | Should -Be 25769803776
        $r.vramFree | Should -Be 8589934592
        $r.holds | Should -Be 16320875520
        $r.torchFree | Should -Be 536870912
    }
    It 'T93-06 <what> gives $null, without an exception' -ForEach @(
        @{ what = 'no devices'; change = { param($o) $o.devices = @() } }
        @{ what = 'no devices key'; change = { param($o) $o.PSObject.Properties.Remove('devices') } }
        @{ what = 'no system'; change = { param($o) $o.PSObject.Properties.Remove('system') } }
        @{ what = 'numbers as strings'; change = { param($o) $d = $o.devices[0]; foreach ($k in 'vram_total', 'vram_free', 'torch_vram_total', 'torch_vram_free') { $d.$k = [string]$d.$k } } }
        @{ what = 'vram_total alone as a string'; change = { param($o) $o.devices[0].vram_total = [string]$o.devices[0].vram_total } }
        @{ what = 'torch_vram_total alone as a string'; change = { param($o) $o.devices[0].torch_vram_total = [string]$o.devices[0].torch_vram_total } }
    ) {
        $body = Get-ChangedStats $change
        $r = ConvertFrom-ComfyStats -Body $body
        $null -eq $r | Should -BeTrue -Because $what
    }
    It 'T93-06 a reply that is not JSON, or JSON of another shape, gives $null: <what>' -ForEach @(
        @{ what = 'HTML'; body = '<html><body>This is not ComfyUI.</body></html>' }
        @{ what = 'cut off'; body = '{"system": {"comfyui_version": "0.3.99", "argv": ["--CANARY-ARGV"' }
        @{ what = 'empty'; body = '' }
        @{ what = 'JSON null'; body = 'null' }
        @{ what = 'a JSON array'; body = '[]' }
        @{ what = 'a JSON number'; body = '42' }
        @{ what = 'a JSON string'; body = '"ok"' }
    ) {
        $r = ConvertFrom-ComfyStats -Body $body
        $null -eq $r | Should -BeTrue -Because $what
    }
}

Describe 'T93-07 the queue from /prompt' {
    It 'T93-07 the fixture gives 2, as an int' {
        $r = ConvertFrom-ComfyQueue -Body ([IO.File]::ReadAllText((Join-Path $Fixtures 'prompt.json')))
        $r | Should -Be 2
        $r | Should -BeOfType [int]
    }
    It 'T93-07 {"exec_info":{"queue_remaining":<n>}} gives <n>' -ForEach @(@{ n = 2 }, @{ n = 0 }) {
        $r = ConvertFrom-ComfyQueue -Body ('{"exec_info":{"queue_remaining":' + $n + '}}')
        $null -eq $r | Should -BeFalse
        $r | Should -Be $n
        $r | Should -BeOfType [int]
    }
    It 'T93-07 <what> gives $null, without an exception' -ForEach @(
        @{ what = 'a negative count'; body = '{"exec_info":{"queue_remaining":-1}}' }
        @{ what = 'the count as a string'; body = '{"exec_info":{"queue_remaining":"2"}}' }
        @{ what = 'a fractional count'; body = '{"exec_info":{"queue_remaining":2.5}}' }
        @{ what = 'no queue_remaining'; body = '{"exec_info":{}}' }
        @{ what = 'no exec_info'; body = '{}' }
        @{ what = 'exec_info not an object'; body = '{"exec_info":2}' }
        @{ what = 'junk'; body = '<html><body>This is not ComfyUI.</body></html>' }
        @{ what = 'empty'; body = '' }
        @{ what = 'JSON null'; body = 'null' }
        @{ what = 'a JSON array'; body = '[]' }
    ) {
        $r = ConvertFrom-ComfyQueue -Body $body
        $null -eq $r | Should -BeTrue -Because $what
    }
}

Describe 'T93-08 to T93-10 the AI server states and the job timer' {
    BeforeAll {
        $script:T0 = 1795000000000   # a fixed time in ms since 1970; steps are seconds after it
        $script:Kept = @{ version = '0.3.99'; vramTotal = 25769803776; vramFree = 8589934592; holds = 16320875520; torchFree = 536870912 }
        $script:RowKeys = @('holds', 'lastDoneSec', 'lastDoneTs', 'name', 'queue', 'state', 'version', 'vramFree', 'vramTotal', 'workingSec') | Sort-Object
        function New-MainWatch { New-AiWatch -Entries @(@{ Name = 'Main'; Port = 8188 }) }
        function Get-Answer([int]$Queue) { @{ Ok = $true; Stats = $Kept.Clone(); Queue = $Queue } }
        function Get-Miss { @{ Ok = $false; Stats = $null; Queue = $null } }
        # One reading of entry Main, $Seconds after T0, with the VM running ($true), not running ($false) or unknown ($null).
        function Invoke-AiStep($Watch, [hashtable]$Answer, $Vm, [double]$Seconds) {
            Update-AiWatch -Watch $Watch -Name 'Main' -Answer $Answer -VmRunning $Vm -NowMs ([long]($T0 + $Seconds * 1000))
        }
    }

    It 'T93-08 off, then starting once the VM runs and the entry has not answered in it' {
        $w = New-MainWatch
        $r = Invoke-AiStep $w (Get-Miss) $false 0
        $r.name | Should -BeExactly 'Main'
        $r.state | Should -BeExactly 'off'
        (Invoke-AiStep $w (Get-Miss) $true 5).state | Should -BeExactly 'starting'
    }
    It 'T93-08 starting to idle: queue 0, holds, the card as ComfyUI sees it, the version, and exactly the row keys' {
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Miss) $true 0
        $r = Invoke-AiStep $w (Get-Answer 0) $true 5
        $r.state | Should -BeExactly 'idle'
        $r.name | Should -BeExactly 'Main'
        $r.queue | Should -Be 0
        $r.holds | Should -Be 16320875520
        $r.vramTotal | Should -Be 25769803776
        $r.vramFree | Should -Be 8589934592
        $r.version | Should -BeExactly '0.3.99'
        @($r.Keys | Sort-Object) | Should -Be $RowKeys
    }
    It 'T93-08 idle to working: queue 2, workingSec 0 on the first working reading' {
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Answer 0) $true 0
        $r = Invoke-AiStep $w (Get-Answer 2) $true 5
        $r.state | Should -BeExactly 'working'
        $r.queue | Should -Be 2
        $r.workingSec | Should -Be 0
    }
    It 'T93-08 the 1st and 2nd misses hold the last row (<from>), the 3rd with the VM up is not-answering' -ForEach @(
        @{ from = 'idle'; queue = 0 }, @{ from = 'working'; queue = 2 }
    ) {
        $w = New-MainWatch
        $last = Invoke-AiStep $w (Get-Answer $queue) $true 0
        $last.state | Should -BeExactly $from
        foreach ($s in 5, 10) {
            $r = Invoke-AiStep $w (Get-Miss) $true $s
            $r.state | Should -BeExactly $from -Because "miss at $s s is held"
            $r.queue | Should -Be $queue
            $r.holds | Should -Be 16320875520
            $r.version | Should -BeExactly '0.3.99'
        }
        (Invoke-AiStep $w (Get-Miss) $true 15).state | Should -BeExactly 'not-answering'
    }
    It 'T93-08 not-answering to idle when it answers again' {
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Answer 0) $true 0
        foreach ($s in 5, 10, 15) { $r = Invoke-AiStep $w (Get-Miss) $true $s }
        $r.state | Should -BeExactly 'not-answering'
        (Invoke-AiStep $w (Get-Answer 0) $true 20).state | Should -BeExactly 'idle'
    }
    It 'T93-08 <from>, answered with the VM up, then the VM gone and no answer: off at once' -ForEach @(
        @{ from = 'idle' }, @{ from = 'working' }, @{ from = 'unknown' }, @{ from = 'not-answering' }
    ) {
        $w = New-MainWatch
        switch ($from) {
            'idle' { $r = Invoke-AiStep $w (Get-Answer 0) $true 0 }
            'working' { $r = Invoke-AiStep $w (Get-Answer 3) $true 0 }
            'unknown' { $r = Invoke-AiStep $w @{ Ok = $true; Stats = $null; Queue = 0 } $true 0 }
            'not-answering' {
                $null = Invoke-AiStep $w (Get-Answer 0) $true 0
                foreach ($s in 5, 10, 15) { $r = Invoke-AiStep $w (Get-Miss) $true $s }
            }
        }
        $r.state | Should -BeExactly $from
        (Invoke-AiStep $w (Get-Miss) $false 20).state | Should -BeExactly 'off' -Because 'the VM it ran in has gone, so no miss is held'
    }
    It 'T93-08 an answer with bad stats or no queue is unknown, and unknown counts as answering' {
        $w = New-MainWatch
        (Invoke-AiStep $w @{ Ok = $true; Stats = $null; Queue = 0 } $true 0).state | Should -BeExactly 'unknown'
        (Invoke-AiStep $w (Get-Miss) $true 5).state | Should -BeExactly 'unknown' -Because 'the 1st miss after an unknown reply is held'
        $w2 = New-MainWatch
        (Invoke-AiStep $w2 @{ Ok = $true; Stats = $Kept.Clone(); Queue = $null } $true 0).state | Should -BeExactly 'unknown'
    }
    It 'T93-08 the VM unknown ($null): off until it has answered once (never starting), then the miss rule gives not-answering' {
        $w = New-MainWatch
        foreach ($s in 0, 5, 10, 15) { (Invoke-AiStep $w (Get-Miss) $null $s).state | Should -BeExactly 'off' -Because "no answer yet at $s s" }
        (Invoke-AiStep $w (Get-Answer 0) $null 20).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $null 25).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $null 30).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $null 35).state | Should -BeExactly 'not-answering'
    }
    It 'T93-08 the VM down all along (ComfyUI on Windows): answered, then held twice, then not-answering' {
        $w = New-MainWatch
        (Invoke-AiStep $w (Get-Answer 0) $false 0).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $false 5).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $false 10).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $false 15).state | Should -BeExactly 'not-answering'
    }

    It 'T93-09 answered, the VM down, then up again with no answer: off, then starting, never not-answering' {
        $w = New-MainWatch
        (Invoke-AiStep $w (Get-Answer 0) $true 0).state | Should -BeExactly 'idle'
        (Invoke-AiStep $w (Get-Miss) $false 5).state | Should -BeExactly 'off'
        foreach ($s in 10, 15, 20, 25, 30) {
            (Invoke-AiStep $w (Get-Miss) $true $s).state | Should -BeExactly 'starting' -Because "the new VM's entry has not answered yet at $s s"
        }
        (Invoke-AiStep $w (Get-Answer 0) $true 35).state | Should -BeExactly 'idle'
    }

    It 'T93-10 one batch: queue 5 at 0 s, 3 at 30 s, a held miss at 40 s, 3 at 50 s, 0 at 70 s: one lastDone at 70 s, 70 s long' {
        $w = New-MainWatch
        $r = Invoke-AiStep $w (Get-Answer 5) $true 0
        $r.state | Should -BeExactly 'working'
        $r.workingSec | Should -Be 0
        $null -eq $r.lastDoneTs | Should -BeTrue
        (Invoke-AiStep $w (Get-Answer 3) $true 30).workingSec | Should -Be 30
        (Invoke-AiStep $w (Get-Miss) $true 40).state | Should -BeExactly 'working'
        (Invoke-AiStep $w (Get-Answer 3) $true 50).workingSec | Should -Be 50 -Because 'WorkingSinceMs is kept across the held miss'
        $r = Invoke-AiStep $w (Get-Answer 0) $true 70
        $r.state | Should -BeExactly 'idle'
        $r.lastDoneTs | Should -Be ($T0 + 70000)
        $r.lastDoneSec | Should -Be 70
        $r = Invoke-AiStep $w (Get-Answer 0) $true 75
        $r.lastDoneTs | Should -Be ($T0 + 70000) -Because 'an idle reading after the batch is not a second batch'
        $r.lastDoneSec | Should -Be 70
        $r = Invoke-AiStep $w (Get-Answer 2) $true 80
        $r.state | Should -BeExactly 'working'
        $r.workingSec | Should -Be 0 -Because 'a new batch starts its own timer'
        $r.lastDoneTs | Should -Be ($T0 + 70000) -Because 'the last batch stays on the row while the next one works'
    }
    It 'T93-10 a 59 s run sets no lastDone; a 60 s run does' {
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Answer 1) $true 0
        $r = Invoke-AiStep $w (Get-Answer 0) $true 59
        $r.state | Should -BeExactly 'idle'
        $null -eq $r.lastDoneTs | Should -BeTrue
        $null -eq $r.lastDoneSec | Should -BeTrue
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Answer 1) $true 0
        $r = Invoke-AiStep $w (Get-Answer 0) $true 60
        $r.lastDoneTs | Should -Be ($T0 + 60000)
        $r.lastDoneSec | Should -Be 60
    }
    It 'T93-10 the clock 10,000 ms backwards while working: workingSec 0, never negative, and no lastDone' {
        $w = New-MainWatch
        $null = Invoke-AiStep $w (Get-Answer 2) $true 0
        foreach ($s in -10, -5) {
            $r = Invoke-AiStep $w (Get-Answer 2) $true $s
            $r.state | Should -BeExactly 'working'
            $r.workingSec | Should -Be 0 -Because "the clock is $(-$s) s behind the job's start"
        }
        $r = Invoke-AiStep $w (Get-Answer 0) $true -1
        $r.state | Should -BeExactly 'idle'
        $null -eq $r.lastDoneTs | Should -BeTrue -Because 'a job that seems to end before it started is not a 60 s job'
        $null -eq $r.lastDoneSec | Should -BeTrue
    }
}

Describe 'T93-11 the AI server events' {
    BeforeAll {
        function New-AiRow([string]$Name, [string]$State, $LastDoneTs = $null, $LastDoneSec = $null) {
            @{ name = $Name; state = $State; queue = $(if ($State -eq 'working') { 2 } else { 0 }); workingSec = 0; holds = 16320875520
               vramTotal = 25769803776; vramFree = 8589934592; version = '0.3.99'; lastDoneTs = $LastDoneTs; lastDoneSec = $LastDoneSec }
        }
        # The records for two readings that carry only ai rows (no gpuSpill, so #91's part adds nothing).
        function Get-AiEvents($OldRows, $NewRows) {
            $old = if ($null -eq $OldRows) { $null } else { @{ ai = @($OldRows) } }
            , @(Get-WorkstationEvents -Old $old -New @{ ai = @($NewRows) })
        }
        $script:Ts = 1795000070000
    }
    It 'T93-11 working to not-answering gives one ai-stopped-answering, Data name only, Key ai-stopped-answering|Main' {
        $e = Get-AiEvents (New-AiRow 'Main' 'working') (New-AiRow 'Main' 'not-answering')
        $e.Count | Should -Be 1
        $e[0].Type | Should -BeExactly 'ai-stopped-answering'
        @($e[0].Data.Keys) | Should -Be @('name')
        $e[0].Data.name | Should -BeExactly 'Main'
        $e[0].Key | Should -BeExactly 'ai-stopped-answering|Main'
    }
    It 'T93-11 <from> to <to> gives nothing' -ForEach @(
        @{ from = 'idle'; to = 'not-answering' }, @{ from = 'unknown'; to = 'not-answering' }, @{ from = 'starting'; to = 'not-answering' }
        @{ from = 'working'; to = 'off' }, @{ from = 'working'; to = 'idle' }, @{ from = 'working'; to = 'working' }
    ) {
        (Get-AiEvents (New-AiRow 'Main' $from) (New-AiRow 'Main' $to)).Count | Should -Be 0
    }
    It 'T93-11 a new lastDoneTs with 840 s gives one ai-job-done: Data name Main and seconds 840, Key ai-job-done|Main|lastDoneTs' {
        $e = Get-AiEvents (New-AiRow 'Main' 'working') (New-AiRow 'Main' 'idle' $Ts 840)
        $e.Count | Should -Be 1
        $e[0].Type | Should -BeExactly 'ai-job-done'
        @($e[0].Data.Keys | Sort-Object) | Should -Be @('name', 'seconds')
        $e[0].Data.name | Should -BeExactly 'Main'
        $e[0].Data.seconds | Should -Be 840
        $e[0].Key | Should -BeExactly "ai-job-done|Main|$Ts"
    }
    It 'T93-11 a second batch (a different lastDoneTs) gives its own ai-job-done with its own key' {
        $e = Get-AiEvents (New-AiRow 'Main' 'working' ($Ts - 3600000) 300) (New-AiRow 'Main' 'idle' $Ts 120)
        $e.Count | Should -Be 1
        $e[0].Type | Should -BeExactly 'ai-job-done'
        $e[0].Data.seconds | Should -Be 120
        $e[0].Key | Should -BeExactly "ai-job-done|Main|$Ts"
    }
    It 'T93-11 the same lastDoneTs again gives nothing' {
        (Get-AiEvents (New-AiRow 'Main' 'idle' $Ts 840) (New-AiRow 'Main' 'idle' $Ts 840)).Count | Should -Be 0
        (Get-AiEvents (New-AiRow 'Main' 'idle' $Ts 840) (New-AiRow 'Main' 'working' $Ts 840)).Count | Should -Be 0
    }
    It 'T93-11 Old $null gives nothing, even with a new lastDoneTs or not-answering' {
        (Get-AiEvents $null (New-AiRow 'Main' 'idle' $Ts 840)).Count | Should -Be 0
        (Get-AiEvents $null (New-AiRow 'Main' 'not-answering')).Count | Should -Be 0
    }
    It 'T93-11 two entries are each compared by name, in any order' {
        $old = @((New-AiRow 'Main' 'working'), (New-AiRow 'Second' 'working'))
        $new = @((New-AiRow 'Second' 'idle' $Ts 840), (New-AiRow 'Main' 'not-answering'))
        $e = Get-AiEvents $old $new
        $e.Count | Should -Be 2
        @($e | ForEach-Object { $_.Key } | Sort-Object) | Should -Be @("ai-job-done|Second|$Ts", 'ai-stopped-answering|Main')
        ($e | Where-Object { $_.Type -eq 'ai-job-done' }).Data.name | Should -BeExactly 'Second'
        ($e | Where-Object { $_.Type -eq 'ai-stopped-answering' }).Data.name | Should -BeExactly 'Main'
    }
}

Describe 'T93-13 the AI part of the workstation tick' {
    BeforeAll {
        $script:StatsText = [IO.File]::ReadAllText((Join-Path $Fixtures 'system_stats.json'))
        $script:PromptText = [IO.File]::ReadAllText((Join-Path $Fixtures 'prompt.json'))   # queue 2
        $script:Entries = @(@{ Name = 'Main'; Port = 8188 }, @{ Name = 'Second'; Port = 8288 })
        $script:Luid = '0x00000000_0x0000a1b2'
        # A Counters snapshot the other parts can read: Memory, one Process and its video memory.
        function Get-Snapshot {
            New-FakeSnapshot @{
                'Memory'             = @{ 'Committed Bytes' = @{ '' = 31GB }; 'Commit Limit' = @{ '' = 96GB }; 'Pages Input/sec' = @{ '' = 0 } }
                'Process'            = @{ '% Processor Time' = @{ 'editor' = 0 }; 'Working Set - Private' = @{ 'editor' = 100MB }; 'ID Process' = @{ 'editor' = 4242 } }
                'GPU Process Memory' = @{ 'Dedicated Usage' = @{ "pid_4242_luid_$($Luid)_phys_0" = 50MB } }
            }
        }
        # A counting Http reader: records "<port> <path>" per call; a port in $FailStats fails /system_stats, and
        # a port in $Throw throws.
        function New-CountingHttp([System.Collections.Generic.List[string]]$Calls, [int[]]$FailStats = @(), [int[]]$Throw = @()) {
            $stats = $StatsText; $prompt = $PromptText
            {
                param($Port, $Path)
                $Calls.Add("$Port $Path")
                if ($Throw -contains $Port) { throw 'fake reader failure' }
                if ($Path -eq '/system_stats' -and $FailStats -contains $Port) { return @{ Ok = $false; Status = 0; Body = ''; Error = 'The operation has timed out' } }
                $body = if ($Path -eq '/system_stats') { $stats } else { $prompt }
                @{ Ok = $true; Status = 200; Body = $body; Error = '' }
            }.GetNewClosure()
        }
        function New-Context([object[]]$ComfyEntries, [scriptblock]$Http) {
            $snap = Get-Snapshot
            $readers = @{
                Counters   = { $snap }.GetNewClosure()
                WslProcess = { [pscustomobject]@{ ProcessName = 'vmmemWSL'; Id = 4343; WorkingSet64 = 31GB } }
                WslConfig  = { $null }
                Http       = $Http
            }
            New-WorkstationContext -ComfyEntries $ComfyEntries -GpuLuid $Luid -Cores 4 -TotalRam 64GB -Readers $readers
        }
    }
    It 'T93-13 both Ok: per entry /system_stats then /prompt, 2 calls each, and a row per entry from the replies' {
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-Context $Entries (New-CountingHttp $calls)
        $state = @{}
        Invoke-WorkstationTick -State $state -Context $ctx -NowMs 1795000000000
        @($calls) | Should -Be @('8188 /system_stats', '8188 /prompt', '8288 /system_stats', '8288 /prompt')
        $state.ai -is [array] | Should -BeTrue
        @($state.ai).Count | Should -Be 2
        @($state.ai | ForEach-Object { $_.name }) | Should -Be @('Main', 'Second')
        foreach ($row in $state.ai) {
            $row.state | Should -BeExactly 'working'
            $row.queue | Should -Be 2
            $row.holds | Should -Be 16320875520
            $row.version | Should -BeExactly '0.3.99'
        }
    }
    It 'T93-13 /system_stats failing: only /system_stats for that entry, the other entry still gets both' {
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-Context $Entries (New-CountingHttp $calls -FailStats @(8188))
        Invoke-WorkstationTick -State @{} -Context $ctx -NowMs 1795000000000
        @($calls) | Should -Be @('8188 /system_stats', '8288 /system_stats', '8288 /prompt')
    }
    It 'T93-13 at most 2 calls per entry per tick, and $State.ai a new array each tick' {
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-Context $Entries (New-CountingHttp $calls)
        $state = @{}
        $before = $null
        foreach ($i in 0..2) {
            $calls.Clear()
            Invoke-WorkstationTick -State $state -Context $ctx -NowMs (1795000000000 + 5000 * $i)
            foreach ($port in 8188, 8288) { @($calls | Where-Object { $_ -like "$port *" }).Count | Should -BeLessOrEqual 2 }
            $state.ai -is [array] | Should -BeTrue
            if ($null -ne $before) { [object]::ReferenceEquals($before, $state.ai) | Should -BeFalse -Because "tick $i publishes a new array" }
            $before = $state.ai
        }
    }
    It 'T93-13 one entry still gives an array of one row' {
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-Context @($Entries[0]) (New-CountingHttp $calls)
        $state = @{}
        Invoke-WorkstationTick -State $state -Context $ctx -NowMs 1795000000000
        $state.ai -is [array] | Should -BeTrue
        @($state.ai).Count | Should -Be 1
    }
    It 'T93-13 a reader that times out costs one call per entry, one that throws costs the ai part only: the other slow checks still run' {
        $calls = New-Object System.Collections.Generic.List[string]
        $ctx = New-Context $Entries (New-CountingHttp $calls -FailStats @(8188, 8288))
        $state = @{}
        Invoke-WorkstationTick -State $state -Context $ctx -NowMs 1795000000000
        @($calls) | Should -Be @('8188 /system_stats', '8288 /system_stats') -Because 'a hung AI server costs one timeout per entry, never two'
        $state.ContainsKey('memCommit') | Should -BeTrue
        $state.ContainsKey('wsl') | Should -BeTrue
        $state.ContainsKey('top') | Should -BeTrue
        [string]$state.workstationError | Should -Not -Match '^ai server: ' -Because 'no reply is a miss, not an error of the tick'
        $calls2 = New-Object System.Collections.Generic.List[string]
        $ctx2 = New-Context $Entries (New-CountingHttp $calls2 -Throw @(8188))
        $state2 = @{}
        Invoke-WorkstationTick -State $state2 -Context $ctx2 -NowMs 1795000000000
        $state2.workstationError | Should -Match '^ai server: '
        $state2.ContainsKey('memCommit') | Should -BeTrue
        $state2.ContainsKey('wsl') | Should -BeTrue
        $state2.ContainsKey('top') | Should -BeTrue
    }
}

Describe 'T93-03 the local reader against the fake AI server' -Tag 'Integration' {
    BeforeAll {
        Import-Module (Join-Path (Get-RepoRoot) 'tests\fakes\FakeComfyUi.psm1') -Force
        $script:StatsText = [IO.File]::ReadAllText((Join-Path $Fixtures 'system_stats.json'))
        function Measure-Read([scriptblock]$Call) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = & $Call
            $sw.Stop()
            @{ Result = $r; Ms = $sw.ElapsedMilliseconds }
        }
        # Every request the fake saw that isn't a plain GET of one of the two paths, with Host 127.0.0.1:<port> and
        # no body, credentials or cookies.
        function Get-OddRequests($Fake) {
            @($Fake.Requests | Where-Object {
                $_.Line -cnotmatch '^GET /(system_stats|prompt) HTTP/1\.1$' -or $_.Host -cne "127.0.0.1:$($Fake.Port)" -or
                $_.ContentLength -or $_.TransferEncoding -or $_.BodyBytes -ne 0 -or
                @($_.Headers | Where-Object { $_ -match '^(Authorization|Cookie|Proxy-Authorization):' }).Count
            } | ForEach-Object { "$($_.Line) [Host $($_.Host)]" })
        }
    }
    It 'T93-03 an answer: Ok, status 200 and the body; the fake saw GET /system_stats HTTP/1.1, Host 127.0.0.1 and its port, no body' {
        $fake = Start-FakeComfyUi -Mode answer -Queue 3
        try {
            $r = Read-LocalHttp -Port $fake.Port -Path '/system_stats'
            $r.Ok | Should -BeTrue
            $r.Status | Should -Be 200
            $r.Body | Should -BeExactly $StatsText
            $q = Read-LocalHttp -Port $fake.Port -Path '/prompt'
            $q.Ok | Should -BeTrue
            ($q.Body | ConvertFrom-Json).exec_info.queue_remaining | Should -Be 3
            $seen = @($fake.Requests)
            $seen.Count | Should -Be 2
            $seen[0].Line | Should -BeExactly 'GET /system_stats HTTP/1.1'
            $seen[0].Host | Should -BeExactly "127.0.0.1:$($fake.Port)"
            $seen[0].ContentLength | Should -BeNullOrEmpty
            $seen[0].TransferEncoding | Should -BeNullOrEmpty
            $seen[0].BodyBytes | Should -Be 0
            $seen[1].Line | Should -BeExactly 'GET /prompt HTTP/1.1'
            Get-OddRequests $fake | Should -BeNullOrEmpty
        } finally { & $fake.Stop }
    }
    It 'T93-03 a closed port: Ok false in under 2,500 ms' {
        $port = Get-FreePort
        $t = Measure-Read { Read-LocalHttp -Port $port -Path '/system_stats' }
        $t.Result.Ok | Should -BeFalse
        $t.Result.Error | Should -Not -BeNullOrEmpty
        $t.Ms | Should -BeLessThan 2500 -Because 'Windows retries a refused connection for about 2 s; the lead set this bound (2026-11-27)'
    }
    It 'T93-03 an AI server that accepts but sends nothing for 3 s: Ok false in under 2,500 ms, after the 2,000 ms timeout' {
        $fake = Start-FakeComfyUi -Mode slow -DelayMs 3000
        try {
            $t = Measure-Read { Read-LocalHttp -Port $fake.Port -Path '/system_stats' }
            $t.Result.Ok | Should -BeFalse
            $t.Result.Error | Should -Not -BeNullOrEmpty
            $t.Ms | Should -BeLessThan 2500
            $t.Ms | Should -BeGreaterThan 1500 -Because 'the default timeout is 2,000 ms'
            Get-OddRequests $fake | Should -BeNullOrEmpty
        } finally { & $fake.Stop }
    }
    It 'T93-03 a reply 1 s late is still read (Ok), and -TimeoutMs 500 gives up on a 3 s one in under 1,000 ms' {
        $late = Start-FakeComfyUi -Mode slow -DelayMs 1000
        try { (Read-LocalHttp -Port $late.Port -Path '/system_stats').Ok | Should -BeTrue } finally { & $late.Stop }
        $slow = Start-FakeComfyUi -Mode slow -DelayMs 3000
        try {
            $t = Measure-Read { Read-LocalHttp -Port $slow.Port -Path '/system_stats' -TimeoutMs 500 }
            $t.Result.Ok | Should -BeFalse
            $t.Ms | Should -BeLessThan 1000
        } finally { & $slow.Stop }
    }
    It 'T93-03 a reply that sends its headers and then trickles bytes: Ok false within TimeoutMs plus a small margin (one deadline for the whole request)' {
        $fake = Start-FakeComfyUi -Mode trickle -DelayMs 8000
        try {
            $t = Measure-Read { Read-LocalHttp -Port $fake.Port -Path '/system_stats' -TimeoutMs 1000 }
            $t.Result.Ok | Should -BeFalse
            $t.Result.Error | Should -Not -BeNullOrEmpty
            $t.Ms | Should -BeLessThan 1600 -Because 'the timeout covers the whole request, not each Read'
            $t.Ms | Should -BeGreaterThan 800
        } finally { & $fake.Stop }
    }
    It 'T93-03 a 262,145-byte body: Ok false, Error "reply too large"' {
        $fake = Start-FakeComfyUi -Mode huge -Bytes 262145
        try {
            $r = Read-LocalHttp -Port $fake.Port -Path '/system_stats'
            $r.Ok | Should -BeFalse
            $r.Error | Should -BeExactly 'reply too large'
        } finally { & $fake.Stop }
    }
    It 'T93-03 a 262,144-byte body: Ok, all of it read' {
        $fake = Start-FakeComfyUi -Mode huge -Bytes 262144
        try {
            $r = Read-LocalHttp -Port $fake.Port -Path '/system_stats'
            $r.Ok | Should -BeTrue
            $r.Status | Should -Be 200
            $r.Body.Length | Should -Be 262144
        } finally { & $fake.Stop }
    }
    It 'T93-03 status 500: Ok false' {
        $fake = Start-FakeComfyUi -Mode status500
        try {
            $r = Read-LocalHttp -Port $fake.Port -Path '/system_stats'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Not -BeNullOrEmpty
            Get-OddRequests $fake | Should -BeNullOrEmpty
        } finally { & $fake.Stop }
    }
    It 'T93-03 a 302: Ok false, and the redirect is not followed' {
        $fake = Start-FakeComfyUi -Mode redirect
        try {
            $r = Read-LocalHttp -Port $fake.Port -Path '/system_stats'
            $r.Ok | Should -BeFalse
            @($fake.Requests).Count | Should -Be 1 -Because 'the 302 points at /history on the same fake'
            @($fake.Requests)[0].Line | Should -BeExactly 'GET /system_stats HTTP/1.1'
        } finally { & $fake.Stop }
    }
    It 'T93-04 a path outside the two never reaches a listening AI server' {
        $fake = Start-FakeComfyUi -Mode answer
        try {
            foreach ($path in '/queue', '/history', '/interrupt', '/free', '/upload/image') {
                { Read-LocalHttp -Port $fake.Port -Path $path } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Read-LocalHttp'
            }
            @($fake.Requests).Count | Should -Be 0
        } finally { & $fake.Stop }
    }
}
#endregion 93
