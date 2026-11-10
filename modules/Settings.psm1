# Settings: defaults, SRRVRR.config.psd1, and validation. Invalid settings throw one plain message; everything
# worth telling the user comes back as Notes (@{ Level = 'Note' | 'Warning'; Text }) for SRRVRR.ps1 to print.
# Also the exit codes: a settings error exits 2, a refusal to start 3, anything else 1 (spec section 5).

# The two exceptions that set the exit code, compiled once even when the module is imported again.
if (-not ('SrrSettingsException' -as [type])) {
    Add-Type -TypeDefinition @'
public class SrrSettingsException : System.Exception { public SrrSettingsException(string message) : base(message) { } }
public class SrrRefusalException : System.Exception { public SrrRefusalException(string message) : base(message) { } }
'@
}

function New-SettingsError([string]$Message) { New-Object SrrSettingsException $Message }

# Defaults, replaced by anything set in SRRVRR.config.psd1.
function Get-SrrDefaultSettings {
    @{
        Port                 = 8099
        FirewallScope        = 'LocalSubnet'
        FirewallAddresses    = @()
        AllowPublicAddresses = $false
        PreferredGpu         = ''
        Processes            = @{}
        ValheimPort          = 2456
        DataPath             = ''
        NamedPCs             = @()
        TransferFolders      = $true
        LogRetentionDays     = 31
        MaintenanceHours     = 2
        MaintenanceMaxHours  = 8
        BurstFiles           = 500
        BurstWindowSeconds   = 60
        BurstQuietMinutes    = 5
        DriveWarnPercent     = 85
        DriveFullPercent     = 95
        BottleneckPercent    = 80
    }
}

# Settings from older versions, now handled automatically.
function Get-SrrRetiredSettings {
    @{
        ListenAddress = 'the monitor always listens on this machine''s own addresses'
        OpenFirewall  = 'the firewall rule is always set up, since other PCs need it'
        GpuFallback   = 'without a PreferredGpu, the GPU with the most video memory is used'
    }
}

# The page is meant for local networks, so firewall addresses must be private:
# 10.x, 172.16-31.x, 192.168.x, 169.254.x, 127.x, or IPv6 fe80::/10 and fc00::/7.
function Test-PrivateAddress([string]$Entry) {
    function Test-Ip([string]$text, [int]$prefix) {
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ip)) { return $false }
        $b = $ip.GetAddressBytes()
        if ($b.Length -eq 4) {
            # The whole subnet must fit inside one private block.
            $blocks = @(@(10, 0, 8), @(172, 16, 12), @(192, 168, 16), @(169, 254, 16), @(127, 0, 8))
            foreach ($blk in $blocks) {
                $inBlock = if ($blk[2] -eq 8) { $b[0] -eq $blk[0] } elseif ($blk[2] -eq 12) { $b[0] -eq $blk[0] -and ($b[1] -band 0xF0) -eq $blk[1] } else { $b[0] -eq $blk[0] -and $b[1] -eq $blk[1] }
                if ($inBlock -and $prefix -ge $blk[2]) { return $true }
            }
            return $false
        }
        if ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0x80) { return $prefix -ge 10 }   # fe80::/10 link-local
        if (($b[0] -band 0xFE) -eq 0xFC) { return $prefix -ge 7 }                          # fc00::/7 unique local
        return $false
    }
    if ($Entry -match '^(.+)/(\d+)$') { return Test-Ip $matches[1] ([int]$matches[2]) }
    if ($Entry -match '^(.+)-(.+)$') { return (Test-Ip $matches[1] 128) -and (Test-Ip $matches[2] 128) }
    Test-Ip $Entry 128
}

# One specific address, written out in full: no ranges, subnets or "any" addresses.
function Test-SingleAddress([string]$Entry) {
    $ip = $null
    if ($Entry -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and $Entry -notmatch ':') { return $false }
    if (-not [System.Net.IPAddress]::TryParse($Entry, [ref]$ip)) { return $false }
    -not ($ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any) -or $ip.Equals([System.Net.IPAddress]::Broadcast))
}

# An address as the PC list compares it (the same form as ConvertTo-PcAddress in modules\Transfers.psm1, which this
# module can't import: it is loaded first): IPv4-mapped IPv6 back to IPv4, brackets and zone id dropped, lower case.
# $null for anything that isn't an address.
function Get-NormalizedPcAddress([string]$Address) {
    if (-not $Address) { return $null }
    $text = ($Address.Trim() -replace '^\[|\]$', '') -replace '%.*$', ''
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($text, [ref]$ip)) { return $null }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $ip.ToString().ToLowerInvariant()
}

# NamedPCs and TransferFolders (spec section 7).
function Test-PcSettings([hashtable]$Settings) {
    $shape = 'NamedPCs must be a list of up to 32 entries like @{ Name = ''Desk PC''; Addresses = @(''192.0.2.10'') } (default: none).'
    $list = $Settings.NamedPCs
    if ($null -eq $list) { $list = @() }
    if ($list -is [string] -or $list -is [Collections.IDictionary]) { throw (New-SettingsError $shape) }
    $entries = @($list)
    if ($entries.Count -gt 32) { throw (New-SettingsError "NamedPCs has $($entries.Count) entries; at most 32 are allowed.") }
    $names = @{}; $addresses = @{}
    $n = 0
    foreach ($e in $entries) {
        $n++
        if ($e -isnot [Collections.IDictionary]) { throw (New-SettingsError $shape) }
        foreach ($k in @($e.Keys)) {
            if ($k -notin 'Name', 'Addresses') { throw (New-SettingsError "NamedPCs entry $n has an unknown key '$k'; only Name and Addresses are allowed.") }
        }
        $name = $e['Name']
        if ($name -isnot [string] -or $name.Length -lt 1 -or $name.Length -gt 40 -or $name -match '[\x00-\x1f\x7f]') {
            throw (New-SettingsError "NamedPCs entry $n needs a Name of 1 to 40 printable characters.")
        }
        if ($names.ContainsKey($name.ToLowerInvariant())) { throw (New-SettingsError "NamedPCs has the Name '$name' more than once (capital letters don't count); each Name must be different.") }
        $names[$name.ToLowerInvariant()] = $true
        $list = @($e['Addresses'])
        if ($null -eq $e['Addresses'] -or $list.Count -lt 1 -or $list.Count -gt 8) { throw (New-SettingsError "NamedPCs entry '$name' needs 1 to 8 Addresses.") }
        foreach ($a in $list) {
            $form = if ($a -is [string]) { Get-NormalizedPcAddress $a } else { $null }
            $ip = $null
            $plain = $form -and ($a.Trim() -match ':' -or $a.Trim() -match '^\d{1,3}(\.\d{1,3}){3}$')
            if ($plain) { $plain = [System.Net.IPAddress]::TryParse($form, [ref]$ip) }
            if (-not $plain) { throw (New-SettingsError "NamedPCs entry '$name': Addresses must be single IPv4 or IPv6 addresses (no ranges, subnets or names), and '$a' isn't one.") }
            $bytes = $ip.GetAddressBytes()
            $bad = $ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any) -or $ip.Equals([System.Net.IPAddress]::Broadcast) -or [System.Net.IPAddress]::IsLoopback($ip) -or
                ($bytes.Length -eq 4 -and $bytes[0] -ge 224) -or ($bytes.Length -eq 16 -and $bytes[0] -eq 0xFF)
            if ($bad) { throw (New-SettingsError "NamedPCs entry '$name': Addresses can't be loopback, unspecified, multicast or broadcast addresses, and '$a' is one.") }
            if ($addresses.ContainsKey($form)) { throw (New-SettingsError "NamedPCs lists '$a' in Addresses more than once; an address can belong to only one PC.") }
            $addresses[$form] = $true
        }
    }
    if ($Settings.TransferFolders -isnot [bool]) {
        throw (New-SettingsError 'TransferFolders must be $true or $false: $false keeps only counts of open files per PC, with no folders on the page or in the log (default $true).')
    }
}

# Checks a complete settings table. Returns @{ Settings; Notes } or throws one plain message.
function Test-SrrSettings([hashtable]$Settings) {
    $notes = New-Object System.Collections.Generic.List[hashtable]
    if ($Settings.ValheimPort -isnot [int] -or $Settings.ValheimPort -lt 1 -or $Settings.ValheimPort -gt 65534) {
        throw (New-SettingsError "ValheimPort must be the Valheim server's game port, a number from 1 to 65534 (default 2456).")
    }
    $scopes = 'LocalSubnet', 'Allowlist', 'Blocklist'
    if ($Settings.FirewallScope -notin $scopes) { throw (New-SettingsError "FirewallScope must be one of: $($scopes -join ', ')") }
    if ($Settings.FirewallScope -in 'Allowlist', 'Blocklist' -and -not $Settings.FirewallAddresses) {
        throw (New-SettingsError "FirewallScope '$($Settings.FirewallScope)' needs at least one address in FirewallAddresses.")
    }
    # The one exception to private addresses: with AllowPublicAddresses, an Allowlist may also name single
    # public IPs, at the user's own risk (see the README's security warning).
    $public = @($Settings.FirewallAddresses | Where-Object { -not (Test-PrivateAddress $_) })
    if ($Settings.FirewallScope -ne 'LocalSubnet' -and $public) {
        if ($Settings.FirewallScope -ne 'Allowlist' -or -not $Settings.AllowPublicAddresses) {
            $hint = if ($Settings.FirewallScope -eq 'Allowlist') { ' To let specific public IPs in AT YOUR OWN RISK, set AllowPublicAddresses = $true (read the README security warning first).' } else { '' }
            throw (New-SettingsError "FirewallAddresses must be private (local network) addresses. Not allowed: $($public -join ', ').$hint")
        }
        $wide = @($public | Where-Object { -not (Test-SingleAddress $_) })
        if ($wide) { throw (New-SettingsError "Public addresses must be single IPs, not ranges, subnets or 'any' addresses. Not allowed: $($wide -join ', ')") }
        $notes.Add(@{ Level = 'Warning'; Text = ("SECURITY: AllowPublicAddresses is on. The firewall will let these INTERNET addresses open the page, " +
            "which has no password and no encryption: $($public -join ', '). You accept this risk; see the README security warning.") })
    }
    Test-NewSettings $Settings
    @{ Settings = $Settings; Notes = $notes }
}

function Test-Number($Value) { $Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] }

# The write-burst settings (v0.9.0 design, section 7): whole numbers within a range, one plain message each.
function Test-BurstSettings([hashtable]$Settings) {
    $rules = @(
        @{ Name = 'BurstFiles'; Min = 50; Max = 100000; Default = 500; What = 'how many files one PC opens while writing, within BurstWindowSeconds, for SRRVRR to flag a write burst' }
        @{ Name = 'BurstWindowSeconds'; Min = 10; Max = 600; Default = 60; What = 'the number of seconds in which a PC must open BurstFiles files to count as a write burst' }
        @{ Name = 'BurstQuietMinutes'; Min = 1; Max = 60; Default = 5; What = 'the minutes a PC must stay below the burst threshold for a write burst to end' }
    )
    foreach ($r in $rules) {
        $v = $Settings[$r.Name]
        if (-not ($v -is [int] -or $v -is [long]) -or $v -lt $r.Min -or $v -gt $r.Max) {
            throw (New-SettingsError "$($r.Name) must be a whole number from $($r.Min) to $($r.Max), $($r.What) (default $($r.Default)).")
        }
    }
}

# The settings added in v0.7.0 (spec section 6).
function Test-NewSettings([hashtable]$Settings) {
    $d = $Settings.DataPath
    # A full local path with a drive letter. Whether it exists isn't checked here: a missing or read-only folder
    # falls back to SRRVRR's own folder at start (spec section 3), so a drive that's unplugged never stops SRRVRR.
    if ($d -isnot [string] -or ($d -ne '' -and $d -notmatch '^[A-Za-z]:\\')) {
        throw (New-SettingsError "DataPath must be empty (SRRVRR's own folder) or a full local folder path with a drive letter, like 'D:\SRRVRR'; not a relative or network path.")
    }
    Test-PcSettings $Settings
    $days = $Settings.LogRetentionDays
    if (-not ($days -is [int] -or $days -is [long]) -or $days -lt 7 -or $days -gt 366) {
        throw (New-SettingsError 'LogRetentionDays must be a whole number of days from 7 to 366 (default 31).')
    }
    Test-BurstSettings $Settings
    $max = $Settings.MaintenanceMaxHours
    if (-not (Test-Number $max) -or $max -lt 1 -or $max -gt 24) {
        throw (New-SettingsError 'MaintenanceMaxHours must be a number of hours from 1 to 24 (default 8).')
    }
    $hours = $Settings.MaintenanceHours
    if (-not (Test-Number $hours) -or $hours -lt 0.25 -or $hours -gt $max) {
        throw (New-SettingsError "MaintenanceHours must be a number of hours from 0.25 up to MaintenanceMaxHours ($max) (default 2).")
    }
    foreach ($name in 'DriveWarnPercent', 'DriveFullPercent') {
        $v = $Settings[$name]
        $default = if ($name -eq 'DriveWarnPercent') { 85 } else { 95 }
        $what = if ($name -eq 'DriveWarnPercent') { 'warns that a drive is filling up' } else { 'flags a drive as almost full' }
        if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 50 -or $v -gt 99) {
            throw (New-SettingsError "$name must be a whole number from 50 to 99, the percent of a drive that is used when SRRVRR $what (default $default).")
        }
    }
    if ($Settings.DriveWarnPercent -ge $Settings.DriveFullPercent) {
        throw (New-SettingsError "DriveWarnPercent ($($Settings.DriveWarnPercent)) must be lower than DriveFullPercent ($($Settings.DriveFullPercent)).")
    }
    Test-BottleneckSetting $Settings
}

# The settings added in v0.9.0 for the Transfers card: BottleneckPercent (the others are validated beside their stories).
function Test-BottleneckSetting([hashtable]$Settings) {
    $v = $Settings.BottleneckPercent
    if (-not ($v -is [int] -or $v -is [long]) -or $v -lt 50 -or $v -gt 99) {
        throw (New-SettingsError 'BottleneckPercent must be a whole number from 50 to 99, the percent of its limit at which the Transfers card names a resource as the bottleneck (default 80).')
    }
}

# The exit code for whatever stopped SRRVRR: 2 for a settings error, 3 for a refusal to start, 1 for anything else.
# Looks through the exceptions PowerShell wraps around the real one.
function Get-SrrExitCode([Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [SrrSettingsException]) { return 2 }
        if ($e -is [SrrRefusalException]) { return 3 }
        $e = $e.InnerException
    }
    1
}

# Why SRRVRR stopped, for its last log line: "settings error", "refused: <why>" or "crash: <exception type>".
function Get-SrrStopReason([Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [SrrSettingsException]) { return 'settings error' }
        if ($e -is [SrrRefusalException]) { return "refused: $($e.Message)" }
        $e = $e.InnerException
    }
    "crash: $(if ($Exception) { $Exception.GetType().FullName } else { 'unknown' })"
}

function Format-StopLine([string]$Reason, [int]$Code) {
    "stopped: $Reason (exit $Code)"
}

# Reads SRRVRR.config.psd1 from Folder (or the pre-rename SystemMonitor.config.psd1 when it's the only one),
# applies -Port, and validates. Returns @{ Settings; Notes; Path } or throws.
function Import-SrrSettings {
    param([Parameter(Mandatory)][string]$Folder, [int]$Port)
    $settings = Get-SrrDefaultSettings
    $retired = Get-SrrRetiredSettings
    $notes = New-Object System.Collections.Generic.List[hashtable]
    $configPath = Join-Path $Folder 'SRRVRR.config.psd1'
    $legacy = Join-Path $Folder 'SystemMonitor.config.psd1'
    if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $legacy)) {
        $configPath = $legacy
        $notes.Add(@{ Level = 'Note'; Text = 'Note: using the old settings file name SystemMonitor.config.psd1; rename it to SRRVRR.config.psd1.' })
    }
    if (Test-Path -LiteralPath $configPath) {
        try { $config = Import-PowerShellDataFile -LiteralPath $configPath -ErrorAction Stop }
        catch { throw (New-SettingsError "$([IO.Path]::GetFileName($configPath)) couldn't be read: $($_.Exception.Message)") }
        foreach ($k in $config.Keys) {
            if ($settings.ContainsKey($k)) { $settings[$k] = $config[$k] }
            elseif ($retired.ContainsKey($k)) { $notes.Add(@{ Level = 'Note'; Text = "Note: setting '$k' is no longer used ($($retired[$k])); you can delete it from the config." }) }
            else { $notes.Add(@{ Level = 'Warning'; Text = "Unknown setting '$k' in $configPath (ignored)." }) }
        }
        $notes.Add(@{ Level = 'Note'; Text = "Settings loaded from $configPath" })
    } else {
        $configPath = $null
        $notes.Add(@{ Level = 'Note'; Text = 'No SRRVRR.config.psd1 found, using default settings. Copy SRRVRR.config.example.psd1 to SRRVRR.config.psd1 to change them.' })
    }
    if ($PSBoundParameters.ContainsKey('Port')) { $settings.Port = $Port }
    $checked = Test-SrrSettings $settings
    foreach ($n in $checked.Notes) { $notes.Add($n) }
    @{ Settings = $settings; Notes = $notes; Path = $configPath }
}

Export-ModuleMember -Function Get-SrrDefaultSettings, Get-SrrRetiredSettings, Test-PrivateAddress, Test-SingleAddress, Get-NormalizedPcAddress,
    Test-SrrSettings, Import-SrrSettings, Get-SrrExitCode, Get-SrrStopReason, Format-StopLine
