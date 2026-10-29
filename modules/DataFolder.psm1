# The data folder (spec section 3): where state\ and logs\ live, the fallback to SRRVRR's own folder, the check
# that no network share covers it, the lock that keeps a second copy out, and its permissions.
# Refusals throw SrrRefusalException (exit 3), defined in modules\Settings.psm1, which must be imported first.

$script:SpecialShare = 0x80000000   # Win32_Share type bit for Windows' own shares (ADMIN$, IPC$, C$ ...)
$script:SystemSid = 'S-1-5-18'
$script:AdminsSid = 'S-1-5-32-544'

function New-Refusal([string]$Message) { New-Object SrrRefusalException $Message }

# The full path with every junction or folder link followed, no trailing separator.
function Resolve-SrrPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parts = $full.Split('\')
    $current = $parts[0]
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $current = "$current\$($parts[$i])"
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Target) {
            $current = Resolve-SrrPath (@($item.Target)[0])
        }
    }
    if ($current.Length -eq 2) { $current += '\' }   # a drive root keeps its separator
    $current
}

# The share whose folder is the same as Path, above it, or below it ($null if none). Windows' own special shares
# are ignored; a hidden share someone made (a name ending in $) still counts.
function Test-PathInShare {
    param([string]$Path, [object[]]$Shares)
    $p = (Resolve-SrrPath $Path).TrimEnd('\')
    foreach ($s in $Shares) {
        if (-not $s.Path -or ([long]$s.Type -band $script:SpecialShare)) { continue }
        $sp = (Resolve-SrrPath $s.Path).TrimEnd('\')
        $cmp = [StringComparison]::OrdinalIgnoreCase
        if ([string]::Equals($p, $sp, $cmp) -or $p.StartsWith("$sp\", $cmp) -or $sp.StartsWith("$p\", $cmp)) { return $s }
    }
    $null
}

# OS wrappers, kept small so tests can replace them.
function Get-ShareList { @(Get-CimInstance -ClassName Win32_Share -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Type = [long]$_.Type } }) }
function Test-Elevated { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Get-SrrDriveType([string]$Path) { [string]([IO.DriveInfo]::new([IO.Path]::GetPathRoot((Resolve-SrrPath $Path))).DriveType) }
function Test-FolderWritable([string]$Path) {
    $probe = Join-Path $Path ('.srrvrr-write-test-' + [guid]::NewGuid().ToString('n'))
    try { [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force; $true } catch { $false }
}

# True when another copy holds Folder\state\srrvrr.lock open (a sharing violation), even if the folder looks
# read-only: a held lock is always a refusal, never a fallback.
function Test-LockHeld([string]$Folder) {
    $lock = Join-Path $Folder 'state\srrvrr.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try { [IO.File]::Open($lock, 'Open', 'Read', 'ReadWrite').Dispose(); $false }
    catch [IO.IOException] { $true }
    catch { $false }
}

function Assert-UsableFolder([string]$Folder, [object[]]$Shares, [scriptblock]$DriveType) {
    if ((& $DriveType $Folder) -eq 'Network') { throw (New-Refusal "The data folder $Folder is on a network drive. SRRVRR keeps its data on a local drive.") }
    if (Test-LockHeld $Folder) { throw (New-Refusal "another SRRVRR is using the data folder $Folder. Only one copy can use a data folder; give a test copy its own DataPath.") }
    $share = Test-PathInShare -Path $Folder -Shares $Shares
    if ($share) { throw (New-Refusal "The data folder $Folder is shared on the network (share '$($share.Name)', $($share.Path)). Stop sharing it, or set DataPath to a folder that isn't shared.") }
}

# Picks the data folder: DataPath if it's there and writable, else SRRVRR's own folder (with the reason), after
# the lock, share and network checks on each. Creates state\ and logs\ (never DataPath itself), takes the lock,
# and, when elevated, makes sure only SYSTEM and Administrators can write there.
# Returns @{ Path; IsFallback; Reason; Lock (the open lock file); Notes }.
function Resolve-DataPath {
    param(
        [string]$Setting, [Parameter(Mandatory)][string]$OwnFolder, [object[]]$Shares, [bool]$IsElevated,
        [scriptblock]$DriveType = { param($p) Get-SrrDriveType $p },
        [scriptblock]$TestWritable = { param($p) Test-FolderWritable $p }
    )
    $notes = New-Object System.Collections.Generic.List[hashtable]
    if ($null -eq $Shares) {
        if ($IsElevated) { throw (New-Refusal "SRRVRR couldn't read the list of shared folders, so it can't check the data folder isn't shared.") }
        $notes.Add(@{ Level = 'Warning'; Text = "Couldn't read the list of shared folders (not running as administrator), so the data folder wasn't checked against shares." })
        $Shares = @()
    }
    $path = $OwnFolder; $fallback = $false; $reason = $null
    if ($Setting) {
        if (-not (Test-Path -LiteralPath $Setting -PathType Container)) { $fallback = $true; $reason = 'missing' }
        else {
            Assert-UsableFolder $Setting $Shares $DriveType
            if (& $TestWritable $Setting) { $path = $Setting } else { $fallback = $true; $reason = 'read-only' }
        }
        if ($fallback) { $notes.Add(@{ Level = 'Warning'; Text = "DataPath $Setting is $reason, so history and logs go to $OwnFolder until the next restart." }) }
    }
    if ($path -eq $OwnFolder) {
        Assert-UsableFolder $OwnFolder $Shares $DriveType
        if (-not (& $TestWritable $OwnFolder)) { throw (New-Refusal "SRRVRR can't write to its own folder $OwnFolder, so it has nowhere to keep its data.") }
    }
    foreach ($sub in 'state', 'logs') { New-Item -ItemType Directory -Force -Path (Join-Path $path $sub) | Out-Null }
    try { $lock = [IO.File]::Open((Join-Path $path 'state\srrvrr.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { throw (New-Refusal "another SRRVRR is using the data folder $path.") }
    if ($IsElevated) {
        try { foreach ($sub in 'state', 'logs') { Set-DataFolderAcl -Path (Join-Path $path $sub) } }
        catch { $lock.Dispose(); throw (New-Refusal "SRRVRR couldn't limit who can write its data folder ${path}: $($_.Exception.Message)") }
    } else {
        $notes.Add(@{ Level = 'Note'; Text = 'Not running as administrator, so the data folder''s permissions were left as they are.' })
    }
    @{ Path = $path; IsFallback = $fallback; Reason = $reason; Lock = $lock; Notes = $notes }
}

# Which access rules to change so only SYSTEM and Administrators can write: every other allow rule that grants
# any write right is replaced by a read rule for the same account, and inheritance is turned off.
function Get-DataFolderAclPlan {
    param([System.Security.AccessControl.FileSystemSecurity]$Acl)
    $write = [System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
    $remove = @(); $add = @()
    foreach ($r in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow' -or $r.IdentityReference.Value -in $script:SystemSid, $script:AdminsSid) { continue }
        if (([int]$r.FileSystemRights -band [int]$write) -eq 0) { continue }
        $who = $r.IdentityReference.Translate([Security.Principal.NTAccount])
        $remove += New-Object System.Security.AccessControl.FileSystemAccessRule($who, $r.FileSystemRights, $r.InheritanceFlags, $r.PropagationFlags, 'Allow')
        $add += New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'ReadAndExecute', $r.InheritanceFlags, $r.PropagationFlags, 'Allow')
    }
    @{ Remove = $remove; Add = $add; DisableInheritance = $true }
}

function Set-DataFolderAcl([string]$Path) {
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $true)   # inherited rules become explicit, so they can be changed here
    Set-Acl -LiteralPath $Path -AclObject $acl
    $acl = Get-Acl -LiteralPath $Path
    $plan = Get-DataFolderAclPlan -Acl $acl
    foreach ($r in $plan.Remove) { [void]$acl.RemoveAccessRule($r) }
    foreach ($r in $plan.Add) { $acl.AddAccessRule($r) }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# Writes data files under the data folder. The first write that fails switches every later write to the fallback
# folder for good (until a restart, so one day's files are never split across two drives) and calls OnFallback
# once with the reason.
function New-DataFolder {
    param(
        [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$FallbackPath, [scriptblock]$OnFallback = { },
        [scriptblock]$Writer = { param($file, $text) [IO.File]::WriteAllText($file, $text, (New-Object Text.UTF8Encoding($false))) },
        [bool]$IsFallback = $false
    )
    $f = [pscustomobject]@{ Path = $Path; FallbackPath = $FallbackPath; IsFallback = $IsFallback; OnFallback = $OnFallback; Writer = $Writer }
    $f | Add-Member ScriptMethod Write {
        param([string]$Relative, [string]$Text)
        $file = Join-Path $this.Path $Relative
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
            & $this.Writer $file $Text
        } catch {
            if ($this.IsFallback) { throw }
            $why = "writing $Relative to $($this.Path) failed: $($_.Exception.Message)"
            $this.Path = $this.FallbackPath; $this.IsFallback = $true
            & $this.OnFallback $why
            $file = Join-Path $this.Path $Relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
            & $this.Writer $file $Text
        }
    }
    $f
}

Export-ModuleMember -Function Resolve-SrrPath, Test-PathInShare, Get-ShareList, Test-Elevated, Get-SrrDriveType, Test-FolderWritable,
    Test-LockHeld, Resolve-DataPath, Get-DataFolderAclPlan, Set-DataFolderAcl, New-DataFolder
