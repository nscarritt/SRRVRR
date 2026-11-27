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
#endregion 92

#region 93 The AI server (#93)
#endregion 93
