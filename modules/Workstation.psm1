# The Workstation role (docs/specs/2026-11-26-srrvrr-workstation-design.md): the role plan and host name, video
# memory and GPU detail, memory detail and top programs, the AI server. Pure functions: no clock, counter, process,
# file or network calls; callers pass readings, readers and times in. The one exception is Read-LocalHttp (region
# 93), the only network call, which is fixed to GET on 127.0.0.1. One region per story
# (docs/plans/2026-11-26-srrvrr-v0.10.0-implementation-plan.md, Shared interfaces): change only your own.
# Every function is exported (no Export-ModuleMember), so the regions never share a line.
Set-StrictMode -Version 2

#region 90 Roles and the host name (#90)
# What runs for a role (validated before this is called; any case).
function Get-RolePlan {
    param([string]$Role)
    if ($Role -eq 'Workstation') {
        return @{ Role = 'workstation'; Processes = $false; Tracer = $false; Workstation = $true
                  HistoryLines = [string[]]@('cpu', 'mem', 'gpu', 'rx', 'tx', 'vram', 'vramShared') }
    }
    @{ Role = 'server'; Processes = $true; Tracer = $true; Workstation = $false
       HistoryLines = [string[]]@('cpu', 'mem', 'gpu', 'rx', 'tx') }
}

# The name on the page: the setting, else the computer name on a Workstation, else SRRVRR.
function Resolve-DisplayName {
    param([string]$Setting, [string]$Role, [string]$ComputerName)
    if ($Setting) { return [string]$Setting }
    if ($Role -eq 'workstation' -and $ComputerName) { return [string]$ComputerName }
    'SRRVRR'
}

# The startup lines for a plan, printed with Write-Status and logged.
function Format-RoleLines {
    param([hashtable]$Plan)
    if ($Plan.Workstation) {
        return [string[]]@('Role: Workstation. Off: Processes. On: video memory, top programs, AI server',
                           'Not used on a workstation: Processes, ValheimPort')
    }
    [string[]]@('Role: Server')
}
#endregion 90

#region 91 Video memory and GPU detail (#91)
# The nvidia-smi query for the detail fields. Returns the two arguments (the comma binds tighter than +, so the
# first is built in parentheses).
function Get-SmiArguments {
    param([Parameter(Mandatory)][ValidateSet('clocks_event_reasons', 'clocks_throttle_reasons')][string]$Prefix)
    $query = '--query-gpu=name,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.max.sm,fan.speed,pstate,' +
        "$Prefix.sw_power_cap,$Prefix.hw_slowdown,$Prefix.sw_thermal_slowdown,$Prefix.hw_thermal_slowdown,$Prefix.hw_power_brake_slowdown"
    [string[]]@($query, '--format=csv,noheader,nounits')
}

# Which field-name prefix this driver knows. Each query is @{ Lines = [string[]]; ExitCode = [int] } or $null.
function Select-SmiPrefix {
    param([hashtable]$Event, [hashtable]$Throttle)
    if ($null -eq $Event) { return 'none' }
    if ($Event.ExitCode -eq 0) { return 'clocks_event_reasons' }
    $unknown = $false
    foreach ($l in @($Event.Lines)) { if ("$l" -match 'is not a valid field to query') { $unknown = $true } }
    if ($unknown -and $null -ne $Throttle -and $Throttle.ExitCode -eq 0) { return 'clocks_throttle_reasons' }
    'none'
}

# One nvidia-smi line's number, or $null for [N/A], empty, Not Supported or anything not a number.
function ConvertTo-SmiNumber {
    param([string[]]$Fields, [int]$Index)
    if ($Index -ge $Fields.Count) { return $null }
    $d = 0.0
    if ([double]::TryParse($Fields[$Index], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    $null
}

# The reading for the named card (or the only line); $null when there is no such line or it isn't a reading.
function ConvertFrom-SmiDetail {
    param([string[]]$Lines, [string]$GpuName)
    $rows = @()
    foreach ($l in @($Lines)) { if ($l -and $l.Trim()) { $rows += , @($l -split ',' | ForEach-Object { $_.Trim() }) } }
    $pick = $null
    foreach ($r in $rows) { if ($r[0] -eq $GpuName) { $pick = $r; break } }
    if (-not $pick -and $rows.Count -eq 1) { $pick = $rows[0] }
    if (-not $pick -or $pick.Count -lt 8) { return $null }
    $f = [string[]]$pick
    $int = { param($i) $v = ConvertTo-SmiNumber -Fields $f -Index $i; if ($null -eq $v) { $null } else { [int]$v } }
    $state = ''
    if ($f[7] -match '^P\d+$') { $state = $f[7] }
    $active = { param($i) ($i -lt $f.Count) -and ($f[$i] -eq 'Active') }
    $limits = New-Object System.Collections.Generic.List[string]
    if ((& $active 8) -or (& $active 12)) { $limits.Add('power') }
    if ((& $active 10) -or (& $active 11)) { $limits.Add('thermal') }
    if (& $active 9) { $limits.Add('slowed') }
    @{ gpuTemp = (& $int 1); gpuPower = (& $int 2); gpuPowerLimit = (& $int 3); gpuClock = (& $int 4); gpuClockMax = (& $int 5)
       gpuFan = (& $int 6); gpuPState = $(if ($state) { $state } else { $null }); gpuLimits = [string[]]$limits.ToArray() }
}

# Events from two detection readings (SRRVRR.ps1 adds each with Add-SrrEvent). The spill: gpuSpill changing.
function Get-WorkstationEvents {
    param([object]$Old, [object]$New)
    $out = New-Object System.Collections.Generic.List[hashtable]
    if ($null -eq $Old -or $null -eq $New) { return }
    if ($Old.ContainsKey('gpuSpill') -and $New.ContainsKey('gpuSpill') -and $Old.gpuSpill -ne $New.gpuSpill) {
        if ($New.gpuSpill) {
            $mem = if ($New.ContainsKey('gpuMem')) { [double]$New.gpuMem } else { 0.0 }
            $shared = if ($New.ContainsKey('gpuShared')) { [double]$New.gpuShared } else { 0.0 }
            $out.Add(@{ Type = 'vram-spill'; Key = 'vram-spill'
                        Data = @{ dedicatedGb = [math]::Round($mem / 1GB, 1); sharedGb = [math]::Round($shared / 1GB, 1) } })
        } else {
            $out.Add(@{ Type = 'vram-spill-ended'; Key = 'vram-spill-ended'; Data = @{} })
        }
    }
    $out.ToArray()
}
#endregion 91

#region 92 Memory detail and top programs (#92)
# Memory detail, the WSL VM and the top programs. Every reading comes through the $Readers the context holds, so
# nothing here reads the machine itself. Snapshots are shaped like PerformanceCounterCategory.ReadCategory():
# category -> counter -> instance -> object with .Sample and .RawValue.

# The value of one counter of a single-instance category (Memory), or $null.
function Get-SingleRaw {
    param($Snapshot, [string]$Category, [string]$Counter)
    if (-not $Snapshot -or -not $Snapshot.ContainsKey($Category)) { return $null }
    $c = $Snapshot[$Category]
    if (-not $c.ContainsKey($Counter)) { return $null }
    foreach ($inst in $c[$Counter].Values) { return $inst }   # the first (only) instance
    $null
}

# Commit and its limit are the current raw values (CounterSample.Calculate goes through a float and loses bytes); paging
# in is Pages Input/sec times the page size, or $null with no previous reading.
function Get-MemoryDetail {
    param($Previous, $Current, [int]$PageSize = 4096)
    $commit = Get-SingleRaw $Current 'Memory' 'Committed Bytes'
    $limit = Get-SingleRaw $Current 'Memory' 'Commit Limit'
    if ($null -eq $commit -or $null -eq $limit) { throw 'the Memory counters have no Committed Bytes or Commit Limit' }
    $pageIn = $null
    $now = Get-SingleRaw $Current 'Memory' 'Pages Input/sec'
    $old = Get-SingleRaw $Previous 'Memory' 'Pages Input/sec'
    if ($now -and $old) {
        $rate = [Diagnostics.CounterSample]::Calculate($old.Sample, $now.Sample)
        $pageIn = [long][math]::Round($rate * $PageSize)
    }
    @{ memCommit = [long]$commit.RawValue; memCommitLimit = [long]$limit.RawValue; memPageIn = $pageIn }
}

# The WSL VM's memory cap: memory= under [wsl2] (a number with KB, MB, GB or TB), else half of RAM.
function ConvertFrom-WslConfig {
    param([string]$Text, [double]$TotalRam)
    $default = @{ Cap = [double]($TotalRam / 2); Source = 'default' }
    if (-not $Text) { return $default }
    $inWsl2 = $false
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -match '^\[(.*)\]$') { $inWsl2 = ($Matches[1].Trim() -ieq 'wsl2'); continue }
        if (-not $inWsl2) { continue }
        if ($line -match '^memory\s*=\s*(.*)$') {
            if ($Matches[1].Trim() -match '^(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)$') {
                $n = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
                $unit = switch ($Matches[2].ToUpperInvariant()) { 'KB' { 1KB } 'MB' { 1MB } 'GB' { 1GB } 'TB' { 1TB } }
                if ($n * $unit -gt 0) { return @{ Cap = [double]($n * $unit); Source = 'config' } }
            }
            return $default
        }
    }
    $default
}

# The WSL VM (the vmmemWSL process): running or not, its working set, and the cap.
function Get-WslReading {
    param([object]$Process, [hashtable]$Cap)
    $mem = $null
    $running = $null -ne $Process
    if ($running) {
        try {
            $ws = $Process.WorkingSet64
            if ($null -ne $ws) { $mem = [long]$ws }   # a property that throws reads as $null, and [long]$null is 0
        } catch { $mem = $null }
    }
    @{ running = $running; mem = $mem
       cap = $(if ($Cap) { $Cap.Cap } else { $null }); capSource = $(if ($Cap) { $Cap.Source } else { $null }) }
}

# Programs (processes grouped by name), the top $Count by video memory and by RAM, at most $MaxRows rows. A program's
# CPU adds up only the instances that are in both readings with the same process id, and is $null with none.
function Get-TopPrograms {
    param($Previous, $Current, [double]$ElapsedSeconds, [int]$Cores, [string]$GpuLuid, [int]$Count = 5, [int]$MaxRows = 8)
    if (-not $Current -or -not $Current.ContainsKey('Process')) { return }
    $proc = $Current['Process']
    if (-not $proc.ContainsKey('ID Process') -or -not $proc.ContainsKey('Working Set - Private')) { return }
    $oldProc = if ($Previous -and $Previous.ContainsKey('Process')) { $Previous['Process'] } else { $null }
    # Video memory on the chosen card, per process id.
    $vramOf = @{}
    if ($Current.ContainsKey('GPU Process Memory') -and $Current['GPU Process Memory'].ContainsKey('Dedicated Usage')) {
        $ded = $Current['GPU Process Memory']['Dedicated Usage']
        foreach ($k in $ded.Keys) {
            if ($k -notmatch '^pid_(\d+)_luid_(\w+?_\w+?)_phys_\d+') { continue }
            if ($GpuLuid -and $Matches[2] -ne $GpuLuid) { continue }
            $id = [int]$Matches[1]
            if (-not $vramOf.ContainsKey($id)) { $vramOf[$id] = [long]0 }
            $vramOf[$id] += [long]$ded[$k].RawValue
        }
    }
    $programs = @{}
    foreach ($inst in @($proc['ID Process'].Keys)) {
        if ($inst -eq '_Total' -or $inst -eq 'Idle') { continue }
        $name = $inst -replace '#\d+$', ''
        if ($name -eq 'vmmemWSL') { $name = 'WSL VM' }
        if (-not $programs.ContainsKey($name)) { $programs[$name] = @{ name = $name; count = 0; vram = [long]0; mem = [long]0; cpu = $null } }
        $p = $programs[$name]
        $id = [int]$proc['ID Process'][$inst].RawValue
        $p.count++
        if ($proc['Working Set - Private'].ContainsKey($inst)) { $p.mem += [long]$proc['Working Set - Private'][$inst].RawValue }
        if ($vramOf.ContainsKey($id)) { $p.vram += $vramOf[$id] }
        # CPU: the same instance, the same process, in both readings.
        if ($oldProc -and $Cores -gt 0 -and $proc.ContainsKey('% Processor Time') -and $oldProc.ContainsKey('% Processor Time') -and $oldProc.ContainsKey('ID Process') -and
            $oldProc['ID Process'].ContainsKey($inst) -and $oldProc['% Processor Time'].ContainsKey($inst) -and $proc['% Processor Time'].ContainsKey($inst) -and
            [int]$oldProc['ID Process'][$inst].RawValue -eq $id) {
            try {
                $v = [Diagnostics.CounterSample]::Calculate($oldProc['% Processor Time'][$inst].Sample, $proc['% Processor Time'][$inst].Sample) / $Cores
                if ($v -ge 0 -and -not [double]::IsNaN($v)) { $p.cpu = [double]$p.cpu + $v }
            } catch { $null = $_ }   # not comparable: no number from this instance
        }
    }
    $all = @($programs.Values)
    foreach ($p in $all) { if ($null -ne $p.cpu) { $p.cpu = [math]::Round($p.cpu, 1) } }
    $byVram = @($all | Where-Object { $_.vram -gt 0 } | Sort-Object -Property @{ Expression = { $_.vram }; Descending = $true }, @{ Expression = { $_.mem }; Descending = $true } | Select-Object -First $Count)
    $byMem = @($all | Sort-Object -Property @{ Expression = { $_.mem }; Descending = $true } | Select-Object -First $Count)
    $chosen = @{}
    foreach ($p in $byVram + $byMem) { $chosen[$p.name] = $p }
    $rows = @($chosen.Values | Sort-Object -Property @{ Expression = { $_.vram }; Descending = $true }, @{ Expression = { $_.mem }; Descending = $true } | Select-Object -First $MaxRows)
    foreach ($r in $rows) { $r }
}

# The slow sampler's memory, keeping what it needs from one pass to the next. Ai stays $null until story #93.
function New-WorkstationContext {
    param([object[]]$ComfyEntries = @(), [string]$GpuLuid, [int]$Cores, [double]$TotalRam, [int]$PageSize = 4096,
          [hashtable]$Readers, [int]$WslConfigEveryMs = 60000)
    @{ ComfyEntries = $ComfyEntries; GpuLuid = $GpuLuid; Cores = $Cores; TotalRam = $TotalRam; PageSize = $PageSize
       Readers = $Readers; WslConfigEveryMs = $WslConfigEveryMs
       Previous = $null; PreviousMs = $null; WslCap = $null; WslCapReadMs = $null; Ai = $null }
}

# One slow-sampler pass: each part in its own try/catch, so one failing leaves the others running.
function Invoke-WorkstationTick {
    param([hashtable]$State, [hashtable]$Context, [long]$NowMs)
    $readers = $Context.Readers
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $snap = $null

    try {   # memory: the counter reading, commit and paging
        $snap = & $readers.Counters
        $d = Get-MemoryDetail -Previous $Context.Previous -Current $snap -PageSize $Context.PageSize
        $State.memCommit = $d.memCommit; $State.memCommitLimit = $d.memCommitLimit; $State.memPageIn = $d.memPageIn
    } catch { $snap = $null; $errors.Add("memory: $($_.Exception.Message)") }

    try {   # wsl: the VM now, and .wslconfig when it is due
        $due = $null -eq $Context.WslCapReadMs -or $NowMs -lt $Context.WslCapReadMs -or ($NowMs - $Context.WslCapReadMs) -ge $Context.WslConfigEveryMs
        if ($due) {
            $Context.WslCapReadMs = $NowMs
            $Context.WslCap = ConvertFrom-WslConfig -Text (& $readers.WslConfig) -TotalRam $Context.TotalRam
        }
        $State.wsl = Get-WslReading -Process (& $readers.WslProcess) -Cap $Context.WslCap
    } catch { $errors.Add("wsl: $($_.Exception.Message)") }

    try {   # top programs: from the same reading
        if ($snap) {
            $elapsed = if ($null -ne $Context.PreviousMs) { ($NowMs - $Context.PreviousMs) / 1000.0 } else { 0.0 }
            $State.top = @(Get-TopPrograms -Previous $Context.Previous -Current $snap -ElapsedSeconds $elapsed -Cores $Context.Cores -GpuLuid $Context.GpuLuid)
        } else { $State.top = @() }
    } catch { $errors.Add("top programs: $($_.Exception.Message)") }

    if ($snap) { $Context.Previous = $snap; $Context.PreviousMs = $NowMs }
    $State.workstationError = if ($errors.Count) { $errors -join '; ' } else { $null }
}
#endregion 92

#region 93 The AI server (#93)
#endregion 93
