# The data folder: DataPath, its fallback, the share check, the lock and the permissions (spec section 3).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\DataFolder.psm1') -Force
    function Share([string]$Name, [string]$Path, [long]$Type = 0) { [pscustomobject]@{ Name = $Name; Path = $Path; Type = $Type } }
    function Get-Refusal([scriptblock]$Block) { try { & $Block; $null } catch { $_.Exception } }
    # Resolve-DataPath with test defaults: no shares, unelevated, local drives, writable.
    function Resolve-Test([hashtable]$p) {
        $args = @{ Setting = ''; OwnFolder = $Own; Shares = @(); IsElevated = $false; DriveType = { 'Fixed' } }
        foreach ($k in $p.Keys) { $args[$k] = $p[$k] }
        Resolve-DataPath @args
    }
}

Describe 'Share matching' {
    BeforeAll { $script:Root = New-TestDataPath; $script:Own = Join-Path $Root 'own'; $script:Data = Join-Path $Root 'Data'; New-Item -ItemType Directory $Own, $Data | Out-Null }
    It 'T48-01 a share on the data folder itself refuses, naming the folder' {
        $e = Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = @(Share 'Stuff' $Data) } }
        $e | Should -BeOfType ([SrrRefusalException]); $e.Message | Should -Match ([regex]::Escape($Data))
    }
    It 'T48-02 a share above the data folder refuses' {
        Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = @(Share 'Up' $Root) } } | Should -BeOfType ([SrrRefusalException])
        Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = @(Share 'Up2' (Split-Path $Root)) } } | Should -BeOfType ([SrrRefusalException])
    }
    It 'T48-03 a share below the data folder refuses' {
        foreach ($below in 'state', 'logs', 'a\b') { Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = @(Share 'Down' (Join-Path $Data $below)) } } | Should -BeOfType ([SrrRefusalException]) -Because $below }
    }
    It 'T48-04 folders are compared by whole names, case-insensitively, ignoring a trailing separator' {
        Test-PathInShare -Path "$Root\Logs" -Shares @(Share 'L' "$Root\Log") | Should -BeNullOrEmpty
        Test-PathInShare -Path "$Root\DataX" -Shares @(Share 'D' "$Root\Data") | Should -BeNullOrEmpty
        (Test-PathInShare -Path "$Root\logs" -Shares @(Share 'L' "$Root\LOGS\")).Name | Should -Be 'L'
    }
    It 'T48-06 Windows'' own special shares are ignored, a hidden share someone made is not' {
        $r = Resolve-Test @{ Setting = $Data; Shares = @((Share 'C$' 'C:\' 2147483648), (Share 'ADMIN$' 'C:\WINDOWS' 2147483648), (Share 'H$' ($Root.Substring(0, 3)) 2147483648)) }
        $r.Path | Should -Be $Data
        $r.Lock.Dispose()
        Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = @(Share 'Logs$' $Data) } } | Should -BeOfType ([SrrRefusalException])
    }
    It 'T48-07 a data folder or a fallback on a network drive refuses' {
        Get-Refusal { Resolve-Test @{ Setting = $Data; DriveType = { 'Network' } } } | Should -BeOfType ([SrrRefusalException])
        Get-Refusal { Resolve-Test @{ Setting = (Join-Path $Root 'missing'); DriveType = { param($p) if ($p -like "$Own*") { 'Network' } else { 'Fixed' } } } } | Should -BeOfType ([SrrRefusalException])
    }
    It 'T48-08 an unreadable share list refuses when elevated and warns when not' {
        Get-Refusal { Resolve-Test @{ Setting = $Data; Shares = $null; IsElevated = $true } } | Should -BeOfType ([SrrRefusalException])
        $r = Resolve-Test @{ Setting = $Data; Shares = $null }
        $r.Path | Should -Be $Data
        @($r.Notes | Where-Object { $_.Level -eq 'Warning' -and $_.Text -match 'share' }).Count | Should -Be 1
        $r.Lock.Dispose()
    }
}

Describe 'Junctions' -Tag 'Integration' {
    It 'T48-05 a data folder reached through a junction into a shared folder refuses' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; $shared = Join-Path $root 'shared'; $data = Join-Path $shared 'data'
        New-Item -ItemType Directory $own, $data | Out-Null
        $link = Join-Path $root 'link'
        cmd /c mklink /J "$link" "$data" | Out-Null
        try {
            Get-Refusal { Resolve-DataPath -Setting $link -OwnFolder $own -Shares @(Share 'S' $shared) -IsElevated $false -DriveType { 'Fixed' } } | Should -BeOfType ([SrrRefusalException])
            Get-Refusal { Resolve-DataPath -Setting $data -OwnFolder $own -Shares @(Share 'S' $link) -IsElevated $false -DriveType { 'Fixed' } } | Should -BeOfType ([SrrRefusalException])
        } finally { cmd /c rmdir "$link" | Out-Null }
    }
}

Describe 'DataPath and its fallback' {
    BeforeEach { $script:Root = New-TestDataPath; $script:Own = Join-Path $Root 'own'; New-Item -ItemType Directory $Own | Out-Null }
    It 'T48-11 an empty DataPath means SRRVRR''s own folder, with state\ and logs\ made there' {
        $r = Resolve-Test @{}
        $r.Path | Should -Be $Own; $r.IsFallback | Should -BeFalse
        Test-Path (Join-Path $Own 'state') | Should -BeTrue; Test-Path (Join-Path $Own 'logs') | Should -BeTrue
        $r.Lock.Dispose()
    }
    It 'T48-12 a missing DataPath falls back to the own folder and is never created' {
        $missing = Join-Path $Root 'unplugged'
        $r = Resolve-Test @{ Setting = $missing }
        $r.Path | Should -Be $Own; $r.IsFallback | Should -BeTrue; $r.Reason | Should -Be 'missing'
        Test-Path $missing | Should -BeFalse
        @($r.Notes | Where-Object { $_.Text -match [regex]::Escape($Own) }).Count | Should -BeGreaterThan 0
        $r.Lock.Dispose()
    }
    It 'T48-13 a read-only DataPath falls back and is left alone' {
        $ro = Join-Path $Root 'readonly'; New-Item -ItemType Directory $ro | Out-Null
        $r = Resolve-Test @{ Setting = $ro; TestWritable = { param($p) $p -ne $ro } }
        $r.IsFallback | Should -BeTrue; $r.Reason | Should -Be 'read-only'
        @(Get-ChildItem $ro).Count | Should -Be 0
        $r.Lock.Dispose()
    }
}

Describe 'The lock' {
    BeforeEach { $script:Root = New-TestDataPath; $script:Own = Join-Path $Root 'own'; $script:Data = Join-Path $Root 'data'; New-Item -ItemType Directory $Own, $Data | Out-Null }
    It 'T48-15 a data folder another copy holds refuses, naming the folder' {
        $first = Resolve-Test @{ Setting = $Data }
        try {
            $e = Get-Refusal { Resolve-Test @{ Setting = $Data } }
            $e | Should -BeOfType ([SrrRefusalException]); $e.Message | Should -Match 'another SRRVRR'
            # Even when the folder also looks read-only, a held lock is a refusal, never a fallback.
            $e = Get-Refusal { Resolve-Test @{ Setting = $Data; TestWritable = { $false } } }
            $e | Should -BeOfType ([SrrRefusalException])
        } finally { $first.Lock.Dispose() }
    }
    It 'T48-16 a lock file left by a crash doesn''t block a start, and a clean stop releases it' {
        New-Item -ItemType Directory (Join-Path $Data 'state') | Out-Null
        Set-Content (Join-Path $Data 'state\srrvrr.lock') 'left over'
        $r = Resolve-Test @{ Setting = $Data }
        $r.Path | Should -Be $Data
        $r.Lock.Dispose()
        { [IO.File]::Open((Join-Path $Data 'state\srrvrr.lock'), 'Open', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
    }
}

Describe 'Writing data and falling back later' {
    It 'T48-14 the first failed write switches to the fallback once, and writes stay there' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; $data = Join-Path $root 'data'; New-Item -ItemType Directory $own, $data | Out-Null
        $flags = New-Object System.Collections.Generic.List[string]
        $broken = @{ On = $false }
        $folder = New-DataFolder -Path $data -FallbackPath $own -OnFallback { param($why) $flags.Add($why) }.GetNewClosure() `
            -Writer { param($path, $text) if ($broken.On -and $path -like "$data*") { throw [UnauthorizedAccessException]::new('denied') }; [IO.File]::WriteAllText($path, $text) }.GetNewClosure()
        $folder.Write('state\a.json', '1')
        Test-Path (Join-Path $data 'state\a.json') | Should -BeTrue
        $broken.On = $true
        $folder.Write('state\a.json', '2'); $folder.Write('state\a.json', '3')
        [IO.File]::ReadAllText((Join-Path $own 'state\a.json')) | Should -Be '3'
        $flags.Count | Should -Be 1
        $broken.On = $false
        $folder.Write('state\a.json', '4')
        [IO.File]::ReadAllText((Join-Path $own 'state\a.json')) | Should -Be '4'
        $folder.IsFallback | Should -BeTrue
    }
    It 'T48-72 a full disk falls back the same way as a read-only folder' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; $data = Join-Path $root 'data'; New-Item -ItemType Directory $own, $data | Out-Null
        $flags = New-Object System.Collections.Generic.List[string]
        $folder = New-DataFolder -Path $data -FallbackPath $own -OnFallback { param($why) $flags.Add($why) }.GetNewClosure() `
            -Writer { param($path, $text) if ($path -like "$data*") { throw [IO.IOException]::new('There is not enough space on the disk.', -2147024784) }; [IO.File]::WriteAllText($path, $text) }.GetNewClosure()
        $folder.Write('logs\x.log', 'line')
        [IO.File]::ReadAllText((Join-Path $own 'logs\x.log')) | Should -Be 'line'
        $flags.Count | Should -Be 1
        $flags[0] | Should -Match 'not enough space'
    }
}

Describe 'The drives card' {
    BeforeAll {
        function Vol($Letter, $Type, $SizeGB, $Label = '') { [pscustomobject]@{ DeviceID = $Letter; DriveType = $Type; Size = [double]$SizeGB * 1GB; FreeSpace = 1GB; VolumeName = $Label } }
        $script:Vols = @((Vol 'C:' 3 400), (Vol 'D:' 3 0.5), (Vol 'G:' 2 29.5 'USB'), (Vol 'E:' 3 4000))
    }
    It 'T48-65 fixed drives as before, plus the removable drive that holds DataPath' {
        @(Select-DrivesToShow -Volumes $Vols -DataPaths @() | ForEach-Object DeviceID) | Should -Be @('C:', 'E:')
        @(Select-DrivesToShow -Volumes $Vols -DataPaths @('G:\SRRVRR') | ForEach-Object DeviceID) | Should -Be @('C:', 'E:', 'G:')
    }
    It 'T48-65 the data drive is shown even when it''s under 1 GB' {
        @(Select-DrivesToShow -Volumes $Vols -DataPaths @('D:\data') | ForEach-Object DeviceID) | Should -Contain 'D:'
    }
    It 'T48-66 a data drive that''s gone stays on the card as missing' {
        $d = @(Select-DrivesToShow -Volumes @((Vol 'C:' 3 400)) -DataPaths @('G:\SRRVRR'))
        $missing = $d | Where-Object { $_.DeviceID -eq 'G:' }
        $missing.Missing | Should -BeTrue
        $missing.Size | Should -Be 0
    }
    It 'T48-71 after a fallback both the fallback''s drive and the configured drive are watched, so it shows again when it''s back' {
        @(Select-DrivesToShow -Volumes $Vols -DataPaths @('G:\SRRVRR', 'C:\SRRVRR') | ForEach-Object DeviceID) | Should -Be @('C:', 'E:', 'G:')
        (@(Select-DrivesToShow -Volumes $Vols -DataPaths @('G:\SRRVRR', 'C:\SRRVRR')) | Where-Object { $_.DeviceID -eq 'G:' }).Missing | Should -BeFalse
    }
}

Describe 'Review fixes' {
    It 'T48-08 a machine with no shares gives an empty list, not an unreadable one' {
        Mock -ModuleName DataFolder Get-CimInstance { }
        $s = Get-ShareList
        $null -eq $s | Should -BeFalse
        @($s).Count | Should -Be 0
    }
    It 'T48-18 an account that no longer exists in the permissions doesn''t stop the plan' {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $ghost = New-Object Security.Principal.SecurityIdentifier 'S-1-5-21-1111111111-2222222222-3333333333-4444'
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($ghost, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $plan = Get-DataFolderAclPlan -Acl $acl
        @($plan.Remove | ForEach-Object { $_.IdentityReference.Value }) | Should -Be @($ghost.Value)
    }
    It 'T48-13 a data folder whose state\ is closed to this account falls back instead of crashing' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; $data = Join-Path $root 'data'
        New-Item -ItemType Directory $own, (Join-Path $data 'state'), (Join-Path $data 'logs') | Out-Null
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl (Join-Path $data 'state')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'CreateFiles, WriteData, AppendData', 'ContainerInherit,ObjectInherit', 'None', 'Deny')))
        Set-Acl (Join-Path $data 'state') $acl
        try {
            $r = Resolve-DataPath -Setting $data -OwnFolder $own -Shares @() -IsElevated $false -DriveType { 'Fixed' }
            $r.IsFallback | Should -BeTrue
            $r.Reason | Should -Be 'read-only'
            $r.Lock.Dispose()
        } finally {
            $acl = Get-Acl (Join-Path $data 'state')
            foreach ($rule in @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })) { [void]$acl.RemoveAccessRule($rule) }
            Set-Acl (Join-Path $data 'state') $acl
        }
    }
    It 'T48-19 a drive without permissions (FAT32, exFAT) is used as it is, with a note, never refused' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; New-Item -ItemType Directory $own | Out-Null
        Mock -ModuleName DataFolder Get-SrrFileSystem { 'exFAT' }
        Mock -ModuleName DataFolder Set-DataFolderAcl { throw 'should not be called' }
        $r = Resolve-DataPath -Setting '' -OwnFolder $own -Shares @() -IsElevated $true -DriveType { 'Removable' }
        Should -Invoke -ModuleName DataFolder Set-DataFolderAcl -Times 0
        @($r.Notes | Where-Object { $_.Text -match 'exFAT' }).Count | Should -Be 1
        $r.Lock.Dispose()
    }
}

Describe 'Permissions on a real folder' -Tag 'Integration' {
    It 'T48-19 write is removed for everyone but SYSTEM and Administrators, read stays, inheritance off, and a second run changes nothing' {
        $f = Join-Path (New-TestDataPath) 'acl'
        New-Item -ItemType Directory $f | Out-Null
        $acl = Get-Acl $f
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl $f $acl
        Set-DataFolderAcl -Path $f
        $after = Get-Acl $f
        $after.AreAccessRulesProtected | Should -BeTrue
        $write = [int][System.Security.AccessControl.FileSystemRights]'WriteData, AppendData, Delete'
        $writers = @($after.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
            $_.AccessControlType -eq 'Allow' -and ([int]$_.FileSystemRights -band $write) -and $_.IdentityReference.Value -notin 'S-1-5-18', 'S-1-5-32-544' })
        $writers | Should -BeNullOrEmpty
        @($after.Access | Where-Object { $_.IdentityReference.Value -eq 'BUILTIN\Users' -and $_.FileSystemRights -match 'ReadAndExecute' }).Count | Should -BeGreaterThan 0
        Mock -ModuleName DataFolder Write-FolderAcl { throw 'nothing should change' }
        { Set-DataFolderAcl -Path $f } | Should -Not -Throw
        Should -Invoke -ModuleName DataFolder Write-FolderAcl -Times 0
    }
}

Describe 'Permissions' {
    It 'T48-18 the plan removes write for everyone but SYSTEM and Administrators, keeps read, and turns inheritance off' {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $rule = { param($who, $rights) New-Object System.Security.AccessControl.FileSystemAccessRule($who, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow') }
        $acl.AddAccessRule((& $rule 'BUILTIN\Users' 'Modify'))
        $acl.AddAccessRule((& $rule 'Everyone' 'ReadAndExecute'))
        $acl.AddAccessRule((& $rule 'NT AUTHORITY\SYSTEM' 'FullControl'))
        $acl.AddAccessRule((& $rule 'BUILTIN\Administrators' 'FullControl'))
        $plan = Get-DataFolderAclPlan -Acl $acl
        $plan.DisableInheritance | Should -BeTrue
        @($plan.Remove | ForEach-Object { $_.IdentityReference.Value }) | Should -Be @('S-1-5-32-545')   # BUILTIN\Users, by id
        @($plan.Add | ForEach-Object { '{0}:{1}' -f $_.IdentityReference.Value, $_.FileSystemRights }) | Should -Be @('S-1-5-32-545:ReadAndExecute, Synchronize')
    }
    It 'T48-20 an unelevated start skips the permissions step and says so' {
        $root = New-TestDataPath; $own = Join-Path $root 'own'; New-Item -ItemType Directory $own | Out-Null
        Mock -ModuleName DataFolder Set-DataFolderAcl { }
        $r = Resolve-DataPath -Setting '' -OwnFolder $own -Shares @() -IsElevated $false -DriveType { 'Fixed' }
        Should -Invoke -ModuleName DataFolder Set-DataFolderAcl -Times 0
        @($r.Notes | Where-Object { $_.Text -match 'permissions' }).Count | Should -Be 1
        $r.Lock.Dispose()
    }
}
