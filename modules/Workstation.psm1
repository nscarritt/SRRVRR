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
#endregion 92

#region 93 The AI server (#93)
#endregion 93
