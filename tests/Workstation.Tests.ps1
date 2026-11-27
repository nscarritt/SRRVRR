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
#endregion 93
