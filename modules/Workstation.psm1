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
#endregion 91

#region 92 Memory detail and top programs (#92)
#endregion 92

#region 93 The AI server (#93)
#endregion 93
