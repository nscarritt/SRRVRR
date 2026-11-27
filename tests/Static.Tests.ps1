# Static checks of the design-for-testability rules (test plan section 3.2, rules marked S).
BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:ModuleFiles = @(Get-ChildItem -Path (Join-Path $root 'modules') -Filter '*.psm1' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
}

BeforeAll {
    Import-Module "$PSScriptRoot\TestHelpers.psm1" -Force
    function Get-CommandNames($ast) {
        @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    }
    function Get-Imports($ast) {
        @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
    }
    $script:EntryPath = Join-Path (Get-RepoRoot) 'SRRVRR.ps1'
}

Describe 'T47-09 module rules' -ForEach $ModuleFiles -AllowNullOrEmptyForEach {
    BeforeAll {
        $script:Ast = Get-ScriptAst $Path
        $script:Text = [IO.File]::ReadAllText($Path)
    }
    It 'T47-09 <Name> never reads the clock directly' {
        Get-CommandNames $Ast | Should -Not -Contain 'Get-Date'
        $Text | Should -Not -Match '\[(DateTime|DateTimeOffset)\]::(Utc)?Now'
    }
    It 'T47-09 <Name> has no Write-Host, Read-Host, exit, $global: or [Console]' {
        $names = Get-CommandNames $Ast
        $names | Should -Not -Contain 'Write-Host'
        $names | Should -Not -Contain 'Read-Host'
        @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.ExitStatementAst] }, $true)).Count | Should -Be 0
        $Text | Should -Not -Match '\$global:'
        $Text | Should -Not -Match '\[Console\]'
    }
    It 'T47-08 <Name> imports only sibling modules by full path' {
        foreach ($i in Get-Imports $Ast) { $i.Extent.Text | Should -Match '\$PSScriptRoot' }
        $Text | Should -Not -Match '#Requires\s+-Modules'
        $Text | Should -Not -Match 'PSModulePath'
    }
}

Describe 'T47-08 and T47-07 entry script rules' {
    It 'T47-08 SRRVRR.ps1 imports modules by full path and never touches PSModulePath' {
        $text = [IO.File]::ReadAllText($EntryPath)
        $text | Should -Not -Match 'PSModulePath'
        $text | Should -Not -Match '#Requires\s+-Modules'
        # A literal path under modules\, or a module-path variable the script builds from $PSScriptRoot\modules.
        foreach ($i in Get-Imports (Get-ScriptAst $EntryPath)) { $i.Extent.Text | Should -Match 'modules|\$\w*[Mm]odule\w*Path' }
    }
    It 'T47-07 the Steps count matches the Set-Step calls and the last step is Reticulating Splines' {
        $ast = Get-ScriptAst $EntryPath
        $calls = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Step' }, $true))
        $steps = [regex]::Match([IO.File]::ReadAllText($EntryPath), 'Steps\s*=\s*(\d+)').Groups[1].Value
        $calls.Count | Should -Be ([int]$steps)
        $calls[-1].CommandElements[1].Value | Should -Be 'Reticulating Splines...'
    }
}

#region 92
Describe 'T92-08 region 92 of Workstation.psm1 reads nothing itself' {
    It 'T92-08 region 92 defines its functions and calls no process, CIM, counter, file or clock functions (all come through $Readers)' {
        $path = Join-Path (Get-RepoRoot) 'modules\Workstation.psm1'
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $lines = [IO.File]::ReadAllLines($path)
        $open = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*#region 92\b' })
        $close = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*#endregion 92\b' })
        $open.Count | Should -Be 1 -Because 'one #region 92 line'
        $close.Count | Should -Be 1 -Because 'one #endregion 92 line'
        $from = $open[0] + 2; $to = $close[0]   # the region's own lines, 1-based
        $inRegion = { param($n) $n.Extent.StartLineNumber -ge $from -and $n.Extent.EndLineNumber -le $to }
        # The check means something only on the region's real code.
        $defined = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            Where-Object { & $inRegion $_ } | ForEach-Object { $_.Name })
        foreach ($f in 'Get-MemoryDetail', 'ConvertFrom-WslConfig', 'Get-WslReading', 'Get-TopPrograms', 'New-WorkstationContext', 'Invoke-WorkstationTick') {
            $defined | Should -Contain $f -Because 'region 92 defines it'
        }
        # Commands, by name and common alias.
        $commands = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) |
            Where-Object { & $inRegion $_ } | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        foreach ($c in 'Get-Process', 'gps', 'ps', 'Get-CimInstance', 'gcim', 'Get-WmiObject', 'gwmi', 'Get-Content', 'gc', 'cat', 'type') {
            $commands | Should -Not -Contain $c -Because 'region 92 gets its readings through $Readers'
        }
        # Types and clock calls, in the region's code with its comments blanked out.
        $chars = [IO.File]::ReadAllText($path).ToCharArray()
        foreach ($t in $tokens) {
            if ($t.Kind -ne 'Comment') { continue }
            for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset; $i++) { if ($chars[$i] -ne "`n" -and $chars[$i] -ne "`r") { $chars[$i] = ' ' } }
        }
        $code = ((New-Object string (, $chars)) -split "`n")[($from - 1)..($to - 1)] -join "`n"
        $code | Should -Not -Match 'PerformanceCounterCategory'
        $code | Should -Not -Match '\[\s*(System\.)?IO\.File\s*\]'
        $code | Should -Not -Match '\[\s*(System\.)?DateTime(Offset)?\s*\]\s*::\s*(UtcNow|Now|Today)\b'
    }
}
#endregion 92
#region 93 The AI server boundary (#93, test plan 6.13; spec Q9 and section 6; plan Global Constraints)
Describe 'T93-05 the AI server boundary in the code' {
    BeforeAll {
        # A script's text with its comments blanked out (offsets kept), and its syntax tree from the same parse.
        function Get-CodeView([string]$Path) {
            $text = [IO.File]::ReadAllText($Path)
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            $chars = $text.ToCharArray()
            foreach ($t in $tokens) {
                if ($t.Kind -ne 'Comment') { continue }
                for ($i = $t.Extent.StartOffset; $i -lt $t.Extent.EndOffset; $i++) { if ($chars[$i] -ne "`n") { $chars[$i] = ' ' } }
            }
            @{ Code = (-join $chars); Ast = $ast }
        }
        function Remove-Extent([string]$Code, $Extent) {
            $chars = $Code.ToCharArray()
            for ($i = $Extent.StartOffset; $i -lt $Extent.EndOffset; $i++) { if ($chars[$i] -ne "`n") { $chars[$i] = ' ' } }
            -join $chars
        }
        # Every way of starting wsl, or a Linux distro that runs inside it, outside comments: a wsl, bash, distro
        # launcher (ubuntu*.exe, debian.exe, kali.exe, opensuse*.exe and the like) or wslapi command, a string naming
        # one with .exe or .dll, a bare launcher name as an argument (Start-Process wsl), a 'wsl ...' or 'bash -...'
        # command line, a path to one ('\wsl', \wsl$, '\ubuntu.exe'), or the wslapi calls (WslLaunch*).
        # 'WSL VM', vmmemWSL, .wslconfig and [wsl2] are fine, and so is a member or key named wsl ($State.wsl,
        # $State['wsl'], @{ wsl = ... }): reading the WSL VM's numbers starts nothing.
        $script:Launchers = 'wsl|wslg|wslapi|bash|ubuntu\d*|debian|kali(-linux)?|opensuse[\w.-]*|sles[\w.-]*|oraclelinux[\w.-]*|archlinux|fedora\w*|alpine|pengwin'
        function Get-TextView([string]$Text) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
            @{ Code = $Text; Ast = $ast }
        }
        function Find-WslUse($View) {
            $found = New-Object System.Collections.Generic.List[string]
            foreach ($c in $View.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $name = $c.GetCommandName()
                if ($name -and $name -match "(?i)(^|[\/])($Launchers)(\.exe|\.dll)?$") { $found.Add("line $($c.Extent.StartLineNumber): command $name") }
            }
            $strings = $View.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
            foreach ($s in $strings) {
                $v = [string]$s.Value
                $p = $s.Parent
                $isMember = $p -is [Management.Automation.Language.MemberExpressionAst] -and [object]::ReferenceEquals($p.Member, $s)
                $isKey = ($p -is [Management.Automation.Language.HashtableAst] -and @($p.KeyValuePairs | Where-Object { [object]::ReferenceEquals($_.Item1, $s) }).Count -gt 0) -or
                    ($p -is [Management.Automation.Language.IndexExpressionAst] -and [object]::ReferenceEquals($p.Index, $s))
                if (($v -match "(?i)^($Launchers)(\.exe|\.dll)?$" -and -not $isMember -and -not $isKey) -or
                    $v -match "(?i)\b($Launchers)\.(exe|dll)\b" -or $v -match '(?i)WslLaunch|wslapi' -or
                    $v -match "(?i)(^|[\s\\/""'])($Launchers)\s+-" -or $v -cmatch '(^|[\s"''&;|(])wsl\s' -or
                    $v -match "(?i)\\($Launchers)(\.exe)?(\s|$|""|')" -or $v -match '(?i)\\wsl') {
                    $found.Add("line $($s.Extent.StartLineNumber): '$v'")
                }
            }
            $found.ToArray()   # unrolled: nothing when there is no wsl
        }
        function Get-StringValues($View) {
            @($View.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst] }, $true) | ForEach-Object { [string]$_.Value })
        }
        # ComfyUI's other endpoints, with or without its /api prefix: prompts, history, images, uploads, unloading models.
        $script:ForbiddenPaths = '(?i)/(queue|history|ws|view|interrupt|upload|free)\b'
        $script:NetworkApis = '(?i)WebRequest|WebClient|HttpClient|RestMethod|TcpClient|TcpListener|UdpClient|Net\.Sockets|\bSockets?\b|BitsTransfer|DownloadString|DownloadFile|ServicePoint'
        $script:WsModule = Get-CodeView (Join-Path (Get-RepoRoot) 'modules\Workstation.psm1')
        $script:WsEntry = Get-CodeView (Join-Path (Get-RepoRoot) 'SRRVRR.ps1')
        $script:Reader = $WsModule.Ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-LocalHttp' }, $true)
    }
    It 'T93-05 Find-WslUse catches every way of starting wsl or a Linux distro in sample lines' {
        $bad = @(
            'wsl.exe -l', 'wsl -d Ubuntu', 'Start-Process wsl', "Start-Process 'wsl.exe'", '& "C:\Windows\System32\wsl.exe" --status',
            '$x = ''wsl --shutdown''', 'cmd /c "wsl -e ls"', 'bash -c "ls"', 'bash.exe -c ls', "Start-Process bash", '& C:\Windows\System32\bash.exe',
            'ubuntu.exe run ls', 'ubuntu2204.exe', 'ubuntu2404.exe run ls', 'debian.exe', 'kali.exe', 'opensuse-leap-15.exe', 'opensuse42.exe',
            'Start-Process "C:\Users\x\AppData\Local\Microsoft\WindowsApps\Ubuntu.exe"', 'cmd /c "bash -lc ls"',
            '[DllImport("wslapi.dll")] $x', "Add-Type 'WslLaunch'", '$h = WslLaunchInteractive', "Add-Type -Path 'wslapi'",
            '$p = ''\wsl$\Ubuntu\home'''
        )
        foreach ($line in $bad) { @(Find-WslUse (Get-TextView $line)).Count | Should -BeGreaterThan 0 -Because "[$line] starts wsl or a distro" }
    }
    It 'T93-05 Find-WslUse passes the allowed uses in sample lines (vmmemWSL, .wslconfig, the wsl key, WSL VM text)' {
        $ok = @(
            '$n = ''vmmemWSL''', '$p = ''C:\Users\x\.wslconfig''', '$s = $State.wsl', '$s = $State[''wsl'']', '$h = @{ wsl = 1 }', '$h = @{ ''wsl'' = 1 }',
            '$t = ''WSL VM''', '$t = "WSL VM: $x"', '# wsl.exe -l is a comment', '$c = ''[wsl2]''', '$s = $State.bash',
            '$t = ''Debian is a distro''', '$t = ''the bash shell'''
        )
        foreach ($line in $ok) { @(Find-WslUse (Get-TextView $line)).Count | Should -Be 0 -Because "[$line] starts nothing" }
    }
    It 'T93-05 Read-LocalHttp is a GET to the literal http://127.0.0.1:, with no proxy, no redirects, no keep-alive and no body' {
        $Reader | Should -Not -BeNullOrEmpty -Because 'modules\Workstation.psm1 defines Read-LocalHttp'
        $fn = $WsModule.Code.Substring($Reader.Extent.StartOffset, $Reader.Extent.EndOffset - $Reader.Extent.StartOffset)
        $fn | Should -Match 'HttpWebRequest'
        $fn | Should -Match '[''"]http://127\.0\.0\.1:[''"]'
        $fn | Should -CMatch '[''"]GET[''"]'
        $fn | Should -Match '(?i)\.Method\s*=\s*[''"]GET[''"]'
        $fn | Should -Match '(?i)\.Proxy\s*=\s*\$null'
        $fn | Should -Match '(?i)\.AllowAutoRedirect\s*=\s*\$false'
        $fn | Should -Match '(?i)\.KeepAlive\s*=\s*\$false'
        $fn | Should -Not -Match '(?i)GetRequestStream|\.Host\s*=|\.ContentLength\s*=|\.Credentials\s*=|UseDefaultCredentials|CookieContainer'
    }
    It 'T93-05 in the module only Read-LocalHttp does network I/O; every URL is http://127.0.0.1:; GET only; no wsl; no other ComfyUI path' {
        $Reader | Should -Not -BeNullOrEmpty -Because 'modules\Workstation.psm1 defines Read-LocalHttp'
        (Remove-Extent $WsModule.Code $Reader.Extent) | Should -Not -Match $NetworkApis
        foreach ($m in [regex]::Matches($WsModule.Code, '(?i)\b[a-z][a-z0-9+.-]*://[^\s''"]*')) { $m.Value | Should -Match '^http://127\.0\.0\.1:' }
        $WsModule.Code | Should -Not -Match '(?i)\blocalhost\b|\[::1\]|0\.0\.0\.0'
        $WsModule.Code | Should -Not -Match '(?i)[''"](POST|PUT|DELETE|PATCH|HEAD|OPTIONS|CONNECT|TRACE)[''"]'
        Find-WslUse $WsModule | Should -BeNullOrEmpty
        $WsModule.Code | Should -Not -Match $ForbiddenPaths
        @(Get-StringValues $WsModule | Where-Object { $_ -match '^/[A-Za-z_]' } | Sort-Object -Unique) | Should -Be @('/prompt', '/system_stats')
    }
    It 'T93-05 SRRVRR.ps1 reaches the AI server only through Read-LocalHttp, runs no wsl, and no other module reaches it (no relay)' {
        @($WsEntry.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Read-LocalHttp' }, $true)).Count |
            Should -BeGreaterThan 0 -Because 'the startup probe and the Http reader call Read-LocalHttp'
        Find-WslUse $WsEntry | Should -BeNullOrEmpty
        $WsEntry.Code | Should -Not -Match $ForbiddenPaths
        $WsEntry.Code | Should -Not -Match '(?i)HttpWebRequest|WebClient|HttpClient|TcpClient'
        # The web cmdlets SRRVRR.ps1 already uses are for Plex only.
        $web = @($WsEntry.Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Invoke-WebRequest', 'Invoke-RestMethod', 'iwr', 'irm', 'curl', 'wget' }, $true))
        foreach ($c in $web) { $c.Extent.Text | Should -Match '\$plexUrl' -Because "line $($c.Extent.StartLineNumber) is a web request" }
        foreach ($f in Get-ChildItem (Join-Path (Get-RepoRoot) 'modules') -Filter '*.psm1') {
            Find-WslUse (Get-CodeView $f.FullName) | Should -BeNullOrEmpty -Because "$($f.Name) starts no wsl, bash or distro"
        }
        foreach ($f in Get-ChildItem (Join-Path (Get-RepoRoot) 'modules') -Filter '*.psm1' | Where-Object { $_.Name -ne 'Workstation.psm1' }) {
            (Get-CodeView $f.FullName).Code | Should -Not -Match "(?i)Read-LocalHttp|Invoke-WorkstationTick|$($NetworkApis.Substring(4))" -Because "$($f.Name) never reaches the AI server"
        }
    }
}
#endregion 93
