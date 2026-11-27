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

# Events from two detection readings (SRRVRR.ps1 adds each with Add-SrrEvent). The spill: gpuSpill changing; the AI
# server: Get-AiWatchEvents (region 93).
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
    foreach ($e in @(Get-AiWatchEvents -Old $Old -New $New)) { $out.Add($e) }
    $out.ToArray()
}
#endregion 91

#region 92 Memory detail and top programs (#92)
# Memory detail, the WSL VM and the top programs. Every reading comes through the $Readers the context holds, so
# nothing here reads the machine itself. Snapshots are shaped like PerformanceCounterCategory.ReadCategory():
# category -> counter -> instance -> object with .Sample, .RawValue and .InstanceName (the real collections have
# .Contains, not .ContainsKey, and lower-case keys).

# The value of one counter of a single-instance category (Memory), or $null.
function Get-SingleRaw {
    param($Snapshot, [string]$Category, [string]$Counter)
    if (-not $Snapshot -or -not $Snapshot.Contains($Category)) { return $null }
    $c = $Snapshot[$Category]
    if (-not $c.Contains($Counter)) { return $null }
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
    if (-not $Current -or -not $Current.Contains('Process')) { return }
    $proc = $Current['Process']
    if (-not $proc.Contains('ID Process') -or -not $proc.Contains('Working Set - Private')) { return }
    $oldProc = if ($Previous -and $Previous.Contains('Process')) { $Previous['Process'] } else { $null }
    # Video memory on the chosen card, per process id.
    $vramOf = @{}
    if ($Current.Contains('GPU Process Memory') -and $Current['GPU Process Memory'].Contains('Dedicated Usage')) {
        $ded = $Current['GPU Process Memory']['Dedicated Usage']
        foreach ($k in $ded.Keys) {
            if ($k -notmatch '^pid_(\d+)_luid_(\w+?_\w+?)_phys_\d+') { continue }
            if ($GpuLuid -and $Matches[2] -ne $GpuLuid) { continue }
            $id = [int]$Matches[1]
            if (-not $vramOf.Contains($id)) { $vramOf[$id] = [long]0 }
            $vramOf[$id] += [long]$ded[$k].RawValue
        }
    }
    $programs = @{}
    foreach ($inst in @($proc['ID Process'].Keys)) {
        if ($inst -eq '_Total' -or $inst -eq 'Idle') { continue }
        $name = ([string]$proc['ID Process'][$inst].InstanceName) -replace '#\d+$', ''   # the real collection's keys are lower-case; InstanceName keeps the case
        if ($name -eq 'vmmemWSL') { $name = 'WSL VM' }
        if (-not $programs.Contains($name)) { $programs[$name] = @{ name = $name; count = 0; vram = [long]0; mem = [long]0; cpu = $null } }
        $p = $programs[$name]
        $id = [int]$proc['ID Process'][$inst].RawValue
        $p.count++
        if ($proc['Working Set - Private'].Contains($inst)) { $p.mem += [long]$proc['Working Set - Private'][$inst].RawValue }
        if ($vramOf.Contains($id)) { $p.vram += $vramOf[$id] }
        # CPU: the same instance, the same process, in both readings.
        if ($oldProc -and $Cores -gt 0 -and $proc.Contains('% Processor Time') -and $oldProc.Contains('% Processor Time') -and $oldProc.Contains('ID Process') -and
            $oldProc['ID Process'].Contains($inst) -and $oldProc['% Processor Time'].Contains($inst) -and $proc['% Processor Time'].Contains($inst) -and
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

# The slow sampler's memory, keeping what it needs from one pass to the next, with the AI server watch (#93).
function New-WorkstationContext {
    param([object[]]$ComfyEntries = @(), [string]$GpuLuid, [int]$Cores, [double]$TotalRam, [int]$PageSize = 4096,
          [hashtable]$Readers, [int]$WslConfigEveryMs = 60000)
    @{ ComfyEntries = $ComfyEntries; GpuLuid = $GpuLuid; Cores = $Cores; TotalRam = $TotalRam; PageSize = $PageSize
       Readers = $Readers; WslConfigEveryMs = $WslConfigEveryMs
       Previous = $null; PreviousMs = $null; WslCap = $null; WslCapReadMs = $null; Ai = (New-AiWatch -Entries $ComfyEntries) }
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

    if (@($Context.ComfyEntries).Count -gt 0) {
        try {   # ai server: each entry's replies, after the wsl part so the VM state is this pass's
            Update-WorkstationAi -State $State -Context $Context -NowMs $NowMs
        } catch { $errors.Add("ai server: $($_.Exception.Message)") }
    }

    if ($snap) { $Context.Previous = $snap; $Context.PreviousMs = $NowMs }
    $State.workstationError = if ($errors.Count) { $errors -join '; ' } else { $null }
}
#endregion 92

#region 93 The AI server (#93)
# The AI server (spec section 6; plan, region 93). Every reading of ComfyUI goes through Read-LocalHttp: two GETs
# (/system_stats and /prompt) on 127.0.0.1, nothing else. Everything below it is pure.

# The one network call in this module. Port and Path are validated before the body runs, so no other host, port
# range or path can be asked for. Replies are capped at MaxBytes, counted as they are read (a reply may have no
# Content-Length). Never throws: a refusal, a timeout, a status other than 200 or a reply that is too large is
# Ok = $false with the reason in Error.
function Read-LocalHttp {
    param([ValidateRange(1024, 65535)][int]$Port, [ValidateSet('/system_stats', '/prompt')][string]$Path,
          [int]$TimeoutMs = 2000, [int]$MaxBytes = 262144)
    $result = @{ Ok = $false; Status = 0; Body = ''; Error = '' }
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + $Path)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutMs
        $request.ReadWriteTimeout = $TimeoutMs
        $request.Proxy = $null
        $request.AllowAutoRedirect = $false
        $request.KeepAlive = $false
        try {
            $response = $request.GetResponse()
        } catch [Net.WebException] {
            # A 4xx or 5xx arrives as an exception that still carries the reply.
            if ($_.Exception.Response) {
                $result.Status = [int]$_.Exception.Response.StatusCode
                $_.Exception.Response.Close()
                $result.Error = "HTTP $($result.Status)"
            } else {
                $result.Error = $_.Exception.Message
            }
            return $result
        }
        $result.Status = [int]$response.StatusCode
        if ($result.Status -ne 200) { $result.Error = "HTTP $($result.Status)"; return $result }
        $stream = $response.GetResponseStream()
        $stream.ReadTimeout = $TimeoutMs
        $held = New-Object IO.MemoryStream
        $buffer = New-Object byte[] 8192
        $limit = [long]$MaxBytes + 1
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($held.Length -lt $limit) {
            if ($timer.ElapsedMilliseconds -gt (2 * $TimeoutMs)) { $result.Error = 'reply too slow'; return $result }
            $want = [int][Math]::Min([long]$buffer.Length, $limit - $held.Length)
            $got = $stream.Read($buffer, 0, $want)
            if ($got -le 0) { break }
            $held.Write($buffer, 0, $got)
        }
        if ($held.Length -gt $MaxBytes) { $result.Error = 'reply too large'; return $result }
        $result.Body = [Text.Encoding]::UTF8.GetString($held.ToArray())
        $result.Ok = $true
        $result
    } catch {
        $result.Ok = $false
        $result.Body = ''
        $result.Error = $_.Exception.Message
        $result
    } finally {
        if ($response) { $response.Close() }
    }
}

# A member of a parsed JSON object, or $null (strict mode safe).
function Get-ComfyMember {
    param($Object, [string]$Name)
    if ($Object -is [pscustomobject]) {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    }
    $null
}

# A whole number of zero or more as a [long], else $null (strings, fractions, negatives and booleans are not numbers).
function ConvertTo-ComfyCount {
    param($Value)
    if ($Value -is [int] -or $Value -is [long]) {
        if ($Value -ge 0) { return [long]$Value }
        return $null
    }
    if ($Value -is [double] -or $Value -is [decimal]) {
        if ($Value -ge 0 -and $Value -lt 9e15 -and $Value -eq [Math]::Floor($Value)) { return [long]$Value }
    }
    $null
}

# The kept fields of /system_stats and nothing else: the ComfyUI version, and for the first device the card's total
# and free video memory (as ComfyUI sees them), what its PyTorch holds (torch_vram_total) and what is free of that.
# $null for anything that isn't that shape. Everything else in the reply (argv, paths, library versions) is dropped.
function ConvertFrom-ComfyStats {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try {
        $json = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
        $version = Get-ComfyMember (Get-ComfyMember $json 'system') 'comfyui_version'
        if ($version -isnot [string] -or $version -cnotmatch '^[A-Za-z0-9._+-]{1,32}\z') { return $null }
        $devices = @(Get-ComfyMember $json 'devices')
        if ($devices.Count -lt 1) { return $null }
        $card = $devices[0]
        $total = ConvertTo-ComfyCount (Get-ComfyMember $card 'vram_total')
        $free = ConvertTo-ComfyCount (Get-ComfyMember $card 'vram_free')
        $holds = ConvertTo-ComfyCount (Get-ComfyMember $card 'torch_vram_total')
        $torchFree = ConvertTo-ComfyCount (Get-ComfyMember $card 'torch_vram_free')
        if ($null -eq $total -or $null -eq $free -or $null -eq $holds -or $null -eq $torchFree) { return $null }
        @{ version = $version; vramTotal = $total; vramFree = $free; holds = $holds; torchFree = $torchFree }
    } catch { $null }
}

# The queue count (running and waiting) from /prompt's exec_info.queue_remaining, or $null.
function ConvertFrom-ComfyQueue {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $null }
    try {
        $json = ConvertFrom-Json -InputObject $Body -ErrorAction Stop
        $n = ConvertTo-ComfyCount (Get-ComfyMember (Get-ComfyMember $json 'exec_info') 'queue_remaining')
        if ($null -eq $n -or $n -gt [int]::MaxValue) { return $null }
        [int]$n
    } catch { $null }
}

# One state record per configured entry, by name.
function New-AiWatch {
    param([object[]]$Entries = @())
    $watch = @{}
    foreach ($e in $Entries) {
        $watch[[string]$e.Name] = @{ State = 'off'; Misses = 0; AnsweredThisVm = $false; AnsweredWithVm = $false
                                     WorkingSinceMs = $null; LastDoneTs = $null; LastDoneSec = $null; LastRow = $null; VmWas = $null }
    }
    $watch
}

# The page's row for one entry. Readings are $null when there is none (off, starting, not answering, unknown).
function New-AiRow {
    param([hashtable]$W, [string]$Name, [string]$State, $Queue = $null, $WorkingSec = $null, $Stats = $null)
    @{ name = $Name; state = $State; queue = $Queue; workingSec = $WorkingSec
       holds = $(if ($Stats) { $Stats.holds } else { $null })
       vramTotal = $(if ($Stats) { $Stats.vramTotal } else { $null })
       vramFree = $(if ($Stats) { $Stats.vramFree } else { $null })
       version = $(if ($Stats) { $Stats.version } else { $null })
       lastDoneTs = $W.LastDoneTs; lastDoneSec = $W.LastDoneSec }
}

# One reading of one entry (spec section 6; the rules in the plan's order). $Answer is @{ Ok; Stats; Queue };
# $VmRunning is $true, $false or $null (can't tell). Returns the row.
function Update-AiWatch {
    param([hashtable]$Watch, [string]$Name, [hashtable]$Answer, [object]$VmRunning, [long]$NowMs,
          [int]$MinJobSec = 60, [int]$MissesToFail = 3)
    $w = $Watch[$Name]
    $ok = $Answer -and $Answer.Ok
    # 1. A VM that was down and is up again is a new VM: this entry has not answered in it yet.
    if ($null -ne $VmRunning) {
        if ($w.VmWas -eq $false -and $VmRunning -eq $true) { $w.AnsweredThisVm = $false }
        $w.VmWas = $VmRunning
    }
    $row = $null
    if ($ok) {
        # 2. Answered.
        $w.Misses = 0
        $w.AnsweredThisVm = $true
        $w.AnsweredWithVm = ($VmRunning -eq $true)
        if ($null -eq $Answer.Stats -or $null -eq $Answer.Queue) {
            $w.State = 'unknown'
            $row = New-AiRow $w $Name 'unknown'
        } elseif ($Answer.Queue -ge 1) {
            if ($null -eq $w.WorkingSinceMs) { $w.WorkingSinceMs = $NowMs }
            $w.State = 'working'
            $row = New-AiRow $w $Name 'working' $Answer.Queue ([long][Math]::Round([Math]::Max(0, $NowMs - $w.WorkingSinceMs) / 1000)) $Answer.Stats
        } else {
            if ($null -ne $w.WorkingSinceMs) {
                $ms = $NowMs - $w.WorkingSinceMs
                if ($ms -ge ($MinJobSec * 1000)) { $w.LastDoneTs = $NowMs; $w.LastDoneSec = [long][Math]::Round($ms / 1000) }
                $w.WorkingSinceMs = $null
            }
            $w.State = 'idle'
            $row = New-AiRow $w $Name 'idle' 0 $null $Answer.Stats
        }
    } elseif ($VmRunning -eq $false -and $w.AnsweredWithVm) {
        # 3. The VM it ran in has gone: off at once.
        $w.WorkingSinceMs = $null; $w.AnsweredThisVm = $false; $w.AnsweredWithVm = $false; $w.Misses = 0
        $w.State = 'off'
        $row = New-AiRow $w $Name 'off'
    } else {
        # 4. A miss. One or two keep the last row (a slow reply during a model load must not flicker).
        $w.Misses++
        if ($w.State -in 'idle', 'working', 'unknown' -and $w.Misses -lt $MissesToFail -and $w.LastRow) {
            $row = $w.LastRow.Clone()
            $row.lastDoneTs = $w.LastDoneTs; $row.lastDoneSec = $w.LastDoneSec
            if ($row.state -eq 'working' -and $null -ne $w.WorkingSinceMs) {
                $row.workingSec = [long][Math]::Round([Math]::Max(0, $NowMs - $w.WorkingSinceMs) / 1000)
            }
        } elseif ($w.AnsweredThisVm) {
            # 5. Answered before in this VM, and no longer: not answering.
            $w.WorkingSinceMs = $null
            $w.State = 'not-answering'
            $row = New-AiRow $w $Name 'not-answering'
        } else {
            $w.State = $(if ($VmRunning -eq $true) { 'starting' } else { 'off' })
            $row = New-AiRow $w $Name $w.State
        }
    }
    $w.LastRow = $row
    $row.Clone()
}

# The AI part of the workstation tick (spec section 6): for each entry, /system_stats and then /prompt only if that
# was Ok (at most 2 calls an entry), then Update-AiWatch with the VM state from $State.wsl.running ($null when
# there is no WSL reading). $State.ai becomes a new array of rows. A reader that throws counts as a miss for that
# entry, the other entries still run, and the first such error is thrown at the end for the tick to report.
function Update-WorkstationAi {
    param([hashtable]$State, [hashtable]$Context, [long]$NowMs)
    $vm = $null
    $wslReading = $State['wsl']   # an index, not .wsl: under strict mode a missing key would throw
    if ($wslReading -is [System.Collections.IDictionary] -and $wslReading.Contains('running')) { $vm = $wslReading['running'] }
    $rows = New-Object System.Collections.Generic.List[object]
    $failure = $null
    foreach ($entry in @($Context.ComfyEntries)) {
        $name = [string]$entry.Name
        $answer = @{ Ok = $false; Stats = $null; Queue = $null }
        try {
            $s = & $Context.Readers.Http $entry.Port '/system_stats'
            if ($s -and $s.Ok) {
                $q = & $Context.Readers.Http $entry.Port '/prompt'
                if ($q -and $q.Ok) {
                    $answer = @{ Ok = $true; Stats = (ConvertFrom-ComfyStats -Body ([string]$s.Body)); Queue = (ConvertFrom-ComfyQueue -Body ([string]$q.Body)) }
                }
            }
        } catch {
            if (-not $failure) { $failure = $_.Exception.Message }
        }
        $rows.Add((Update-AiWatch -Watch $Context.Ai -Name $name -Answer $answer -VmRunning $vm -NowMs $NowMs))
    }
    $State.ai = $rows.ToArray()
    if ($failure) { throw $failure }
}

# The AI events between two readings (each @{ ai = rows }): a job that was working and now isn't answering, and a
# new lastDoneTs. Records @{ Type; Data; Key }, unrolled; counts and the owner's entry names only.
function Get-AiWatchEvents {
    param([object]$Old, [object]$New)
    $found = New-Object System.Collections.Generic.List[object]
    if ($Old -isnot [System.Collections.IDictionary] -or $New -isnot [System.Collections.IDictionary]) { return }
    if (-not $Old.Contains('ai') -or -not $New.Contains('ai')) { return }
    $before = @{}
    foreach ($r in @($Old['ai'])) { if ($r) { $before[[string]$r.name] = $r } }
    foreach ($r in @($New['ai'])) {
        if (-not $r) { continue }
        $name = [string]$r.name
        if (-not $before.ContainsKey($name)) { continue }
        $was = $before[$name]
        if ($was.state -eq 'working' -and $r.state -eq 'not-answering') {
            $found.Add(@{ Type = 'ai-stopped-answering'; Data = @{ name = $name }; Key = "ai-stopped-answering|$name" })
        }
        if ($null -ne $r.lastDoneTs -and $r.lastDoneTs -ne $was.lastDoneTs) {
            $found.Add(@{ Type = 'ai-job-done'; Data = @{ name = $name; seconds = $r.lastDoneSec }; Key = "ai-job-done|$name|$($r.lastDoneTs)" })
        }
    }
    $found.ToArray()
}
#endregion 93
