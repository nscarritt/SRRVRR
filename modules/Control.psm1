# Stopping SRRVRR gracefully (spec section 5): a named Windows event tied to SRRVRR's folder, which SRRVRR waits on
# and -Stop / Stop SRRVRR.bat signal; the stopper's steps; and which processes a forced stop may end.
# Refusals throw SrrRefusalException (exit 3), defined in modules\Settings.psm1, which must be imported first.

$script:SystemSid = 'S-1-5-18'
$script:AdminsSid = 'S-1-5-32-544'
$script:SignalRights = [System.Security.AccessControl.EventWaitHandleRights]'Modify, ChangePermissions, TakeOwnership'

# One spelling per folder, the same on both sides: mapped drive letters replaced by their network path, the full
# long path, no trailing separator, upper case.
function ConvertTo-StopPath([string]$Folder) {
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item) { $full = $item.FullName.TrimEnd('\') }   # long names instead of 8.3 short ones
    if ($full -match '^([A-Za-z]):') {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($matches[1]):'" -ErrorAction SilentlyContinue
        if ($disk -and $disk.DriveType -eq 4 -and $disk.ProviderName) { $full = $disk.ProviderName.TrimEnd('\') + $full.Substring(2) }
    }
    $full.ToUpperInvariant()
}

# Global\ when elevated (administrator or SYSTEM), Local\ (this session only) when not.
function Get-StopEventName([string]$Folder, [bool]$Elevated) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((ConvertTo-StopPath $Folder))) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    '{0}\SRRVRR-stop-{1}' -f $(if ($Elevated) { 'Global' } else { 'Local' }), $hash.Substring(0, 16)
}

# Elevated: only SYSTEM and Administrators may signal or change the event. Unelevated: only the current user.
function New-StopEventSecurity([bool]$Elevated) {
    $sec = New-Object System.Security.AccessControl.EventWaitHandleSecurity
    $sec.SetAccessRuleProtection($true, $false)
    $who = if ($Elevated) { @($script:SystemSid, $script:AdminsSid) } else { @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
    foreach ($sid in $who) {
        $sec.AddAccessRule((New-Object System.Security.AccessControl.EventWaitHandleAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'Allow')))
    }
    $sec
}

# An event someone else created is trusted only if its owner is SYSTEM or Administrators (or, unelevated, the
# current user) and nobody else is allowed to signal or change it.
function Test-StopEventTrusted {
    param([Security.Principal.SecurityIdentifier]$Owner, [object[]]$Rules, [bool]$Elevated)
    $ok = @($script:SystemSid, $script:AdminsSid)
    if (-not $Elevated) { $ok += [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    if ($ok -notcontains $Owner.Value) { return $false }
    foreach ($r in $Rules) {
        if ($r.AccessControlType -ne 'Allow') { continue }
        $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($ok -notcontains $sid -and ([int]$r.EventWaitHandleRights -band [int]$script:SignalRights)) { return $false }
    }
    $true
}

# The event SRRVRR waits on. Anyone can create a named event, so a name someone else got to first is checked, and
# refused (exit 3) unless it's trusted.
function New-StopEvent([string]$Folder, [bool]$Elevated) {
    $name = Get-StopEventName -Folder $Folder -Elevated $Elevated
    $created = $false
    try { $ev = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $name, [ref]$created, (New-StopEventSecurity $Elevated)) }
    catch [UnauthorizedAccessException] { throw (New-Object SrrRefusalException "The stop event name $name is taken by another program that SRRVRR can't open. Close it and start SRRVRR again.") }
    if (-not $created) {
        $acl = $ev.GetAccessControl()
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier])
        $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
        if (-not (Test-StopEventTrusted -Owner $owner -Rules $rules -Elevated $Elevated)) {
            $ev.Dispose()
            $ownerName = try { $owner.Translate([Security.Principal.NTAccount]).Value } catch { $owner.Value }
            throw (New-Object SrrRefusalException "The stop event name $name was made by $ownerName with permissions that would let others stop SRRVRR. Close the program holding it and start SRRVRR again.")
        }
        [void]$ev.Reset()
    }
    $ev
}

# Signals an existing stop event by name; $true if it existed. Opens it with signal rights only.
function Send-StopSignal([string]$Name) {
    $h = $null
    if (-not [System.Threading.EventWaitHandle]::TryOpenExisting($Name, [System.Security.AccessControl.EventWaitHandleRights]::Modify, [ref]$h)) { return $false }
    try { [void]$h.Set(); $true } finally { $h.Dispose() }
}

# The processes running this folder's SRRVRR.ps1, not -Stop calls and not the caller. Processes: Win32_Process-like
# objects with ProcessId and CommandLine.
function Select-SRRVRRProcess {
    param([string]$Folder, [object[]]$Processes, [int]$SelfId = $PID)
    $want = (ConvertTo-StopPath $Folder) + '\SRRVRR.PS1'
    foreach ($p in $Processes) {
        $cmd = [string]$p.CommandLine
        if ($p.ProcessId -eq $SelfId -or -not $cmd -or $cmd -match '(?i)\s-Stop\b') { continue }
        if ($cmd -match '(?i)-File\s+(?:"([^"]+)"|(\S+))') {
            $file = if ($matches[1]) { $matches[1] } else { $matches[2] }
            try { $norm = (ConvertTo-StopPath (Split-Path -Parent $file)) + '\' + ([IO.Path]::GetFileName($file)).ToUpperInvariant() } catch { continue }
            if ($norm -eq $want) { $p }
        }
    }
}

# What -Stop does: write state\stop-requested (time and who asked) so a launcher doesn't restart SRRVRR, signal the
# Global\ event, then the Local\ one, wait up to WaitSeconds for the copy to exit, and force-stop it after that.
# Clock: a scriptblock returning [DateTimeOffset]. Openers (replaceable in tests): Open (name -> handle or $null), Signal (handle), Processes (-> list), Kill (id).
# Returns @{ Action; Signalled; Forced; Ids }.
function Invoke-StopCommand {
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][scriptblock]$Clock, [int]$WaitSeconds = 10, [hashtable]$Openers)
    if (-not $Openers) {
        $Openers = @{
            Open      = { param($name) $h = $null; if ([System.Threading.EventWaitHandle]::TryOpenExisting($name, [System.Security.AccessControl.EventWaitHandleRights]::Modify, [ref]$h)) { $h } else { $null } }
            Signal    = { param($h) try { [void]$h.Set() } finally { $h.Dispose() } }
            Processes = { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'") }
            Kill      = { param($id) Stop-Process -Id $id -Force -ErrorAction Stop }
        }
    }
    $handles = @(foreach ($elevated in $true, $false) { $h = & $Openers.Open (Get-StopEventName -Folder $Folder -Elevated $elevated); if ($h) { $h } })
    $running = @(Select-SRRVRRProcess -Folder $Folder -Processes @(& $Openers.Processes))
    if (-not $handles -and -not $running) { return @{ Action = 'not running'; Signalled = $false; Forced = $false; Ids = @() } }

    $marker = Join-Path $Folder 'state\stop-requested'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
    [IO.File]::WriteAllText($marker, "requested $((& $Clock).ToString('o')) by $([Security.Principal.WindowsIdentity]::GetCurrent().Name)`r`n")
    foreach ($h in $handles) { & $Openers.Signal $h }

    $deadline = (& $Clock).AddSeconds($WaitSeconds)
    while ($running -and (& $Clock) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $running = @(Select-SRRVRRProcess -Folder $Folder -Processes @(& $Openers.Processes))
    }
    $forced = $false
    foreach ($p in $running) { & $Openers.Kill $p.ProcessId; $forced = $true }
    @{ Action = $(if ($forced) { 'forced' } else { 'stopped' }); Signalled = [bool]$handles; Forced = $forced; Ids = @($running | ForEach-Object { $_.ProcessId }) }
}

Export-ModuleMember -Function ConvertTo-StopPath, Get-StopEventName, New-StopEventSecurity, Test-StopEventTrusted, New-StopEvent,
    Send-StopSignal, Select-SRRVRRProcess, Invoke-StopCommand
