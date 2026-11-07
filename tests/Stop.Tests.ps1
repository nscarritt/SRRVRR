# modules\Control.psm1: the stop event, the folder hash, the stopper and process selection (spec section 5).
BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Settings.psm1') -Force
    Import-Module (Join-Path (Get-RepoRoot) 'modules\Control.psm1') -Force
    $script:Me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $script:System = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $script:Admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $script:Everyone = New-Object Security.Principal.SecurityIdentifier 'S-1-1-0'
    function Rule($Sid, $Rights = 'FullControl') { New-Object System.Security.AccessControl.EventWaitHandleAccessRule($Sid, [System.Security.AccessControl.EventWaitHandleRights]$Rights, 'Allow') }
}

Describe 'T62-01 to T62-03 Get-SrrVersion reads VERSION' {
    BeforeAll {
        function New-VersionFolder([byte[]]$Bytes) {
            $f = New-TestDataPath
            if ($null -ne $Bytes) { [IO.File]::WriteAllBytes((Join-Path $f 'VERSION'), $Bytes) }
            $f
        }
        function Get-Ascii([string]$Text) { [Text.Encoding]::ASCII.GetBytes($Text) }
    }
    It 'T62-01 returns the one line, with or without a trailing newline, and no note' {
        foreach ($text in 'v0.8.0', "v0.8.0`n", "v0.8.0`r`n") {
            $r = Get-SrrVersion -Folder (New-VersionFolder (Get-Ascii $text))
            $r.Version | Should -Be 'v0.8.0'
            $r.Note | Should -BeNullOrEmpty
        }
        (Get-SrrVersion -Folder (New-VersionFolder (Get-Ascii ('x' * 64)))).Version | Should -Be ('x' * 64)
        (Get-SrrVersion -Folder (New-VersionFolder (Get-Ascii 'test-feature/x+abc1234'))).Version | Should -Be 'test-feature/x+abc1234'
    }
    It 'T62-02 says dev, with no note, when there is no VERSION file' {
        $r = Get-SrrVersion -Folder (New-VersionFolder $null)
        $r.Version | Should -Be 'dev'
        $r.Note | Should -BeNullOrEmpty
    }
    It 'T62-03 says unknown, with a note naming the problem, for <Name>' -ForEach @(
        @{ Name = 'two lines';        Bytes = [Text.Encoding]::ASCII.GetBytes("v0.8.0`nv0.9.0`n"); Match = 'more than one line' }
        @{ Name = '65 characters';    Bytes = [Text.Encoding]::ASCII.GetBytes('x' * 65);         Match = 'longer than 64' }
        @{ Name = 'a control char';   Bytes = [Text.Encoding]::ASCII.GetBytes("v0.8`t0");        Match = 'control character' }
        @{ Name = 'an empty file';    Bytes = [byte[]]@();                    Match = 'empty' }
        @{ Name = 'only a newline';   Bytes = [Text.Encoding]::ASCII.GetBytes("`r`n");           Match = 'empty' }
        @{ Name = 'non-ASCII text';   Bytes = [byte[]]@(0x76, 0xC3, 0xA9);    Match = 'non-ASCII' }
        @{ Name = 'a byte order mark'; Bytes = [byte[]]@(0xEF, 0xBB, 0xBF, 0x76); Match = 'non-ASCII' }
    ) {
        $r = Get-SrrVersion -Folder (New-VersionFolder $Bytes)
        $r.Version | Should -Be 'unknown'
        $r.Note | Should -Match 'VERSION'
        $r.Note | Should -Match $Match
    }
}

Describe 'T48-37 the stop event''s name' {
    It 'T48-37 one folder gives one name, whatever its case or trailing separator' {
        $f = New-TestDataPath
        ConvertTo-StopPath $f | Should -Be ((Get-Item -LiteralPath $f).FullName.TrimEnd('\').ToUpperInvariant())   # long names, as CI's temp folder is 8.3
        Get-StopEventName -Folder $f -Elevated $true | Should -Be (Get-StopEventName -Folder ($f.ToLowerInvariant() + '\') -Elevated $true)
        Get-StopEventName -Folder $f -Elevated $true | Should -Match '^Global\\SRRVRR-stop-[0-9a-f]{16}$'
        Get-StopEventName -Folder $f -Elevated $false | Should -Match '^Local\\SRRVRR-stop-[0-9a-f]{16}$'
    }
    It 'T48-37 two folders give two names' {
        Get-StopEventName -Folder (New-TestDataPath) -Elevated $true | Should -Not -Be (Get-StopEventName -Folder (New-TestDataPath) -Elevated $true)
    }
}

Describe 'T48-33 the stop event''s permissions' {
    It 'T48-33 elevated: only SYSTEM and Administrators' {
        $sids = @((New-StopEventSecurity -Elevated $true).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object)
        $sids | Should -Be @('S-1-5-18', 'S-1-5-32-544')
    }
    It 'T48-33 unelevated: only the current user' {
        $sids = @((New-StopEventSecurity -Elevated $false).GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value })
        $sids | Should -Be @($Me.Value)
    }
}

Describe 'T48-35 a stop event someone else made' {
    It 'T48-35 trusted only when its owner is SYSTEM or Administrators (or me, unelevated) and nobody else can signal it' {
        Test-StopEventTrusted -Owner $System -Rules @((Rule $System), (Rule $Admins)) -Elevated $true | Should -BeTrue
        Test-StopEventTrusted -Owner $Me -Rules @((Rule $Me)) -Elevated $true | Should -BeFalse
        Test-StopEventTrusted -Owner $System -Rules @((Rule $System), (Rule $Everyone 'Modify')) -Elevated $true | Should -BeFalse
        Test-StopEventTrusted -Owner $Me -Rules @((Rule $Me)) -Elevated $false | Should -BeTrue
        Test-StopEventTrusted -Owner $Me -Rules @((Rule $Me), (Rule $Everyone 'Synchronize, Modify')) -Elevated $false | Should -BeFalse
        Test-StopEventTrusted -Owner $Admins -Rules @((Rule $Admins), (Rule $Everyone 'Synchronize')) -Elevated $true | Should -BeTrue -Because 'waiting on it isn''t signalling it'
    }
    It 'T48-35 New-StopEvent refuses a name another process made first with open permissions' {
        $folder = New-TestDataPath
        $name = Get-StopEventName -Folder $folder -Elevated $false
        $open = New-Object System.Security.AccessControl.EventWaitHandleSecurity
        $open.AddAccessRule((Rule $Everyone 'FullControl'))
        $created = $false
        $squat = New-Object System.Threading.EventWaitHandle($false, 'ManualReset', $name, [ref]$created, $open)
        try {
            $e = try { New-StopEvent -Folder $folder -Elevated $false; $null } catch { $_.Exception }
            $e | Should -BeOfType ([SrrRefusalException])
            $e.Message | Should -Match 'stop event'
        } finally { $squat.Dispose() }
        $mine = New-StopEvent -Folder $folder -Elevated $false
        $mine | Should -Not -BeNullOrEmpty
        $mine.Dispose()
    }
}

Describe 'T48-39 which process a stop picks' {
    It 'T48-39 only copies running this folder''s SRRVRR.ps1, not -Stop calls, other folders or itself' {
        $f = New-TestDataPath
        $procs = @(
            [pscustomobject]@{ ProcessId = 1; CommandLine = "powershell.exe -NoProfile -File `"$f\SRRVRR.ps1`""; ExecutablePath = '' },
            [pscustomobject]@{ ProcessId = 2; CommandLine = "powershell -File `"$($f.ToLowerInvariant())\SRRVRR.ps1`" -Port 8091"; ExecutablePath = '' },
            [pscustomobject]@{ ProcessId = 3; CommandLine = "powershell -File `"$f\SRRVRR.ps1`" -Stop"; ExecutablePath = '' },
            [pscustomobject]@{ ProcessId = 4; CommandLine = "powershell -File `"$f-other\SRRVRR.ps1`""; ExecutablePath = '' },
            [pscustomobject]@{ ProcessId = 5; CommandLine = "powershell -File `"$f\SRRVRR.ps1`""; ExecutablePath = '' },
            [pscustomobject]@{ ProcessId = 6; CommandLine = "powershell -File `"$f\SRRVRR - test.ps1`""; ExecutablePath = '' }
        )
        @(Select-SRRVRRProcess -Folder $f -Processes $procs -SelfId 5 | ForEach-Object ProcessId) | Should -Be @(1, 2)
    }
}

Describe 'T48-38 the stopper' {
    It 'T48-38 writes stop-requested first, tries Global then Local, and signals with signal rights only' {
        $f = New-TestDataPath
        $order = New-Object System.Collections.Generic.List[string]
        $result = Invoke-StopCommand -Folder $f -Clock { [DateTimeOffset]::Now } -WaitSeconds 1 -Openers @{
            Open = { param($name) $order.Add("open $name"); if ($name -like 'Local\*') { 'handle' } else { $null } }.GetNewClosure()
            Signal = { param($h) $order.Add("signal $h") }.GetNewClosure()
            Processes = { @() }
            Kill = { param($id) $order.Add("kill $id") }.GetNewClosure()
        }
        Test-Path (Join-Path $f 'state\stop-requested') | Should -BeTrue
        $order[0] | Should -Match '^open Global\\SRRVRR-stop-'
        $order[1] | Should -Match '^open Local\\SRRVRR-stop-'
        $order[2] | Should -Be 'signal handle'
        $result.Signalled | Should -BeTrue
        $result.Forced | Should -BeFalse
    }
    It 'T48-40 a copy that doesn''t exit in time is force-stopped, only the processes for this folder' {
        $f = New-TestDataPath
        $killed = New-Object System.Collections.Generic.List[int]
        $procs = @([pscustomobject]@{ ProcessId = 42; CommandLine = "powershell -File `"$f\SRRVRR.ps1`"" })
        $result = Invoke-StopCommand -Folder $f -Clock { [DateTimeOffset]::Now } -WaitSeconds 1 -Openers @{
            Open = { param($name) 'handle' }; Signal = { }
            Processes = { $procs }.GetNewClosure()
            Kill = { param($id) $killed.Add($id) }.GetNewClosure()
        }
        $result.Forced | Should -BeTrue
        @($killed) | Should -Be @(42)
    }
    It 'T48-38 nothing running and no event says so, and stops nothing' {
        $f = New-TestDataPath
        $result = Invoke-StopCommand -Folder $f -Clock { [DateTimeOffset]::Now } -WaitSeconds 1 -Openers @{ Open = { $null }; Signal = { throw 'no' }; Processes = { @() }; Kill = { throw 'no' } }
        $result.Action | Should -Be 'not running'
        Test-Path (Join-Path $f 'state\stop-requested') | Should -BeFalse
    }
}

Describe 'T48-41 a real stop event' -Tag 'Integration' {
    It 'T48-41 a waiting runspace wakes on its folder''s signal, not another folder''s' {
        $f = New-TestDataPath; $other = New-TestDataPath
        $ev = New-StopEvent -Folder $f -Elevated $false
        try {
            Send-StopSignal -Name (Get-StopEventName -Folder $other -Elevated $false) | Should -BeFalse
            $ev.WaitOne(0) | Should -BeFalse
            Send-StopSignal -Name (Get-StopEventName -Folder $f -Elevated $false) | Should -BeTrue
            $ev.WaitOne(1000) | Should -BeTrue
        } finally { $ev.Dispose() }
    }
}
