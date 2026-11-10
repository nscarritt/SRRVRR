# The Transfers card (docs/specs/2026-11-07-srrvrr-v0.9.0-design.md): the bottleneck, the shares, PCs and folders,
# write bursts. Pure functions: no clock, counter, CIM or file calls; callers pass readings and times in. One region
# per story (docs/plans/2026-11-10-srrvrr-v0.9.0-implementation-plan.md, Shared interfaces): change only your own.
# Every function is exported (no Export-ModuleMember), so the regions never share a line.
Set-StrictMode -Version 2

#region Shared (byte-identical in every branch; only the lead changes it)
# What the samplers and the web server share: one synchronized table, given to both runspaces.
function New-TransferMonitor {
    param([hashtable]$Settings = @{}, [bool]$Elevated, [string[]]$ServerAddresses = @())
    $get = { param($k, $d) if ($Settings.ContainsKey($k) -and $null -ne $Settings[$k]) { $Settings[$k] } else { $d } }
    [hashtable]::Synchronized(@{
        Elevated = $Elevated; ServerAddresses = @($ServerAddresses); BottleneckPercent = [int](& $get 'BottleneckPercent' 80)
        BurstFiles = [int](& $get 'BurstFiles' 500); BurstWindowSeconds = [int](& $get 'BurstWindowSeconds' 60)
        BurstQuietMinutes = [int](& $get 'BurstQuietMinutes' 5); TransferFolders = [bool](& $get 'TransferFolders' $true)
        NamedIndex = (New-NamedPcIndex -NamedPCs @(& $get 'NamedPCs' @()))
        Shares = @(); SessionPcs = @{}; PcFolders = @{}; OpenFilesCapped = $false; UpdatedMs = $null; Busy = $false
        Hold = @{ Shown = 'idle'; Candidate = 'idle'; SinceMs = 0L }; Bursts = @{}; BurstList = @(); UnknownSeen = @{}
    })
}
# An address as SRRVRR compares it: IPv4-mapped IPv6 back to IPv4, brackets and the zone id dropped, IPv6 in lower
# case. $null for anything that isn't an address.
function ConvertTo-PcAddress {
    param([string]$Address)
    if (-not $Address) { return $null }
    $text = ($Address.Trim() -replace '^\[|\]$', '') -replace '%.*$', ''
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($text, [ref]$ip)) { return $null }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $ip.ToString().ToLowerInvariant()
}
# Address (as ConvertTo-PcAddress gives it) -> the named PC's Name, from the NamedPCs setting.
function New-NamedPcIndex {
    param([object[]]$NamedPCs = @())
    $index = @{}
    foreach ($pc in $NamedPCs) {
        if ($pc -isnot [Collections.IDictionary]) { continue }
        foreach ($a in @($pc['Addresses'])) { $k = ConvertTo-PcAddress ([string]$a); if ($k) { $index[$k] = [string]$pc['Name'] } }
    }
    $index
}
# Who an address is: @{ Address; Name; Known; Self }. Self: loopback or one of ServerAddresses (the server itself is
# always trusted). Known: Self, or in the index. Name: the named PC's Name, else $null.
function Find-NamedPC {
    param([string]$Address, [hashtable]$Index = @{}, [string[]]$ServerAddresses = @())
    $a = ConvertTo-PcAddress $Address
    $out = @{ Address = $a; Name = $null; Known = $false; Self = $false }
    if (-not $a) { return $out }
    $self = [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($a))
    foreach ($s in $ServerAddresses) { if (-not $self -and (ConvertTo-PcAddress $s) -eq $a) { $self = $true } }
    if ($self) { $out.Known = $true; $out.Self = $true; return $out }
    if ($Index -and $Index.ContainsKey($a)) { $out.Name = $Index[$a]; $out.Known = $true }
    $out
}
#endregion Shared

#region 76 The bottleneck and the shares (#76)
#endregion 76

#region 77 Write bursts (#77). Stubs until #77 lands: no bursts, no events.
function Update-WriteBursts { param([hashtable]$State, [object[]]$Pcs, [object[]]$Shares, [long]$NowMs, [int]$Files, [int]$WindowSeconds, [long]$QuietMs) }
function Get-BurstEvents { param([object[]]$Old, [object[]]$New, [object[]]$PcRows, [hashtable]$PcFolders, [bool]$IncludeFolders, [long]$StopMs) }
#endregion 77

#region 78 PCs and folders (#78). Stubs until #78 lands: no PCs, no events.
function Get-SessionPcs { param([object[]]$Sessions, [object[]]$OpenFiles, [object[]]$Shares, [hashtable]$Index, [string[]]$ServerAddresses, [bool]$Folders, [int]$MaxOpenFiles = 5000) @{ SessionPcs = @{}; PcFolders = @{}; Capped = $false } }
function Get-TransferPcRows { param([object[]]$Pcs, [hashtable]$SessionPcs, [hashtable]$PcFolders, [object[]]$Bursts, [int]$MaxPcs = 64) }
function Get-UnknownPcEvents { param([hashtable]$Seen, [object[]]$PcRows, [bool]$Elevated) }
#endregion 78

#region 79 (none: #79's code is in Maintenance.psm1, Web.psm1 and web\app.js)
#endregion 79
