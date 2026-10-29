# Settings: defaults, SRRVRR.config.psd1, and validation. Invalid settings throw one plain message; everything
# worth telling the user comes back as Notes (@{ Level = 'Note' | 'Warning'; Text }) for SRRVRR.ps1 to print.

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

# Checks a complete settings table. Returns @{ Settings; Notes } or throws one plain message.
function Test-SrrSettings([hashtable]$Settings) {
    $notes = New-Object System.Collections.Generic.List[hashtable]
    if ($Settings.ValheimPort -isnot [int] -or $Settings.ValheimPort -lt 1 -or $Settings.ValheimPort -gt 65534) {
        throw "ValheimPort must be the Valheim server's game port, a number from 1 to 65534 (default 2456)."
    }
    $scopes = 'LocalSubnet', 'Allowlist', 'Blocklist'
    if ($Settings.FirewallScope -notin $scopes) { throw "FirewallScope must be one of: $($scopes -join ', ')" }
    if ($Settings.FirewallScope -in 'Allowlist', 'Blocklist' -and -not $Settings.FirewallAddresses) {
        throw "FirewallScope '$($Settings.FirewallScope)' needs at least one address in FirewallAddresses."
    }
    # The one exception to private addresses: with AllowPublicAddresses, an Allowlist may also name single
    # public IPs, at the user's own risk (see the README's security warning).
    $public = @($Settings.FirewallAddresses | Where-Object { -not (Test-PrivateAddress $_) })
    if ($Settings.FirewallScope -ne 'LocalSubnet' -and $public) {
        if ($Settings.FirewallScope -ne 'Allowlist' -or -not $Settings.AllowPublicAddresses) {
            $hint = if ($Settings.FirewallScope -eq 'Allowlist') { ' To let specific public IPs in AT YOUR OWN RISK, set AllowPublicAddresses = $true (read the README security warning first).' } else { '' }
            throw "FirewallAddresses must be private (local network) addresses. Not allowed: $($public -join ', ').$hint"
        }
        $wide = @($public | Where-Object { -not (Test-SingleAddress $_) })
        if ($wide) { throw "Public addresses must be single IPs, not ranges, subnets or 'any' addresses. Not allowed: $($wide -join ', ')" }
        $notes.Add(@{ Level = 'Warning'; Text = ("SECURITY: AllowPublicAddresses is on. The firewall will let these INTERNET addresses open the page, " +
            "which has no password and no encryption: $($public -join ', '). You accept this risk; see the README security warning.") })
    }
    @{ Settings = $Settings; Notes = $notes }
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
        $config = Import-PowerShellDataFile -LiteralPath $configPath
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

Export-ModuleMember -Function Get-SrrDefaultSettings, Get-SrrRetiredSettings, Test-PrivateAddress, Test-SingleAddress,
    Test-SrrSettings, Import-SrrSettings
