<#
  SRRVRR.ps1 - a tiny live CPU / memory / GPU / network monitor for the SRRVRR server.

  Run it on the machine you want to watch, then open http://<that-machine>:8099
  in any browser. Press Ctrl+C in this window to stop it, or run Stop SRRVRR.bat
  (SRRVRR.ps1 -Stop) from anywhere on the machine.

  Settings (port, firewall, GPU, processes) live in SRRVRR.config.psd1 next to
  this script; copy SRRVRR.config.example.psd1 to create it.
  Run as administrator so other PCs can open the page and the firewall rule
  can be managed.
#>
param(
    [int]$Port,   # overrides Port from the config file
    [switch]$Stop # stop a running SRRVRR (the live or the test copy) instead of starting one
)

$ErrorActionPreference = 'Stop'

# --- Stop ---------------------------------------------------------------------
# -Stop (what Stop SRRVRR.bat runs) ends whichever SRRVRR is running, the live
# SRRVRR.ps1 or "SRRVRR - test.ps1", and closes its Start SRRVRR window. Windows
# hides an administrator process's command line from programs that aren't, so when
# nothing is found without administrator, this asks for it and looks again. Ending
# the process skips SRRVRR's own cleanup, so this also stops its network-event
# session (the next start would clear it anyway).
if ($Stop) {
    $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" | Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)-File\s+"?[^"]*\bSRRVRR( - test)?\.ps1"?' -and $_.CommandLine -notmatch '(?i)\s-Stop\b'
    })
    if (-not $running -and -not $elevated) {
        Write-Host 'Looking for an SRRVRR started as administrator; Windows will ask for administrator.'
        try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Stop" }
        catch { Write-Host 'Not stopped: the administrator prompt was declined.'; exit 1 }
        exit 0
    }
    if (-not $running) { Write-Host 'SRRVRR is not running.' }
    foreach ($p in $running) {
        $which = if ($p.CommandLine -match '(?i)SRRVRR - test\.ps1') { 'test version' } else { 'live version' }
        $window = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)" -ErrorAction SilentlyContinue
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            # The Start SRRVRR window would otherwise wait at "Press any key".
            if ($window -and $window.Name -eq 'cmd.exe' -and $window.CommandLine -match '(?i)Start SRRVRR.*\.bat') { Stop-Process -Id $window.ProcessId -Force -ErrorAction SilentlyContinue }
            Write-Host "Stopped the SRRVRR $which (process $($p.ProcessId))."
        } catch { Write-Host "Couldn't stop the SRRVRR $which (process $($p.ProcessId)): $($_.Exception.Message)" }
    }
    if ($running -and $elevated) { & logman.exe stop SRRVRRNet -ets *> $null }
    if (-not [Console]::IsOutputRedirected) { Start-Sleep -Seconds 4 }   # time to read the result before the window closes
    exit 0
}

# --- Startup steps ------------------------------------------------------------
# Each startup step prints its own numbered line, with anything it finds on the
# lines under it, so it's clear what the script is doing. A spinner on a
# background thread sits below the current step while it works. Messages go
# through Write-Status so they don't collide with the spinner line. The spinner
# is skipped when output goes to a file.
$startup = [hashtable]::Synchronized(@{
    Step   = 0
    Steps  = 8        # number of Set-Step calls below
    Active = -not [Console]::IsOutputRedirected
    Lock   = New-Object Object
    Width  = 70
})
if ($startup.Active) {
    try { $startup.Width = [Math]::Min(70, [Console]::WindowWidth - 1); [Console]::CursorVisible = $false } catch { }
    $startupSpinner = [powershell]::Create()
    [void]$startupSpinner.AddScript({
        param($s)
        $frames = '|', '\', '-', '/'; $i = 0
        while ($s.Active) {
            [System.Threading.Monitor]::Enter($s.Lock)
            try {
                if ($s.Active) {
                    [Console]::Write("`r" + "      $($frames[$i++ % 4])  working...".PadRight($s.Width))
                }
            } finally { [System.Threading.Monitor]::Exit($s.Lock) }
            Start-Sleep -Milliseconds 150
        }
    }).AddArgument($startup)
    [void]$startupSpinner.BeginInvoke()
}
function Write-Status([string]$message, [switch]$Warning, [switch]$Step) {
    [System.Threading.Monitor]::Enter($startup.Lock)
    try {
        if ($startup.Active) { [Console]::Write("`r" + (' ' * $startup.Width) + "`r") }   # clear the spinner line
        if ($Warning) { Write-Warning $message }
        elseif ($Step) { Write-Host $message }
        else { Write-Host "      $message" }   # details sit under their step
    } finally { [System.Threading.Monitor]::Exit($startup.Lock) }
}
function Set-Step([string]$label) {
    $startup.Step++
    Write-Status -Step "[$($startup.Step)/$($startup.Steps)] $label"
}
# Runs Windows commands in their own PowerShell pipeline so that any progress
# PowerShell reports while doing them (e.g. "Preparing modules for first use")
# is printed as plain lines under the current step, instead of a progress box.
# Returns the commands' output; errors come back as normal errors.
function Invoke-Reported([scriptblock]$Script, [hashtable]$Arguments = @{}) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script.ToString()).AddParameters($Arguments)
    $handle = $ps.BeginInvoke()
    $seen = 0; $last = ''
    while (-not $handle.IsCompleted -or $seen -lt $ps.Streams.Progress.Count) {
        while ($seen -lt $ps.Streams.Progress.Count) {
            $p = $ps.Streams.Progress[$seen++]
            $status = "$($p.StatusDescription)".Trim()
            $text = "PowerShell: $($p.Activity.Trim())" + $(if ($status -and $status -ne $p.Activity.Trim()) { " - $status" } else { '' })
            if ($p.RecordType -ne 'Completed' -and $text -ne $last) { Write-Status $text; $last = $text }
        }
        Start-Sleep -Milliseconds 50
    }
    try { $ps.EndInvoke($handle) }
    catch { if ($_.Exception.InnerException) { throw $_.Exception.InnerException } else { throw } }
    finally { $ps.Dispose() }
}
function Stop-StartupSpinner {
    [System.Threading.Monitor]::Enter($startup.Lock)
    try {
        if ($startup.Active) { $startup.Active = $false; [Console]::Write("`r" + (' ' * $startup.Width) + "`r") }
    } finally { [System.Threading.Monitor]::Exit($startup.Lock) }
}
# Any error that stops the script: clear the spinner and show one plain message
# instead of PowerShell's error block.
trap {
    Stop-StartupSpinner
    try { [Console]::CursorVisible = $true } catch { }
    Write-Host ''
    Write-Host "SRRVRR stopped: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# --- Settings -----------------------------------------------------------------
Set-Step 'Reading settings'
# Defaults, replaced by anything set in SRRVRR.config.psd1. That file is
# not part of the code (see .gitignore), so updates never overwrite it.
$settings = @{
    Port              = 8099
    FirewallScope     = 'LocalSubnet'
    FirewallAddresses = @()
    AllowPublicAddresses = $false
    PreferredGpu      = ''
    Processes         = @{}
    ValheimPort       = 2456
}
# Settings from older versions, now handled automatically.
$retired = @{
    ListenAddress = 'the monitor always listens on this machine''s own addresses'
    OpenFirewall  = 'the firewall rule is always set up, since other PCs need it'
    GpuFallback   = 'without a PreferredGpu, the GPU with the most video memory is used'
}
$configPath = Join-Path $PSScriptRoot 'SRRVRR.config.psd1'
# Before the rename to SRRVRR the settings file was SystemMonitor.config.psd1; still read it if that's all there is.
$legacyConfig = Join-Path $PSScriptRoot 'SystemMonitor.config.psd1'
if (-not (Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $legacyConfig)) {
    $configPath = $legacyConfig
    Write-Status 'Note: using the old settings file name SystemMonitor.config.psd1; rename it to SRRVRR.config.psd1.'
}
if (Test-Path -LiteralPath $configPath) {
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    foreach ($k in $config.Keys) {
        if ($settings.ContainsKey($k)) { $settings[$k] = $config[$k] }
        elseif ($retired.ContainsKey($k)) { Write-Status "Note: setting '$k' is no longer used ($($retired[$k])); you can delete it from the config." }
        else { Write-Status -Warning "Unknown setting '$k' in $configPath (ignored)." }
    }
    Write-Status "Settings loaded from $configPath"
} else {
    Write-Status 'No SRRVRR.config.psd1 found, using default settings. Copy SRRVRR.config.example.psd1 to SRRVRR.config.psd1 to change them.'
}
if ($PSBoundParameters.ContainsKey('Port')) { $settings.Port = $Port }

if ($settings.ValheimPort -isnot [int] -or $settings.ValheimPort -lt 1 -or $settings.ValheimPort -gt 65534) {
    throw "ValheimPort must be the Valheim server's game port, a number from 1 to 65534 (default 2456)."
}
$scopes = 'LocalSubnet', 'Allowlist', 'Blocklist'
if ($settings.FirewallScope -notin $scopes) { throw "FirewallScope must be one of: $($scopes -join ', ')" }
if ($settings.FirewallScope -in 'Allowlist', 'Blocklist' -and -not $settings.FirewallAddresses) {
    throw "FirewallScope '$($settings.FirewallScope)' needs at least one address in FirewallAddresses."
}

# The page is meant for local networks, so firewall addresses must be private:
# 10.x, 172.16-31.x, 192.168.x, 169.254.x, 127.x, or IPv6 fe80::/10 and fc00::/7.
# The one exception: with AllowPublicAddresses, an Allowlist may also name
# single public IPs, at the user's own risk (see the README's security warning).
function Test-PrivateAddress([string]$entry) {
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
    if ($entry -match '^(.+)/(\d+)$') { return Test-Ip $matches[1] ([int]$matches[2]) }
    if ($entry -match '^(.+)-(.+)$') { return (Test-Ip $matches[1] 128) -and (Test-Ip $matches[2] 128) }
    Test-Ip $entry 128
}
# One specific address, written out in full: no ranges, subnets or "any" addresses.
function Test-SingleAddress([string]$entry) {
    $ip = $null
    if ($entry -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and $entry -notmatch ':') { return $false }
    if (-not [System.Net.IPAddress]::TryParse($entry, [ref]$ip)) { return $false }
    -not ($ip.Equals([System.Net.IPAddress]::Any) -or $ip.Equals([System.Net.IPAddress]::IPv6Any) -or $ip.Equals([System.Net.IPAddress]::Broadcast))
}
$public = @($settings.FirewallAddresses | Where-Object { -not (Test-PrivateAddress $_) })
if ($settings.FirewallScope -ne 'LocalSubnet' -and $public) {
    if ($settings.FirewallScope -ne 'Allowlist' -or -not $settings.AllowPublicAddresses) {
        $hint = if ($settings.FirewallScope -eq 'Allowlist') { ' To let specific public IPs in AT YOUR OWN RISK, set AllowPublicAddresses = $true (read the README security warning first).' } else { '' }
        throw "FirewallAddresses must be private (local network) addresses. Not allowed: $($public -join ', ').$hint"
    }
    $wide = @($public | Where-Object { -not (Test-SingleAddress $_) })
    if ($wide) { throw "Public addresses must be single IPs, not ranges, subnets or 'any' addresses. Not allowed: $($wide -join ', ')" }
    Write-Status -Warning ("SECURITY: AllowPublicAddresses is on. The firewall will let these INTERNET addresses open the page, " +
        "which has no password and no encryption: $($public -join ', '). You accept this risk; see the README security warning.")
}

# --- Processes shown in the table under the graphs ----------------------------
# name:  label on the page, and the switch name under Processes in the config
# main:  process that must be running for the row to show as online
# match: every process counted toward the row (wildcards allowed)
# icon:  logo shown before the name (a .plogo-<icon> style in the page); optional
$services = @(
    @{ name = 'Valheim'; main = 'valheim_server';    match = 'valheim_server'; icon = 'valheim' }
    @{ name = 'Plex';    main = 'Plex Media Server'; match = 'Plex*';          icon = 'plex' }   # includes Plex Transcoder etc.
) | Where-Object { $settings.Processes[$_.name] -ne $false }
$services = @($services)

# --- Which counters exist on this machine ------------------------------------
Set-Step 'Checking Windows performance counters'
$cat = [System.Diagnostics.PerformanceCounterCategory]
if ($cat::Exists('Processor Information') -and $cat::CounterExists('% Processor Utility', 'Processor Information')) {
    $cpuCounter = 'Processor Information', '% Processor Utility'   # same number Task Manager shows
} else {
    $cpuCounter = 'Processor', '% Processor Time'
}
$categories = @($cpuCounter[0], 'Memory', 'Network Interface')
$hasGpu = $cat::Exists('GPU Engine')
if ($hasGpu) { $categories += 'GPU Engine' }
if ($cat::Exists('GPU Adapter Memory')) { $categories += 'GPU Adapter Memory' }
if ($cat::CounterExists('Disk Read Bytes/sec', 'LogicalDisk')) { $categories += 'LogicalDisk' }   # per-drive read/write speed
if ($cat::CounterExists('Working Set - Private', 'Process')) { $categories += 'Process' }   # per-process memory, as Task Manager counts it

Set-Step 'Finding the processor, memory and graphics card'
# Processor: the name Windows reports, without the trademark marks and clock speed
# ("13th Gen Intel(R) Core(TM) i7-13700K" -> "Intel Core i7-13700K"), and its maker for the logo.
$cpuInfo = @(Get-CimInstance Win32_Processor)
$cpuName = ([string]$cpuInfo[0].Name) -replace '\((R|TM|C)\)', '' -replace '\b\d+(st|nd|rd|th) Gen\s+', '' -replace '\s+@.*$', '' -replace '\s+\d+-Core Processor', '' -replace '\s+(CPU|Processor)\b', '' -replace '\s+with Radeon.*$', '' -replace '\s+', ' '
$cpuName = $cpuName.Trim()
if ($cpuInfo.Count -gt 1) { $cpuName = "$($cpuInfo.Count) x $cpuName" }   # more than one socket
$cpuVendor = switch -Wildcard ([string]$cpuInfo[0].Manufacturer) { '*Intel*' { 'intel' } '*AMD*' { 'amd' } default { '' } }
Write-Status $cpuName

# Memory: who made each stick, and its type. Windows reports the maker as a name
# ("G Skill Intl"), as a raw JEDEC ID code (e.g. "04CD": continuation byte, then the
# maker's ID byte, in either order), or not at all; the part number's prefix is the
# fallback. icon picks the logo; Crucial is Micron's brand and uses its logo.
$ramMakers = @(
    @{ label = 'Samsung';  icon = 'samsung';  name = 'samsung';         jedec = '0-CE'; part = '^M[34]\d\d' }
    @{ label = 'SK hynix'; icon = 'skhynix';  name = 'hynix';           jedec = '0-AD'; part = '^HM[ACT]' }
    @{ label = 'Micron';   icon = 'micron';   name = 'micron';          jedec = '0-2C'; part = '^MT[ACF]' }
    @{ label = 'Crucial';  icon = 'micron';   name = 'crucial';         jedec = '5-9B'; part = '^(CT|BL)\d' }
    @{ label = 'Kingston'; icon = 'kingston'; name = 'kingston';        jedec = '1-98'; part = '^(KF|KVR|KHX|KCP|9905)' }
    @{ label = 'Corsair';  icon = 'corsair';  name = 'corsair';         jedec = '2-9E'; part = '^CM[A-Z]' }
    @{ label = 'G.Skill';  icon = 'gskill';   name = 'g\.?\s*skill';    jedec = '4-CD'; part = '^F[345]-' }
    @{ label = 'ADATA';    icon = 'adata';    name = 'a-?data|xpg';     jedec = '4-CB'; part = '^A[DX][45]' }
)
function Get-RamMaker([string]$maker, [string]$part) {
    $maker = $maker.Trim(); $part = $part.Trim()
    $codes = @()
    if ($maker -match '^([0-9A-Fa-f]{2})([0-9A-Fa-f]{2})') {
        $a = [Convert]::ToInt32($matches[1], 16); $b = [Convert]::ToInt32($matches[2], 16)
        $codes = ('{0}-{1:X2}' -f ($a -band 0x7F), $b), ('{0}-{1:X2}' -f ($b -band 0x7F), $a)   # top bit is parity
    }
    foreach ($m in $ramMakers) { if ($maker -match $m.name -or $codes -contains $m.jedec) { return $m } }
    foreach ($m in $ramMakers) { if ($part -match $m.part) { return $m } }
    $plain = if ($maker -and $maker -notmatch '^(unknown|undefined|[0-9A-Fa-f]{4,})$') { $maker } else { '' }
    @{ label = $plain; icon = '' }
}
$ramTypes = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$memSticks = @(foreach ($m in Get-CimInstance Win32_PhysicalMemory) {
    $maker = Get-RamMaker ([string]$m.Manufacturer) ([string]$m.PartNumber)
    [pscustomobject]@{
        slot  = ([string]$m.DeviceLocator).Trim()
        maker = $maker.label
        icon  = $maker.icon
        type  = $ramTypes[[int]$m.SMBIOSMemoryType]
        part  = ([string]$m.PartNumber).Trim()
        size  = [double]$m.Capacity
        mts   = [int]$(if ($m.ConfiguredClockSpeed) { $m.ConfiguredClockSpeed } else { $m.Speed })   # speed it runs at now
    }
})
# One label for the tile: "G.Skill DDR5", or "Mixed" when the sticks come from different makers.
$makers = @($memSticks | ForEach-Object maker | Where-Object { $_ } | Select-Object -Unique)
$types = @($memSticks | ForEach-Object type | Where-Object { $_ } | Select-Object -Unique)
$memLabel = ((@($(if ($makers.Count -eq 1) { $makers[0] } elseif ($makers.Count -gt 1) { 'Mixed' })) + @($(if ($types.Count -eq 1) { $types[0] }))) | Where-Object { $_ }) -join ' '
$icons = @($memSticks | ForEach-Object icon | Select-Object -Unique)
$memVendor = if ($icons.Count -eq 1) { $icons[0] } else { '' }
if ($memSticks) { Write-Status ("{0} {1} {2} {3}, {4:0} GB" -f $(if ($memLabel) { $memLabel } else { 'Memory' }), [char]0x00B7, $memSticks.Count, $(if ($memSticks.Count -eq 1) { 'stick' } else { 'sticks' }), (($memSticks | Measure-Object size -Sum).Sum / 1GB)) }

# Windows lists each graphics card under this registry key, with the name dxdiag
# shows, its vendor, and the same ID (LUID) the GPU counters use, which lets us
# pick out one card.
$gpus = @{}   # luid -> card
if ($hasGpu) {
    $live = (New-Object System.Diagnostics.PerformanceCounterCategory 'GPU Adapter Memory').GetInstanceNames()
    foreach ($key in Get-ChildItem HKLM:\SOFTWARE\Microsoft\DirectX -ErrorAction SilentlyContinue) {
        $adapter = Get-ItemProperty $key.PSPath
        if (-not $adapter.Description -or $null -eq $adapter.AdapterLuid) { continue }
        if ($adapter.VendorId -eq 0x1414) { continue }   # Microsoft Basic Render Driver (software, not a GPU)
        $l = [int64]$adapter.AdapterLuid
        $luid = '0x{0:x8}_0x{1:x8}' -f ($l -shr 32), ($l -band 4294967295)
        if (-not ($live | Where-Object { $_ -like "luid_${luid}_*" })) { continue }   # not present right now
        $vendor = switch ([int]$adapter.VendorId) { 0x10DE { 'nvidia' } 0x1002 { 'amd' } 0x1022 { 'amd' } 0x8086 { 'intel' } default { '' } }
        $gpus[$luid] = [pscustomobject]@{ Name = $adapter.Description.Trim(); Luid = $luid; Vendor = $vendor; Dedicated = [int64]$adapter.DedicatedVideoMemory }
    }
}
# PreferredGpu is the card's exact name; otherwise (or if it isn't found) use the
# GPU with the most video memory, which is the graphics card rather than built-in graphics.
$gpu = $null; $gpuNote = $null
$byMemory = @($gpus.Values | Sort-Object Dedicated -Descending)
if ($settings.PreferredGpu) {
    $gpu = $byMemory | Where-Object { $_.Name -eq $settings.PreferredGpu.Trim() } | Select-Object -First 1
    if (-not $gpu) {
        $gpuNote = "$($settings.PreferredGpu) not found"
        $names = if ($byMemory) { ($byMemory | ForEach-Object { "'$($_.Name)'" }) -join ', ' } else { 'none' }
        Write-Status -Warning "No GPU named '$($settings.PreferredGpu)'. GPUs on this machine: $names. Using the one with the most video memory."
    }
}
if (-not $gpu -and $byMemory) { $gpu = $byMemory[0] }
if ($gpu) {
    # Just the card and its size, as Windows reports them, e.g. "NVIDIA T600 (dot) 4 GB".
    $gb = $gpu.Dedicated / 1GB
    $size = if ($gb -ge 2) { ' {0} {1:0} GB' -f [char]0x00B7, $gb } elseif ($gb -gt 0) { ' {0} {1:0.#} GB' -f [char]0x00B7, $gb } else { '' }
    Write-Status "$($gpu.Name)$size"
}
$gpuLuid = if ($gpu) { $gpu.Luid } else { $null }
$gpuLabel = if ($gpu) { $gpu.Name } else { $null }
$gpuVendor = if ($gpu) { $gpu.Vendor } else { '' }
# GPU temperature comes from nvidia-smi, the command-line tool NVIDIA's driver
# installs. AMD and Intel have no built-in equivalent, so their cards show none.
$smiPath = $null
if ($gpuVendor -eq 'nvidia') {
    $smiPath = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $smiPath -and (Test-Path "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { $smiPath = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe" }
    Write-Status $(if ($smiPath) { "Temperature from $smiPath" } else { 'No nvidia-smi found, so no GPU temperature.' })
}

$totalRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
# Windows' start time, read once; uptime is worked out from it on every request.
$bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$state = [hashtable]::Synchronized(@{
    ready = $false
    cores = [int]$env:NUMBER_OF_PROCESSORS
    memTotal = $totalRam
    hasGpu = $hasGpu
    gpuLabel = $gpuLabel
    gpuNote = $gpuNote
    gpuVendor = $gpuVendor
    cpuName = $cpuName
    cpuVendor = $cpuVendor
    memLabel = $memLabel
    memVendor = $memVendor
    memSticks = $memSticks
})

# --- Per-process network ------------------------------------------------------
Set-Step 'Preparing per-program network tracking (Windows network events)'
# Windows has no per-process network counter, so this listens to the kernel's
# network events (the same source Resource Monitor uses) and adds up bytes per
# process ID. Needs administrator.
Write-Status 'Compiling the network event reader (C# code built into this script)'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class ProcessNetTrace {
    const string SessionName = "SRRVRRNet";
    const string LegacySessionName = "SystemMonitorNet";   // name used before the rename to SRRVRR
    static readonly Guid KernelNetwork = new Guid("7DD42A49-5329-4832-8DFD-43D979153A88");

    delegate void EventRecordCallback(IntPtr record);
    static EventRecordCallback callback;   // must stay referenced while the trace runs
    static Dictionary<int, long[]> totals = new Dictionary<int, long[]>();   // pid -> [sent, received]
    static readonly object gate = new object();
    public static string Error;
    public static long EventsSeen;           // every event delivered, for troubleshooting
    public static int TraceResult = -1;      // ProcessTrace's return code once it stops

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int StartTraceW(out ulong handle, string name, IntPtr properties);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int ControlTraceW(ulong handle, string name, IntPtr properties, uint code);
    [DllImport("advapi32.dll")]
    static extern int EnableTraceEx2(ulong handle, ref Guid provider, uint controlCode, byte level,
        ulong matchAny, ulong matchAll, uint timeout, IntPtr parameters);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern ulong OpenTraceW(IntPtr logfile);
    [DllImport("advapi32.dll")]
    static extern int ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);

    static IntPtr Zeroed(int size) {
        IntPtr p = Marshal.AllocHGlobal(size);
        for (int i = 0; i < size; i++) Marshal.WriteByte(p, i, 0);
        return p;
    }

    // EVENT_TRACE_PROPERTIES (120 bytes on x64) followed by room for the session name.
    static IntPtr NewProperties() {
        int size = 120 + 1024 * 2;
        IntPtr p = Zeroed(size);
        Marshal.WriteInt32(p, 0, size);          // Wnode.BufferSize
        Marshal.WriteInt32(p, 40, 1);            // Wnode.ClientContext: QPC timestamps
        Marshal.WriteInt32(p, 44, 0x00020000);   // Wnode.Flags: WNODE_FLAG_TRACED_GUID
        Marshal.WriteInt32(p, 48, 64);           // BufferSize (KB)
        Marshal.WriteInt32(p, 52, 16);           // MinimumBuffers
        Marshal.WriteInt32(p, 56, 128);          // MaximumBuffers: room for bursts without dropping events
        Marshal.WriteInt32(p, 64, 0x100);        // LogFileMode: EVENT_TRACE_REAL_TIME_MODE
        Marshal.WriteInt32(p, 68, 1);            // FlushTimer (seconds)
        Marshal.WriteInt32(p, 116, 120);         // LoggerNameOffset
        return p;
    }

    public static void Stop() { StopSession(SessionName); }

    static void StopSession(string name) {
        IntPtr p = NewProperties();
        ControlTraceW(0, name, p, 1);            // EVENT_TRACE_CONTROL_STOP
        Marshal.FreeHGlobal(p);
    }

    public static bool Start() {
        if (IntPtr.Size != 8) { Error = "needs 64-bit PowerShell"; return false; }
        Stop();                                  // clear a session left behind by an earlier run
        StopSession(LegacySessionName);
        ulong session;
        IntPtr props = NewProperties();
        int rc = StartTraceW(out session, SessionName, props);
        Marshal.FreeHGlobal(props);
        if (rc != 0) { Error = rc == 5 ? "needs administrator" : "StartTrace error " + rc; return false; }

        Guid provider = KernelNetwork;
        rc = EnableTraceEx2(session, ref provider, 1, 5, ulong.MaxValue, 0, 0, IntPtr.Zero);
        if (rc != 0) { Error = "EnableTrace error " + rc; Stop(); return false; }

        // EVENT_TRACE_LOGFILE (448 bytes on x64)
        IntPtr log = Zeroed(448);
        Marshal.WriteIntPtr(log, 8, Marshal.StringToHGlobalUni(SessionName));   // LoggerName
        Marshal.WriteInt32(log, 28, 0x100 | 0x10000000);   // ProcessTraceMode: real time, event records
        callback = OnEvent;
        Marshal.WriteIntPtr(log, 424, Marshal.GetFunctionPointerForDelegate(callback));   // EventRecordCallback
        ulong trace = OpenTraceW(log);
        if (trace == ulong.MaxValue) { Error = "OpenTrace error " + Marshal.GetLastWin32Error(); Stop(); return false; }

        Thread t = new Thread(() => { TraceResult = ProcessTrace(new ulong[] { trace }, 1, IntPtr.Zero, IntPtr.Zero); });
        t.IsBackground = true;
        t.Start();
        return true;
    }

    static void OnEvent(IntPtr record) {
        Interlocked.Increment(ref EventsSeen);
        bool sent;
        switch ((ushort)Marshal.ReadInt16(record, 40)) {   // EventHeader.EventDescriptor.Id
            case 10: case 26: case 42: case 58: sent = true; break;    // TCP/UDP send, IPv4/IPv6
            case 11: case 27: case 43: case 59: sent = false; break;   // TCP/UDP receive, IPv4/IPv6
            default: return;
        }
        if ((ushort)Marshal.ReadInt16(record, 86) < 8) return;   // UserDataLength
        IntPtr data = Marshal.ReadIntPtr(record, 96);             // UserData: PID, size, ...
        int pid = Marshal.ReadInt32(data, 0);
        long size = (uint)Marshal.ReadInt32(data, 4);
        lock (gate) {
            long[] t;
            if (!totals.TryGetValue(pid, out t)) { t = new long[2]; totals[pid] = t; }
            t[sent ? 0 : 1] += size;
        }
    }

    // Bytes per process since the previous call.
    public static Dictionary<int, long[]> Drain() {
        lock (gate) {
            Dictionary<int, long[]> d = totals;
            totals = new Dictionary<int, long[]>();
            return d;
        }
    }
}
'@
$netPerProcess = [ProcessNetTrace]::Start()
$state.netError = [ProcessNetTrace]::Error
Write-Status $(if ($netPerProcess) { 'Per-program network tracking is on.' } else { "Per-program network tracking is off ($([ProcessNetTrace]::Error))." })

# --- Background sampler: one reading per second -------------------------------
# Reads whole counter categories at once (much faster than Get-Counter when there
# are hundreds of GPU engine instances) and works out each value from the change
# since the previous read.
$sampler = {
    param($state, $categories, $cpuCounter, $totalRam, $services, $netPerProcess, $gpuLuid)
    $cats = @{}
    foreach ($n in $categories) { $cats[$n] = New-Object System.Diagnostics.PerformanceCounterCategory $n }
    $prev = $null
    $cpuTimes = @{}   # process id -> CPU seconds at the previous read
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $cores = [Environment]::ProcessorCount

    # @{ instance = value } for one counter, between the previous read and this one.
    function Get-Values($category, $counter) {
        $out = @{}
        if (-not $prev -or -not $cur.ContainsKey($category)) { return $out }
        $now = $cur[$category][$counter]; $old = $prev[$category][$counter]
        if (-not $now -or -not $old) { return $out }
        foreach ($inst in $now.Keys) {
            $o = $old[$inst]
            if ($o) { $out[$inst] = [System.Diagnostics.CounterSample]::Calculate($o.Sample, $now[$inst].Sample) }
        }
        $out
    }
    function Get-Sum($values) { $t = 0.0; foreach ($v in $values.Values) { $t += $v }; $t }

    while ($true) {
        $started = [DateTime]::UtcNow
        try {
            $cur = @{}
            foreach ($n in $cats.Keys) { $cur[$n] = $cats[$n].ReadCategory() }
            $elapsed = $clock.Elapsed.TotalSeconds
            $clock.Restart()

            if ($prev) {
                $cpu = 0
                $cpuValues = Get-Values $cpuCounter[0] $cpuCounter[1]
                foreach ($k in $cpuValues.Keys) { if ($k -eq '_Total') { $cpu = $cpuValues[$k] } }

                # Like Task Manager: add up every process on each engine, then report the busiest engine.
                $engines = @{}
                $gpuByProc = @{}   # process id -> @{ engine = utilization }
                $util = Get-Values 'GPU Engine' 'Utilization Percentage'
                foreach ($k in $util.Keys) {
                    if ($k -match 'pid_(\d+)_luid_(\w+?_\w+?)_phys_(\d+)_eng_(\d+)_engtype_(.*)$') {
                        if ($gpuLuid -and $matches[2] -ne $gpuLuid) { continue }   # another GPU
                        $key = "$($matches[2])|$($matches[3])|$($matches[4])"
                        if (-not $engines.ContainsKey($key)) { $engines[$key] = @{ v = 0.0; t = $matches[5] } }
                        $engines[$key].v += $util[$k]
                        $procId = [int]$matches[1]
                        if (-not $gpuByProc.ContainsKey($procId)) { $gpuByProc[$procId] = @{} }
                        $gpuByProc[$procId][$key] += $util[$k]
                    }
                }
                $gpu = 0; $gpuEngine = ''
                foreach ($e in $engines.Values) { if ($e.v -gt $gpu) { $gpu = $e.v; $gpuEngine = $e.t } }

                # Per-process rows: CPU and GPU the way Task Manager counts them, memory as a share of RAM.
                $procs = Get-Process
                $net = if ($netPerProcess) { [ProcessNetTrace]::Drain() } else { $null }
                $privateMem = @{}   # process id -> private working set
                if ($cur.ContainsKey('Process')) {
                    $ids = $cur['Process']['ID Process']; $ws = $cur['Process']['Working Set - Private']
                    foreach ($k in $ws.Keys) { $i = $ids[$k]; if ($i) { $privateMem[[int]$i.RawValue] = $ws[$k].RawValue } }
                }
                $nextCpuTimes = @{}
                $rows = @()
                foreach ($svc in $services) {
                    $group = @($procs | Where-Object { $_.ProcessName -like $svc.match })
                    if (-not ($group | Where-Object { $_.ProcessName -eq $svc.main })) {
                        $rows += @{ name = $svc.name; icon = $svc.icon; online = $false }
                        continue
                    }
                    $cpuSec = 0.0; $mem = 0; $sent = 0; $recv = 0; $gpuEngines = @{}
                    foreach ($p in $group) {
                        $mem += if ($privateMem.ContainsKey($p.Id)) { $privateMem[$p.Id] } else { $p.WorkingSet64 }
                        try {
                            $t = $p.TotalProcessorTime.TotalSeconds
                            if ($cpuTimes.ContainsKey($p.Id)) { $cpuSec += $t - $cpuTimes[$p.Id] }
                            $nextCpuTimes[$p.Id] = $t
                        } catch { }   # process exited or is not readable
                        if ($gpuByProc.ContainsKey($p.Id)) {
                            foreach ($e in $gpuByProc[$p.Id].Keys) { $gpuEngines[$e] += $gpuByProc[$p.Id][$e] }
                        }
                        $bytes = $null
                        if ($net -and $net.TryGetValue($p.Id, [ref]$bytes)) { $sent += $bytes[0]; $recv += $bytes[1] }
                    }
                    $procGpu = 0
                    foreach ($v in $gpuEngines.Values) { if ($v -gt $procGpu) { $procGpu = $v } }
                    $rows += @{
                        name   = $svc.name
                        icon   = $svc.icon
                        online = $true
                        cpu    = [math]::Round([math]::Min(100, 100 * $cpuSec / ($elapsed * $cores)), 1)
                        # The same CPU time in whole cores (1.0 = one core flat out); shows when a
                        # mostly single-threaded server like Valheim is maxing out its main thread.
                        coresUsed = [math]::Round($cpuSec / $elapsed, 1)
                        mem    = [math]::Round(100 * $mem / $totalRam, 1)
                        gpu    = [math]::Round([math]::Min(100, $procGpu), 1)
                        tx     = if ($net) { [math]::Round($sent / $elapsed) } else { $null }
                        rx     = if ($net) { [math]::Round($recv / $elapsed) } else { $null }
                    }
                }
                $cpuTimes = $nextCpuTimes
                $state.services = $rows

                $state.cpu = [math]::Round([math]::Min(100, $cpu), 1)
                $state.memUsed = $totalRam - (Get-Sum (Get-Values 'Memory' 'Available Bytes'))
                $state.rx = [math]::Round((Get-Sum (Get-Values 'Network Interface' 'Bytes Received/sec')))
                $state.tx = [math]::Round((Get-Sum (Get-Values 'Network Interface' 'Bytes Sent/sec')))
                $state.gpu = [math]::Round([math]::Min(100, $gpu), 1)
                $state.gpuEngine = $gpuEngine
                $gpuMem = Get-Values 'GPU Adapter Memory' 'Dedicated Usage'
                $state.gpuMem = 0
                foreach ($k in $gpuMem.Keys) { if (-not $gpuLuid -or $k -like "luid_${gpuLuid}_*") { $state.gpuMem += $gpuMem[$k] } }
                # Read/write speed per drive letter (the LogicalDisk counters' "C:", "D:" ... instances).
                $diskIO = @{}
                $reads = Get-Values 'LogicalDisk' 'Disk Read Bytes/sec'; $writes = Get-Values 'LogicalDisk' 'Disk Write Bytes/sec'
                foreach ($k in $reads.Keys) {
                    if ($k -match '^[A-Za-z]:$') { $diskIO[$k.ToUpper()] = @{ r = [math]::Round($reads[$k]); w = [math]::Round($writes[$k]) } }
                }
                $state.diskIO = $diskIO
                $state.ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                $state.error = $null
                $state.ready = $true
            }
            $prev = $cur
        } catch {
            $state.error = $_.Exception.Message
        }
        $wait = 1000 - ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}

Set-Step 'Starting the background samplers'
$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void]$worker.AddScript($sampler).AddArgument($state).AddArgument($categories).AddArgument($cpuCounter).AddArgument($totalRam).AddArgument($services).AddArgument($netPerProcess).AddArgument($gpuLuid)
[void]$worker.BeginInvoke()
Write-Status 'Every second: CPU, memory, GPU, network and the Processes table'

# --- Slow checks --------------------------------------------------------------
# Things that change slowly and take a few hundred milliseconds to read (like
# disk health) run on their own background thread every few seconds, so they
# never stall the once-a-second graphs. The loop ticks every 5 seconds; each
# check runs on its own multiple of that.
$slowChecks = {
    param($state, $smiPath, $gpuName, $plexUrl, $valheimQueryPort, $sensorDir)

    # CPU and memory temperatures come from LibreHardwareMonitor's sensor library (set up by
    # Install-TemperatureSensors.ps1). CPU: the package temperature the processor reports for
    # itself (AMD calls it Tctl), else its hottest core. Memory: each stick's own sensor ("DIMM
    # #n"; DDR5 and some DDR4 sticks have one), hottest first. The other temperature readings
    # (sensor limits, distance to the maximum) are left out.
    function Read-Temperatures($computer) {
        $cpu = @(); $cores = @(); $sticks = @()
        foreach ($hw in $computer.Hardware) {
            $hw.Update()
            $temps = @($hw.Sensors | Where-Object { [string]$_.SensorType -eq 'Temperature' -and $null -ne $_.Value })
            switch ([string]$hw.HardwareType) {
                'Cpu' {
                    $package = @($temps | Where-Object { $_.Name -match 'Package|Tctl' })
                    if (-not $package) { $package = @($temps | Where-Object { $_.Name -match 'Tdie' }) }
                    $each = @($temps | Where-Object { $_.Name -match 'Core #\d+$|^Core \d+$|CCD\d+' })
                    $cpu += if ($package) { [double]$package[0].Value } elseif ($each) { ($each | Measure-Object Value -Maximum).Maximum }
                    $cores += $each | ForEach-Object { @{ name = $_.Name; t = [math]::Round([double]$_.Value) } }
                }
                'Memory' {
                    $sticks += $temps | Where-Object { $_.Name -match '^DIMM' } | ForEach-Object { @{ name = $_.Name; t = [math]::Round([double]$_.Value, 1) } }
                }
            }
        }
        @{
            cpuTemp  = if ($cpu) { [math]::Round(($cpu | Measure-Object -Maximum).Maximum) } else { $null }
            cpuTemps = $cores
            memTemp  = if ($sticks) { ($sticks | ForEach-Object { $_.t } | Measure-Object -Maximum).Maximum } else { $null }
            memTemps = @($sticks | Sort-Object { $_.t } -Descending)
        }
    }
    # Opening the library scans the hardware and takes a few seconds, so it happens here
    # rather than at startup. The C# part lets it find the files it needs in its own folder.
    $sensors = $null
    if ($sensorDir) {
        try {
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
public static class SrrvrrSensorLoader {
    static string dir;
    public static void Init(string folder) {
        if (dir != null) return;
        dir = folder;
        AppDomain.CurrentDomain.AssemblyResolve += (s, e) => {
            string path = Path.Combine(dir, new AssemblyName(e.Name).Name + ".dll");
            return File.Exists(path) ? Assembly.LoadFrom(path) : null;
        };
    }
}
'@
            [SrrvrrSensorLoader]::Init($sensorDir)
            [void][Reflection.Assembly]::LoadFrom((Join-Path $sensorDir 'LibreHardwareMonitorLib.dll'))
            $sensors = New-Object LibreHardwareMonitor.Hardware.Computer
            $sensors.IsCpuEnabled = $true
            $sensors.IsMemoryEnabled = $true
            $sensors.Open()
        } catch { $sensors = $null; $state.tempError = "the sensor library didn't start: $($_.Exception.Message)" }
    }

    # Plex keeps its sign-in token in the registry of the Windows account it runs
    # under. That account's registry is only loaded while it is signed in or Plex is
    # running, so the loop below keeps looking until it's found. The token is only
    # ever sent to Plex itself on this machine, never printed or shown on the page.
    function Find-PlexToken {
        $hives = @('HKCU:') + @(Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | ForEach-Object { "Registry::HKEY_USERS\$($_.PSChildName)" })
        foreach ($h in $hives) {
            try { $t = (Get-ItemProperty -LiteralPath "$h\Software\Plex, Inc.\Plex Media Server" -Name PlexOnlineToken -ErrorAction Stop).PlexOnlineToken } catch { $t = $null }
            if ($t) { return $t }
        }
        $null
    }

    # Valve's A2S server query over UDP, which Valheim answers on its game port + 1.
    # Sends one request and returns the reply bytes; when the server answers with a
    # challenge (0x41 + 4 bytes, an anti-spoofing step), repeats the request with
    # that challenge appended. $base is the request without any challenge.
    function Invoke-A2S([byte[]]$base, [byte[]]$challenge, [int]$port) {
        $udp = New-Object System.Net.Sockets.UdpClient
        try {
            $udp.Client.ReceiveTimeout = 1000
            $udp.Connect('127.0.0.1', $port)
            # (+ on two arrays gives a generic object[]; cast back to bytes for sending)
            $request = if ($challenge) { [byte[]]($base + $challenge) } else { $base }
            foreach ($attempt in 1, 2) {
                [void]$udp.Send($request, $request.Length)
                $from = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any, 0)
                $reply = $udp.Receive([ref]$from)
                if ($reply.Length -ge 9 -and $reply[4] -eq 0x41) { $request = [byte[]]($base + $reply[5..8]); continue }
                return $reply
            }
            throw 'no answer after the challenge'
        } finally { $udp.Close() }
    }
    # Reads a zero-terminated UTF-8 string starting at $pos (passed by reference).
    function Read-A2SString([byte[]]$b, [ref]$pos) {
        $start = $pos.Value
        while ($pos.Value -lt $b.Length -and $b[$pos.Value] -ne 0) { $pos.Value++ }
        $text = [Text.Encoding]::UTF8.GetString($b, $start, $pos.Value - $start)
        $pos.Value++
        $text
    }
    $activity = @{}   # process name -> what it's doing (players, streams); published as $state.activity
    $valheimAnswered = $false
    $plexToken = $null
    $ProgressPreference = 'SilentlyContinue'   # no window to show progress in; don't let records pile up in memory
    $tick = 0
    while ($true) {
        # GPU temperature, every 5 seconds: one line per NVIDIA card, "name, degrees C".
        if ($smiPath) {
            try {
                $lines = @(& $smiPath --query-gpu=name,temperature.gpu --format=csv,noheader,nounits 2>$null)
                $temp = $null
                foreach ($line in $lines) {
                    $name, $degrees = $line -split ',\s*', 2
                    if ($name.Trim() -eq $gpuName -or $lines.Count -eq 1) { $temp = [int]$degrees; break }
                }
                $state.gpuTemp = $temp
            } catch { $state.gpuTemp = $null }
        }
        # CPU and memory temperatures, every 5 seconds.
        if ($sensors) {
            try {
                $r = Read-Temperatures $sensors
                foreach ($k in $r.Keys) { $state[$k] = $r[$k] }
                $state.tempError = if ($null -eq $r.cpuTemp) { 'the processor reported no temperature' } else { $null }
            } catch { $state.cpuTemp = $null; $state.memTemp = $null; $state.tempError = "reading the sensors failed: $($_.Exception.Message)" }
        }
        # Drives, every 30 seconds: space per volume, health of the disk it's on.
        if ($tick % 6 -eq 0) {
            try {
                $diskOf = @{}   # drive letter -> disk number
                foreach ($part in Get-Partition -ErrorAction SilentlyContinue) {
                    if ($part.DriveLetter) { $diskOf[[string]$part.DriveLetter] = [int]$part.DiskNumber }
                }
                # Physical disks report SMART-based health; Get-Disk also covers
                # virtual disks such as Storage Spaces.
                $health = @{}   # disk number -> @{ name; health; bus; media }
                foreach ($d in Get-Disk -ErrorAction SilentlyContinue) { $health[[int]$d.Number] = @{ name = $d.FriendlyName; health = [string]$d.HealthStatus; bus = [string]$d.BusType; media = '' } }
                foreach ($d in Get-PhysicalDisk -ErrorAction SilentlyContinue) {
                    $n = 0
                    if ([int]::TryParse($d.DeviceId, [ref]$n)) { $health[$n] = @{ name = $d.FriendlyName; health = [string]$d.HealthStatus; bus = [string]$d.BusType; media = [string]$d.MediaType } }
                }
                # Windows doesn't report a drive's maximum speed, so use the typical ceiling
                # for its connection and media type (decimal MB/s, as drive makers quote them).
                function Get-DriveCeiling($bus, $media) {
                    if ($media -eq 'HDD')  { return @{ bytes = 200e6;  kind = 'hard drive' } }    # spinning disks top out near 200 MB/s
                    switch -Regex ($bus) {
                        '^NVMe$'          { return @{ bytes = 3500e6; kind = 'NVMe SSD' } }
                        '^(SATA|ATA|SAS)$' { return @{ bytes = 550e6; kind = 'SATA SSD' } }       # the SATA III link limit
                        '^USB$'           { return @{ bytes = 400e6;  kind = 'USB drive' } }
                    }
                    @{ bytes = 500e6; kind = 'drive' }                                            # unknown or virtual: a middle estimate
                }
                $drives = @()
                foreach ($v in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Sort-Object DeviceID) {
                    if ([double]$v.Size -lt 1GB) { continue }   # tiny system/metadata partitions aren't storage people use
                    $disk = $null
                    $letter = $v.DeviceID.TrimEnd(':')
                    if ($diskOf.ContainsKey($letter)) { $disk = $health[$diskOf[$letter]] }
                    $ceiling = if ($disk) { Get-DriveCeiling $disk.bus $disk.media } else { Get-DriveCeiling '' '' }
                    $drives += @{
                        ceiling = $ceiling.bytes
                        kind   = $ceiling.kind
                        letter = $v.DeviceID
                        label  = $v.VolumeName
                        size   = [double]$v.Size
                        free   = [double]$v.FreeSpace
                        disk   = if ($disk) { $disk.name } else { $null }
                        health = if ($disk) { $disk.health } else { $null }
                    }
                }
                $state.drives = $drives
                $state.drivesError = $null
            } catch { $state.drivesError = $_.Exception.Message }
        }
        # Pending Windows restart, every 60 seconds: Windows Update and the servicing
        # stack each leave a registry marker while an installed update waits for a restart.
        if ($tick % 12 -eq 0) {
            $reasons = @()
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows component servicing' }
            $state.restartPending = [bool]$reasons
            $state.restartReason = $reasons -join ', '
        }
        # Plex token, every 60 seconds until found (and right away at start).
        if ($plexUrl -and -not $plexToken -and $tick % 12 -eq 0) {
            $plexToken = Find-PlexToken
            if (-not $plexToken) { $activity.Plex = @{ error = 'no Plex token found yet (checking every minute)' }; $state.activity = $activity }
        }
        # Plex activity, every 10 seconds: who is watching and whether Plex has to
        # transcode (re-encode on the fly, which is what loads the GPU) or can play
        # the file directly. Plex's local API lists active sessions as XML.
        if ($tick % 2 -eq 0 -and $plexToken) {
            try {
                $xml = Invoke-RestMethod -Uri "$plexUrl/status/sessions" -Headers @{ 'X-Plex-Token' = $plexToken; Accept = 'application/xml' } -TimeoutSec 3 -UseBasicParsing
                if ($xml -is [string]) { $xml = [xml]$xml }
                $items = @()
                foreach ($s in @($xml.MediaContainer.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
                    $ts = $s.TranscodeSession
                    $transcoding = [bool]($ts -and ($ts.videoDecision -eq 'transcode' -or $ts.audioDecision -eq 'transcode'))
                    # A title can have several versions (e.g. 4K and 1080p); the one playing is marked selected.
                    $media = @($s.Media | Where-Object { $_.selected -eq '1' })[0]
                    if (-not $media) { $media = @($s.Media)[0] }
                    $items += @{
                        key         = if ($s.Session.id) { [string]$s.Session.id } else { [string]$s.sessionKey }   # tells streams apart
                        user        = [string]$s.User.title
                        title       = if ($s.grandparentTitle) { "$($s.grandparentTitle) - $($s.title)" } else { [string]$s.title }
                        transcoding = $transcoding
                        device      = [string]$s.Player.title     # e.g. "Living Room TV"
                        app         = [string]$s.Player.product   # e.g. "Plex for Roku"
                        # Direct play sends the file as is; direct stream only repackages it; transcode re-encodes it.
                        playback    = if ($transcoding) { 'transcode' } elseif ($ts) { 'direct stream' } else { 'direct play' }
                        source      = if ($media.videoResolution) { [string]$media.videoResolution } else { ([string]$media.audioCodec).ToUpper() }   # "1080", "4k"; music: "FLAC"
                        target      = if ($ts -and $ts.videoDecision -eq 'transcode') { [string]$ts.height } else { '' }   # transcoded height, e.g. "720"
                        hardware    = [bool]($ts -and $ts.transcodeHwEncoding)   # encoding on the GPU (e.g. NVENC) rather than the CPU
                        kbps        = [int]$s.Session.bandwidth
                    }
                }
                $activity.Plex = @{ streams = $items.Count; transcoding = @($items | Where-Object { $_.transcoding }).Count; items = $items }
            } catch { $activity.Plex = @{ error = "Plex didn't answer"; alert = $true } }
            $state.activity = $activity
        }
        # Valheim activity, every 10 seconds: players online (A2S_INFO), their names and
        # time connected (A2S_PLAYER), and how long the server takes to answer. The
        # server answers from its main game loop, so a slow or missing reply is a sign
        # that loop is bogged down. Per-player ping is not part of the query.
        if ($tick % 2 -eq 0 -and $valheimQueryPort) {
            try {
                $header = [byte[]](0xFF, 0xFF, 0xFF, 0xFF)
                $infoRequest = $header + [byte]0x54 + [Text.Encoding]::ASCII.GetBytes("Source Engine Query`0")
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $info = Invoke-A2S $infoRequest $null $valheimQueryPort
                $replyMs = [int]$timer.Elapsed.TotalMilliseconds
                if ($info[4] -ne 0x49) { throw 'unexpected reply' }
                # 0x49 reply: protocol byte, then name, map, folder, game strings, a 2-byte
                # app ID, then players, max players, bots (one byte each).
                $pos = 6
                foreach ($i in 1..4) { [void](Read-A2SString $info ([ref]$pos)) }
                $pos += 2
                $players = [int]$info[$pos]; $maxPlayers = [int]$info[$pos + 1]

                $names = @()
                try {
                    $list = Invoke-A2S ($header + [byte]0x55) ([byte[]](0xFF, 0xFF, 0xFF, 0xFF)) $valheimQueryPort
                    if ($list[4] -eq 0x44) {
                        # 0x44 reply: count, then per player: index, name, 4-byte score, 4-byte seconds connected.
                        $pos = 6
                        $count = [int]$list[5]
                        # (guard: in PowerShell 1..0 counts down instead of being empty)
                        if ($count -gt 0) { foreach ($i in 1..$count) {
                            $pos++
                            $n = Read-A2SString $list ([ref]$pos)
                            $pos += 4
                            $secs = [BitConverter]::ToSingle($list, $pos); $pos += 4
                            if ($n) { $names += @{ name = $n; minutes = [int]($secs / 60) } }
                        } }
                    }
                } catch { }   # names are a nice-to-have; the count above already worked
                $activity.Valheim = @{ players = $players; maxPlayers = $maxPlayers; replyMs = $replyMs; names = $names }
                $valheimAnswered = $true
            } catch {
                # Stopping after it used to answer is a real warning sign. Never answering usually
                # means the query is off (servers started with -public 0, or crossplay servers,
                # don't answer it), so say so quietly and name the fix.
                $activity.Valheim = if ($valheimAnswered) { @{ error = 'stopped answering the status query'; alert = $true } }
                                    else { @{ error = 'status query off; start the server with -public 1 (crossplay servers never answer)' } }
            }
            $state.activity = $activity
        }
        $tick++
        Start-Sleep -Seconds 5
    }
}
# Plex's sign-in token is looked up by the slow sampler (Find-PlexToken), so it is
# found even when Plex starts after SRRVRR.
$plexUrl = $null
if ($services | Where-Object { $_.name -eq 'Plex' }) { $plexUrl = 'http://127.0.0.1:32400' }

$valheimQueryPort = if ($services | Where-Object { $_.name -eq 'Valheim' }) { $settings.ValheimPort + 1 } else { $null }

$slowRunspace = [runspacefactory]::CreateRunspace()
$slowRunspace.Open()
$slowWorker = [powershell]::Create()
$slowWorker.Runspace = $slowRunspace
# CPU and memory temperatures need LibreHardwareMonitor's sensor library and its PawnIO
# driver (Install-TemperatureSensors.ps1 sets up both), and administrator. When one is
# missing, the page says so where the temperature would be.
$sensorDir = Join-Path $PSScriptRoot 'lib\LibreHardwareMonitor'
$tempError = $null
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not (Test-Path -LiteralPath (Join-Path $sensorDir 'LibreHardwareMonitorLib.dll'))) { $tempError = 'not set up; run Install Temperature Sensors.bat' }
elseif (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO')) { $tempError = 'the PawnIO driver is missing; run Install Temperature Sensors.bat' }
elseif (-not $elevated) { $tempError = 'needs administrator' }
if ($tempError) { $sensorDir = $null; $state.tempError = $tempError }

[void]$slowWorker.AddScript($slowChecks).AddArgument($state).AddArgument($smiPath).AddArgument($gpuLabel).AddArgument($plexUrl).AddArgument($valheimQueryPort).AddArgument($sensorDir)
if ($smiPath) { Write-Status 'Every 5 seconds: GPU temperature' }
Write-Status $(if ($sensorDir) { 'Every 5 seconds: CPU and memory temperatures (LibreHardwareMonitor)' } else { "No CPU or memory temperature: $tempError" })
if ($plexUrl) { Write-Status "Every 10 seconds: Plex streams and transcodes (using the token from Plex's own settings; until it's found, checked every minute)" }
if ($valheimQueryPort) { Write-Status "Every 10 seconds: Valheim players and response time (query port $valheimQueryPort)" }
[void]$slowWorker.BeginInvoke()
Write-Status 'Every 30 seconds: drive space and drive health'
Write-Status 'Every 60 seconds: whether Windows is waiting to restart for updates'

# --- Web page -----------------------------------------------------------------
$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SRRVRR</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--text:#1b1f24;--muted:#667080;--grid:rgba(0,0,0,.07);--border:#e2e5e9;
  --cpu:#1f7ae0;--mem:#8e44c9;--gpu:#139068;--rx:#d9661f;--tx:#c2185b;--bad:#d33;--warn:#b7791f;--ok:#139068}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--card:#1b1e23;--text:#e8eaed;--muted:#9aa3ad;--grid:rgba(255,255,255,.07);--border:#2a2f36;
  --cpu:#4c9bff;--mem:#b67cf0;--gpu:#3ccf98;--rx:#ff9a52;--tx:#f2669a;--bad:#ff6b6b;--warn:#f0b429;--ok:#3ccf98}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 system-ui,"Segoe UI",sans-serif}
header{display:flex;align-items:baseline;justify-content:space-between;gap:12px;max-width:1100px;margin:0 auto;padding:20px 24px 0}
h1{font-size:18px;margin:0;font-weight:600;display:inline}
#uptime{color:var(--muted);font-size:13px;margin-left:10px;font-variant-numeric:tabular-nums;white-space:nowrap;display:inline-block}
#restart{color:var(--warn);border:1px solid var(--warn);border-radius:999px;font-size:12px;font-weight:600;padding:1px 8px;margin-left:8px;white-space:nowrap}
#status{color:var(--muted);font-size:13px}
#status.bad{color:var(--bad)}
main{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;max-width:1100px;margin:0 auto;padding:16px 24px 24px}
@media (max-width:700px){header{padding:16px 16px 0}main{grid-template-columns:1fr;padding:12px 16px 16px}}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px 16px 12px;min-width:0}
.top{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.label{font-weight:600;font-size:22px;display:inline-flex;align-items:center;gap:8px}   /* ~85% of the 26px metric */
/* Tile icons: CPU, memory, network and generic GPU from Lucide (lucide.dev, ISC license); NVIDIA eye mark
   (nvidia.com), AMD arrow (amd.com) and Intel wordmark (Intel 2020 logo) are trademarks of their owners */
.ticon{height:1em;width:1em;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.ticon.brand{width:auto;fill:currentColor;stroke:none}
/* The GPU tile shows the logo of the chosen card's maker, or a plain GPU icon. */
#gpuIcon,#cpuIcon,#memIcon{display:inline-flex;align-items:center}
#gpuIcon svg,#cpuIcon .brand{display:none}
#cpuIcon[data-v="amd"] .v-amd,#cpuIcon[data-v="intel"] .v-intel{display:block} #cpuIcon[data-v="amd"] .v-generic,#cpuIcon[data-v="intel"] .v-generic{display:none}
#gpuIcon[data-v=""] .v-generic,#gpuIcon[data-v="nvidia"] .v-nvidia,#gpuIcon[data-v="amd"] .v-amd,#gpuIcon[data-v="intel"] .v-intel{display:block}
.value{font-size:26px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap}
.temp{font-size:16px;color:var(--muted);margin-right:10px}
.temp.warn{color:var(--warn)} .temp.hot{color:var(--bad)}
.sub{color:var(--muted);font-size:12.5px;min-height:18px;font-variant-numeric:tabular-nums}
canvas{display:block;width:100%;height:120px;margin-top:8px}
.key{display:inline-flex;align-items:center;gap:5px;margin-right:12px}
.key i{width:10px;height:3px;border-radius:2px;display:inline-block}
.wide{grid-column:1/-1}
.scroll{overflow-x:auto}
table{width:100%;min-width:440px;table-layout:fixed;border-collapse:collapse;margin-top:6px;font-variant-numeric:tabular-nums}
th,td{overflow:hidden;text-overflow:ellipsis}
th{color:var(--muted);font-weight:500;font-size:12.5px;text-align:right;padding:6px 10px;border-bottom:1px solid var(--border);white-space:nowrap}
td{text-align:right;padding:9px 10px;font-size:15px;white-space:nowrap}
tr+tr td{border-top:1px solid var(--border)}
th:first-child,td:first-child{text-align:left;padding-left:0;font-weight:600}
td.offline{text-align:left;color:var(--muted)}
.plogo{display:inline-block;width:1.15em;height:1.15em;vertical-align:-.2em;margin-right:7px;border-radius:4px;background:center/contain no-repeat}
/* Logos: Valheim emblem (valheimgame.com), Plex chevron (Plex Media Server web app) */
.plogo-valheim{background-image:url(data:image/png;base64,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)}
.plogo-plex{background-image:url(data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA3MiA3MiI+PGRlZnM+PHJhZGlhbEdyYWRpZW50IGlkPSJnIiBjeD0iLjYyIiBjeT0iLjU1IiByPSIuNjIiPjxzdG9wIG9mZnNldD0iMCIgc3RvcC1jb2xvcj0iI2Y5YmUyMCIvPjxzdG9wIG9mZnNldD0iMSIgc3RvcC1jb2xvcj0iI2NjN2MxOSIvPjwvcmFkaWFsR3JhZGllbnQ+PC9kZWZzPjxyZWN0IHdpZHRoPSI3MiIgaGVpZ2h0PSI3MiIgZmlsbD0iIzFmMWYxZiIvPjxwYXRoIHRyYW5zZm9ybT0idHJhbnNsYXRlKDcuOSA3LjkpIHNjYWxlKC43OCkiIGZpbGw9InVybCgjZykiIGQ9Ik0xNC4wMyAwIDM3LjA5IDM2IDE0LjAzIDcyaDIwLjg4TDU3Ljk3IDM2IDM0LjkxIDB6Ii8+PC9zdmc+)}
/* Memory makers' logos (see the README for sources), drawn in the text color through a mask so they match the theme */
.blogo{display:none;background:currentColor;-webkit-mask:var(--m) center/contain no-repeat;mask:var(--m) center/contain no-repeat}
#memIcon:not([data-v=""]) .v-generic{display:none} #memIcon:not([data-v=""]) .blogo{display:inline-block}
.blogo-samsung{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwIDEwLjE2NiAyNCAzLjY2OCIgcm9sZT0iaW1nIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxwYXRoIGQ9Ik0xOS44MTY2IDEwLjI4MDhsLjA0NTkgMi42OTM0aC0uMDIzbC0uNzc5My0yLjY5MzRoLTEuMjgzN3YzLjM5MjVoLjg0ODFsLS4wNDU4LTIuNzg1aC4wMjNsLjgzNjYgMi43ODVoMS4yMjY0di0zLjM5MjV6bS0xNi4xNDkgMGwtLjY0MTggMy40MjdoLjkyODRsLjQ2OTktMy4xMTc1aC4wMjI5bC40NTg1IDMuMTE3NGguOTE2OWwtLjYzMDQtMy40MjY5em01LjE4MDUgMGwtLjQyNCAyLjYxMzJoLS4wMjNsLS40MjQtMi42MTMySDYuNTc4OGwtLjA2ODggMy40MjdoLjg1OTZsLjAyMy0zLjA4MzJoLjAxMTRsLjU3MyAzLjA4MzFoLjg3MTFsLjU3MzEtMy4wODNoLjAyM2wuMDIyOCAzLjA4M2guODU5NmwtLjA4MDItMy40MjY5em0tNy4yNjY0IDIuNDUyN2MuMDM0My4wODAyLjAyMjkuMTk0OS4wMTE0LjI1MjItLjAyMjkuMTE0Ni0uMTAzMS4yMjkyLS4zMzI0LjIyOTItLjIxNzcgMC0uMzQzOC0uMTI2LS4zNDM4LS4zMDk1di0uMzMyM0gwdi4yNjM2YzAgLjc2NzkuNjA3NC45OTcxIDEuMjQ5My45OTcxLjYxODkgMCAxLjEzNDYtLjIxNzggMS4yMTQ5LS43Nzk0LjA0NTgtLjI5OC4wMTE0LS40OTI4IDAtLjU2MTYtLjE2MDUtLjcyMi0xLjQ2Ny0uOTI4My0xLjU1ODgtMS4zMjk1LS4wMTE0LS4wNjg4LS4wMTE0LS4xMzc1IDAtLjE4MzQuMDIzLS4xMTQ2LjEwMzItLjIyOTIuMzA5NS0uMjI5Mi4yMDYzIDAgLjMyMS4xMjYuMzIxLjMwOTV2LjIwNjNoLjg1OTV2LS4yNDA3YzAtLjc0NS0uNjc2Mi0uODU5Ni0xLjE1NzYtLjg1OTYtLjYwNzQgMC0xLjExMTcuMjA2My0xLjIwMzQuNzU2NC0uMDIzLjE0OS0uMDM0NC4yODY2LjAxMTQuNDU4NS4xMzc2LjcxMDYgMS4zNjQuOTE2OSAxLjUzNTggMS4zNTI0bTExLjE1MiAwYy4wMzQzLjA4MDMuMDIyOC4xODM0LjAxMTQuMjUyMi0uMDIzLjExNDYtLjEwMzIuMjI5Mi0uMzMyNC4yMjkyLS4yMTc4IDAtLjM0MzgtLjEyNi0uMzQzOC0uMzA5NXYtLjMzMjNoLS45MTd2LjI2MzZjMCAuNzU2NC41OTYuOTg1NyAxLjIzNzkuOTg1Ny42MTg5IDAgMS4xMjMyLS4yMDYzIDEuMjAzNC0uNzc5NC4wNDU5LS4yOTguMDExNS0uNDgxNCAwLS41NjE2LS4xMzc1LS43MTA2LTEuNDMyNy0uOTI4NC0xLjUyNDMtMS4zMTgtLjAxMTUtLjA2ODgtLjAxMTUtLjEzNzYgMC0uMTgzNS4wMjI5LS4xMTQ2LjEwMzEtLjIyOTIuMzA5NC0uMjI5Mi4xOTQ4IDAgLjMyMS4xMjYuMzIxLjMwOTV2LjIwNjNoLjg0OHYtLjI0MDdjMC0uNzQ1LS42NjQ3LS44NTk2LTEuMTQ2LS44NTk2LS42MDc1IDAtMS4xMDA0LjE5NDgtMS4xOTIuNzU2NC0uMDIzLjE0OS0uMDIzLjI4NjYuMDExNC40NTg1LjEzNzYuNzEwNiAxLjM0MS45MDU0IDEuNTEzIDEuMzUyNG0yLjg4ODIuNDU4NWMuMjQwNyAwIC4zMDk0LS4xNjA1LjMzMjMtLjI1MjIuMDExNS0uMDM0My4wMTE1LS4wOTE3LjAxMTUtLjEyNnYtMi41MzNoLjg3MXYyLjQ2NDJjMCAuMDY4OCAwIC4xOTQ4LS4wMTE0LjIyOTItLjA1NzMuNjQxOS0uNTYxNi44NDgyLTEuMTkyLjg0ODItLjYzMDMgMC0xLjEzNDYtLjIwNjMtMS4xOTItLjg0ODIgMC0uMDM0NC0uMDExNC0uMTYwNC0uMDExNC0uMjI5MnYtMi40NjQyaC44NzF2Mi41MzNjMCAuMDQ1OCAwIC4wOTE2LjAxMTUuMTI2IDAgLjA5MTcuMDY4OC4yNTIyLjMwOTUuMjUyMm03LjE1MTgtLjAzNDRjLjI1MjIgMCAuMzMyNC0uMTYwNS4zNTUzLS4yNTIyLjAxMTUtLjAzNDMuMDExNS0uMDkxNy4wMTE1LS4xMjZ2LS40OTI5aC0uMzU1M3YtLjUwNDNIMjR2LjkxN2MwIC4wNjg3IDAgLjExNDUtLjAxMTUuMjI5Mi0uMDU3My42MzAzLS41OTYuODQ4MS0xLjIwMzQuODQ4MS0uNjA3NSAwLTEuMTQ2MS0uMjE3OC0xLjIwMzQtLjg0ODEtLjAxMTUtLjExNDctLjAxMTUtLjE2MDUtLjAxMTUtLjIyOTN2LTEuNDQ0YzAtLjA1NzQuMDExNS0uMTcyLjAxMTUtLjIyOTMuMDgwMi0uNjQxOS41OTYtLjg0ODIgMS4yMDM0LS44NDgyczEuMTM0Ny4yMDYzIDEuMjAzNC44NDgyYy4wMTE1LjEwMzEuMDExNS4yMjkyLjAxMTUuMjI5MnYuMTE0NmgtLjg1OTZ2LS4xOTQ4czAtLjA4MDMtLjAxMTUtLjEyNjFjLS4wMTE0LS4wODAyLS4wODAyLS4yNTIxLS4zNDM4LS4yNTIxLS4yNTIxIDAtLjMyMS4xNjA0LS4zNDM4LjI1MjEtLjAxMTUuMDQ1OC0uMDExNS4xMDMyLS4wMTE1LjE2MDV2MS41NzAyYzAgLjA0NTggMCAuMDkxNi4wMTE1LjEyNiAwIC4wOTE3LjA5MTcuMjUyMi4zMzIzLjI1MjIiLz48L3N2Zz4=);height:0.7em;width:4.58em}
.blogo-skhynix{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwLjEzMiAwLjEzMiAyOC4xODggMTQuNzY0IiB4bWxuczpkYz0iaHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iIHhtbG5zOmNjPSJodHRwOi8vY3JlYXRpdmVjb21tb25zLm9yZy9ucyMiIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyIgeG1sbnM6c3ZnPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB4bWxuczpzb2RpcG9kaT0iaHR0cDovL3NvZGlwb2RpLnNvdXJjZWZvcmdlLm5ldC9EVEQvc29kaXBvZGktMC5kdGQiIHhtbG5zOmlua3NjYXBlPSJodHRwOi8vd3d3Lmlua3NjYXBlLm9yZy9uYW1lc3BhY2VzL2lua3NjYXBlIiA+PGRlZnMgPjxjbGlwUGF0aCBjbGlwUGF0aFVuaXRzPSJ1c2VyU3BhY2VPblVzZSI+PHBhdGggZD0iTSAwLDAgSCA2MjMuNjIyIFYgNzkzLjcwMSBIIDAgWiIgLz48L2NsaXBQYXRoPjxjbGlwUGF0aCBjbGlwUGF0aFVuaXRzPSJ1c2VyU3BhY2VPblVzZSI+PHBhdGggZD0iTSAwLDAgSCA2MjMuNjIyIFYgNzkzLjcwMSBIIDAgWiIgLz48L2NsaXBQYXRoPjwvZGVmcz48ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSgtMTcuNjU2MDM1LC0xMTUuNDg0NDMpIj48ZyB0cmFuc2Zvcm09InRyYW5zbGF0ZSgwLjEzMjI5MTM5LC0wLjEzMjI4NTA3KSI+PGcgc3R5bGU9ImZpbGw6I2UzMTgzNztmaWxsLW9wYWNpdHk6MSIgPjxwYXRoIHN0eWxlPSJmaWxsOiNlMzE4Mzc7ZmlsbC1vcGFjaXR5OjE7ZmlsbC1ydWxlOm5vbnplcm87c3Ryb2tlOm5vbmU7c3Ryb2tlLXdpZHRoOjAuMzUyNzc3NzgiIGQ9Im0gMjAuMTU2NTI4LDEyNS41MDgxNSBjIC0wLjQ3MjcyMiwtMC4yMjExOSAtMC44NjA3NzgsLTAuMzk5NyAtMC44NjA3NzgsLTAuNzYwNTkgMCwtMC4yNzYyMiAwLjIyMTE5MiwtMC40NzY5NSAwLjY1NzIyNSwtMC40NzY5NSAwLjE2MDUxNCwwIDAuMjkxNzQ3LDAuMDE5IDAuNDI3NTY3LDAuMDQzNyAwLjA3MDkxLDAuMDEyMyAwLjE0NjQwMywwLjAyMjYgMC4yMDg4NDQsMC4wMjI2IDAuMzgxMzUzLDAgMC41OTY1NDgsLTAuMjI3MTkgMC43Mzk3NzUsLTAuNjU4NjQgbCAwLjA1ODkxLC0wLjE3NjAzIGMgLTAuMDYxMDMsLTAuMDI0NyAtMC42ODM2ODMsLTAuMjk4NDUgLTEuNDk1NDI1LC0wLjI5ODQ1IC0xLjI5MTg3MiwwIC0xLjk3Mzc5MSwwLjgyODY3IC0xLjk3MzQzOSwxLjY4ODA0IDAsMC40MzM1NiAwLjEzNTgyLDAuNzQ3ODkgMC4zNDg1NDUsMC45OTU1NCAwLjI3Mzc1NSwwLjMxNzg1IDAuNjYzOTI4LDAuNTI1OTkgMS4wMjkwNTMsMC43MDQ0OSAwLjUzMjM0MSwwLjI2MTA2IDEuMDEyNDcyLDAuNDU0MDMgMS4wMTI0NzIsMC44NDEwMyAzLjUzZS00LDAuMzQzNiAtMC4zNTQ1NDIsMC41Mzg2OSAtMC44MjkwMjgsMC41Mzg2OSAtMC42NTAxNjksMCAtMS4yMTgxNDIsLTAuMzcxMTMgLTEuMjkwNDYxLC0wLjQxNTkzIGwgLTAuNTMzNzUzLDEuMDAwMTMgYyAwLjA5NDU1LDAuMDU0IDAuNzgyMTA4LDAuNDkwMDEgMS45MTM0NjcsMC40OTAwMSAxLjIwNTQ0MSwtNy4xZS00IDIuMTE4NDMsLTAuNjkxOCAyLjExODQzLC0xLjc1NTQzIDAsLTEuMDU3OTggLTAuODQ1OTYxLC0xLjQ1MDI3IC0xLjUzMTQwOCwtMS43ODIyMyIgLz48cGF0aCBzdHlsZT0iZmlsbDojZTMxODM3O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDI0Ljg3MTg2MSwxMjYuMDAxOTcgMi4xODY1MTcsLTIuNjgxMTEgaCAtMS41NTc4NjcgbCAtMS43NDQxMzMsMi4zMTM4NyBoIC0wLjAyNjExIHYgLTIuMzEzODcgaCAtMS4yODQ0NjQgbCA3LjA2ZS00LDUuNjc5NzIgaCAwLjA3NjIgYyAwLjU1NTI3MiwwIDEuMjE2MDI1LC0wLjI1NzE3IDEuMjE2MDI1LC0xLjE4NDI3IHYgLTEuMzA0MjIgaCAwLjAyNjExIGwgMS43NzgsMi40MTc1OCBoIDEuNjM0NDIgeiIgLz48cGF0aCBzdHlsZT0iZmlsbDojZTMxODM3O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDI3LjEzMTIyNywxMTcuMjM2NjQgYyAtMC40NTIyNjEsMC4wODU0IC0xLjEyMjUzOSwwLjQ5NjAxIC0xLjEyMDA2OSwxLjIyMTY3IDAuMDAxNCwwLjY1ODk5IDAuNTQwNDU1LDEuMDU4NjkgMC41NDIyMTksMS45MjE5MyAwLjAwMjUsMC42NDk4MiAtMC4zNTU2LDEuMDg3NjIgLTAuNzQyOTUsMS4zMjk5NyAwLjE1NjYzMywtMC4wMTM4IDAuMzI4MDgzLC0wLjAyMjkgMC41MTY0NjcsLTAuMDIzMyAwLjM5NTgxNiwtMTBlLTQgMC42MzQyOTQsMC4wMzY3IDAuNjQ5MTExLDAuMDM5MiBsIDIuMDI4NDcyLC0yLjQ4OTIgYyAtMC41NjMzODYsLTAuODQzNDkgLTEuMjIxMzE3LC0xLjQ5Nzg5IC0xLjg3MzI1LC0yLjAwMDI1IiAvPjxwYXRoIHN0eWxlPSJmaWxsOiNlMzE4Mzc7ZmlsbC1vcGFjaXR5OjE7ZmlsbC1ydWxlOm5vbnplcm87c3Ryb2tlOm5vbmU7c3Ryb2tlLXdpZHRoOjAuMzUyNzc3NzgiIGQ9Im0gMjguODM1MTQzLDEyMy45NTg3NSBjIDAuMjU1NzY0LC0wLjM5NzU4IDAuMjg3ODY3LC0xLjAzMTE3IDAuMzA5Mzg2LC0xLjY3NjA1IDAuMDI0MzQsLTAuNjAyMTkgMC4xNDk1NzgsLTEuMDU1MTYgMC45NTQ5NywtMS4wNTc5OCAwLjE3ODE1MiwtMy41ZS00IDAuMzQ4MTkxLDAuMDI0IDAuNjU1ODEzLDAuMDIzMyAxLjE3OTY4OSwtMC4wMDUgMS45NDk4MDMsLTAuNDExMzQgMi40Mjg4NzUsLTAuNjc4MDQgLTAuOTc4NjA1LC0wLjYyNDA3IC0yLjQwNzM1NSwtMS4yNjE1NCAtNC4xNzk3MTEsLTEuMzMzMTUgLTAuMTE1NzExLDAuMzI1OTcgLTEuMDEzODgzLDIuODIzNjMgLTEuMDgxOTY5LDMuMDI1NDIgMC4wMTAyMywwLjAxMiAwLjE2NzU2OSwwLjE4ODAzIDAuMzY0MDY3LDAuNTMxOTkgMC4yODk5ODMsMC40NzIzNyAwLjQ0NTU1OCwwLjg3MjQyIDAuNTQ4NTY5LDEuMTY0NTIiIC8+PC9nPjxnIHN0eWxlPSJmaWxsOiNmNTgwMjU7ZmlsbC1vcGFjaXR5OjEiID48cGF0aCBzdHlsZT0iZmlsbDojZjU4MDI1O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDI0LjU1MDkwNCwxMjEuOTE4NzQgYyAtMC4xMDI2NTgsMy41ZS00IC0wLjE1MzgxMSwtMC4wNjc3IC0wLjE2NzU2OSwtMC4xODU5MSAtMC4wMTMwNSwtMC4xMTcxMyAtMC41MjA3LC00Ljc1ODYyIC0wLjU5NTg0MiwtNS40NjEgLTAuMDEwOTQsLTAuMTAyNjYgLTAuMDM2MzQsLTAuMjkxMDUgLTAuMDM2NjksLTAuMzU4MDcgLTMuNTNlLTQsLTAuMTA3OTUgMC4wNzAyLC0wLjE2NDQgMC4xNTMxMDYsLTAuMTY0NzUgMC4yNDAyNDEsLTAuMDAxIDEuNTUwNDU4LDAuMzA1ODYgMi45NDA0MDIsMS4yODA1OCAtMC40MDA3NTUsMC4xMTI1NCAtMS4xMjUwMDgsMC41MjkxNyAtMS4xMjE4MzMsMS4zOTE3MSAwLjAwMjgsMC43NjM3NyAwLjU0OTI3NSwxLjE4MzkyIDAuNTUyMDk3LDEuOTQ5OCAwLjAwNDYsMS4yNDU2NiAtMS40MjczMzksMS41NDY5MyAtMS43MjM2NzIsMS41NDc2NCIgLz48cGF0aCBzdHlsZT0iZmlsbDojZjU4MDI1O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDI4Ljk1MTYzLDEyNC4yOTAwMSBjIDAuMDIxODcsMC4wNTc5IDAuMDQyMzMsMC4xMDY1NCAwLjA2MzE1LDAuMTQwNDEgMC4wMzIxLDAuMDU0IDAuMDczMzgsMC4wNzg3IDAuMTI0ODg0LDAuMDc4NyAwLjAzMjEsLTMuNWUtNCAwLjA3MTYxLC0wLjAxMTMgMC4xMTU3MTEsLTAuMDMxIDAuMTA2ODkxLC0wLjA0OTQgNC4zNDI2OTQsLTIuMDIxMDYgNC45ODE1NzUsLTIuMzE1NjMgMC4wOTI0MywtMC4wNDQ0IDAuMjY4NDYzLC0wLjEyMzEyIDAuMzI1OTY2LC0wLjE1Njk5IDAuMDU5OTcsLTAuMDM0MiAwLjA4NzQ5LC0wLjA4NCAwLjA4NzQ5LC0wLjEzNDc2IC0zLjUzZS00LC0wLjAyODYgLTAuMDA4NSwtMC4wNTcyIC0wLjAyNDY5LC0wLjA4MzMgLTAuMDgwMDgsLTAuMTI5MTEgLTAuNDg5NjU2LC0wLjU2NDA5IC0xLjE3NDc1LC0xLjAzOTI4IC0wLjU0Mzk4NCwwLjI5OTUxIC0xLjM5MzQ3MywwLjc2MjcxIC0yLjY1NzEyMiwwLjc2NzY1IC0wLjMwOTczOSw3ZS00IC0wLjM3OTU4OSwtMC4wMjAxIC0wLjU5MTI1NiwtMC4wMTk0IC0wLjYxNjY1NiwwLjAwMiAtMC43NzA4MTksMC4yNjYgLTAuNzkzMzk3LDAuODA2ODEgLTAuMDAzNSwwLjEwMjMgLTAuMDA1NiwwLjIzOTUzIC0wLjAxMTY0LDAuMzkwNTIgLTAuMDE5NCwwLjQ4MzMxIC0wLjA3NjU1LDEuMTUwMDYgLTAuNDQ1OTExLDEuNTk2MzIiIC8+PHBhdGggc3R5bGU9ImZpbGw6I2Y1ODAyNTtmaWxsLW9wYWNpdHk6MTtmaWxsLXJ1bGU6bm9uemVybztzdHJva2U6bm9uZTtzdHJva2Utd2lkdGg6MC4zNTI3Nzc3OCIgZD0ibSAzNS41Njk0MjQsMTI5LjA3NzQ1IGMgLTAuNDcwMjUzLDEuMjcxMDYgLTEuMDc1OTcyLDEuNDM1NDUgLTEuNTk1NjE0LDEuNDM1NDUgLTAuMzY3MjQyLDAgLTAuNjM3MTE3LC0wLjEzMTIzIC0wLjY2NTMzOSwtMC4xNDU2OSBsIDAuMTk2MTQ1LC0wLjU5NDc5IGMgMC4wMTU1MiwwLjAwOCAwLjIxNDEzNiwwLjExNTAxIDAuNDM0OTc1LDAuMTE1MDEgMC40MTI3NSwwIDAuNjcxNjg5LC0wLjIyOTMxIDAuOTAwNjQxLC0wLjk0NzU2IDAsMCAtMS40MDI5OTcsLTMuMDU0IC0xLjQxOTU3NywtMy4wOTIxIDAuMDI1NzUsLTAuMDA4IDAuMTkzNjc1LC0wLjA1OTMgMC4zODUyMzMsLTAuMDU5MyAwLjQ1NDAyNSwwIDAuNTU0MjE0LDAuMjgzNjQgMC42NzA5ODMsMC41NjY5MiAwLjA5ODc4LDAuMjM3NzcgMC43NDU0MiwxLjc5NzA1IDAuNzQ1NDIsMS43OTcwNSBoIDAuMDIxNTIgbCAwLjc0ODk0NywtMi4zMDQ3IGggMC43NzY4MTcgeiIgLz48cGF0aCBzdHlsZT0iZmlsbDojZjU4MDI1O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDQ1Ljg0Mzk3MSwxMjguOTI0NjYgLTEuMDg1ODUsLTEuNTc3NjIgMS4wNjMyNzIsLTEuNTQ0MTEgaCAtMC45MTY1MTYgbCAtMC43NDAxMjgsMS4xMzIwNiBjIC0wLjE5OTMyLC0wLjMxMjkxIC0wLjM4NzM1LC0wLjYwODE5IC0wLjQ0NTU1OSwtMC42OTk5MSAtMC4xNDgxNjYsLTAuMjI3NTQgLTAuMjgxNTE2LC0wLjQ1NzIgLTAuNjE5ODMsLTAuNDUwNDkgLTAuMDQ0OCwwLjAwMSAtMC4wOTIwNywwLjAwNSAtMC4xNDI4NzUsMC4wMTU1IC0wLjE4ODczNiwwLjAzNDYgLTAuMzQ0MzExLDAuMTE1NzEgLTAuMzY3OTQ3LDAuMTI3NyAwLjAxMTk5LDAuMDE5MSAwLjUyMDcsMC43NDAxMyAxLjAwNzUzMywxLjQ0MTQ1IGwgLTEuMDY5NjIyLDEuNTU1NCBoIDAuOTE1NDU4IGwgMC43NDM2NTYsLTEuMTM1OTQgMC43NDM2NTUsMS4xMzU5NCB6IiAvPjxwYXRoIHN0eWxlPSJmaWxsOiNmNTgwMjU7ZmlsbC1vcGFjaXR5OjE7ZmlsbC1ydWxlOm5vbnplcm87c3Ryb2tlOm5vbmU7c3Ryb2tlLXdpZHRoOjAuMzUyNzc3NzgiIGQ9Im0gMzcuNDAwMzc2LDEyNi44NjE2OSB2IDIuMDY3OTggaCAwLjc3NjQ2NCB2IC0yLjE0OTQ3IGMgMC4wNDIzMywtMC4wMzg4IDAuMzE4NTU4LC0wLjMwMjMzIDAuNjI0NDE3LC0wLjMwMjMzIDAuMzk5MzQ0LDAgMC42MDY0MjUsMC4yODkyOCAwLjYwNjQyNSwwLjY2NjA0IHYgMS43ODU3NiBoIDAuNzc1NzU4IHYgLTEuOTgwMTQgYyAwLC0wLjkzOTggLTAuNzIzNTQ3LC0xLjE0Nzk0IC0xLjEyNzEyNSwtMS4xNDc5NCAtMC40ODU0MjIsMCAtMC44MzA3OTIsMC4zMDU4NiAtMC45MzM0NSwwLjQwNzQ2IC0wLjAzMzE2LC0wLjEyNTk0IC0wLjE4MDk3NSwtMC4zMzkwMiAtMC41MTk5OTUsLTAuMzM5MDIgLTAuMTE5NTkxLDAgLTAuMjc1ODcyLDAuMDM1MyAtMC4yOTAzMzYsMC4wMzkyIDAuMDIzNjQsMC4xMTY3NyAwLjA4Nzg0LDAuMzkzNyAwLjA4Nzg0LDAuOTUyNSIgLz48cGF0aCBzdHlsZT0iZmlsbDojZjU4MDI1O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDQxLjkxNDY5NywxMjQuOTEyNDEgYyAwLDAuMjU2NDcgLTAuMjEzNzgzLDAuNDY0MjYgLTAuNDc4NzE5LDAuNDY0MjYgLTAuMjY0NTg0LDAgLTAuNDc4MzY3LC0wLjIwNzc5IC0wLjQ3ODM2NywtMC40NjQyNiAwLC0wLjI1NzUzIDAuMjEzNzgzLC0wLjQ2NjM3IDAuNDc4MzY3LC0wLjQ2NjM3IDAuMjY0OTM2LDAgMC40Nzg3MTksMC4yMDg4NCAwLjQ3ODcxOSwwLjQ2NjM3IiAvPjxwYXRoIGQ9Im0gNDEuODIwNTgxLDEyOC45MjUyNiBoIC0wLjc2OTc3IHYgLTMuMDc5NCBoIDAuNzY5NzcgeiIgc3R5bGU9ImZpbGw6I2Y1ODAyNTtmaWxsLW9wYWNpdHk6MTtmaWxsLXJ1bGU6bm9uemVybztzdHJva2U6bm9uZTtzdHJva2Utd2lkdGg6MC4zNTI3Nzc3OCIgLz48cGF0aCBzdHlsZT0iZmlsbDojZjU4MDI1O2ZpbGwtb3BhY2l0eToxO2ZpbGwtcnVsZTpub256ZXJvO3N0cm9rZTpub25lO3N0cm9rZS13aWR0aDowLjM1Mjc3Nzc4IiBkPSJtIDMwLjk0MjMyLDEyNi4yMDE0NiBjIDAuMDU0MzMsLTAuMDQ1NSAwLjQ1MDE0NCwtMC40MTMxIDEuMDAwODMxLC0wLjQxMzEgMC42MDI1NDQsMCAxLjA0NzA0NCwwLjMxNDMyIDEuMDQ3MDQ0LDEuMDgwMiB2IDIuMDYxMjggaCAtMC44MDQzMzMgdiAtMS44NDA3OSBjIDAsLTAuMzM5MDIgLTAuMTg2OTczLC0wLjYwMTg0IC0wLjU0MDgwOSwtMC42MDE4NCAtMC4zMzY1NSwwIC0wLjYyMTk0NywwLjI2NTY0IC0wLjcwMjczMywwLjMzMjMyIHYgMi4xMTAzMSBoIC0wLjc5ODY4OSB2IC00LjcwMTQ3IGggMC4xNjkzMzMgYyAwLjM4Mjc2NCwwIDAuNjI5MzU2LDAuMjc4MzUgMC42MjkzNTYsMC42NDkxMiB6IiAvPjwvZz48L2c+PC9nPjwvc3ZnPg==);height:1em;width:1.91em}
.blogo-micron{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwIDAuMDAyIDI4Ny45ODcgNjEuNzAyIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxnIHRyYW5zZm9ybT0idHJhbnNsYXRlKDAgLS4wMDI1MzUyKSBtYXRyaXgoLjEzMzMzIDAgMCAtLjEzMzMzIDAgNjEuNzA3KSI+PHBhdGggZD0ibTAgNjcuMzJoOTMuNjI1YzI4LjA5IDAgNDEuMDIgMTEuMTQ4IDQxLjAyIDQyLjgwMXY2Ni40M2MwIDk4Ljk3NiA0Ni4zNjcgMTUwLjcgMTM1LjA5IDE1MC43IDQ2LjM2NCAwIDgxLjU4Ni0xNi40OTYgMTAyLjU0LTQ4LjE1MiAyMS44NDggMzEuNjU2IDU1LjI4NiA0OC4xNTIgMTAxLjY1IDQ4LjE1MiA4OC43MjIgMCAxMzUuMDktNTEuNzE5IDEzNS4wOS0xNTAuN3YtMTY5LjQyaC02NS45ODV2MTY5LjQyYzAgNjEuMDgyLTI0LjUxOSA5MC41MDgtNjkuMTA1IDkwLjUwOC00NC41ODIgMC02OS4xMDYtMjkuNDI2LTY5LjEwNi05MC41MDh2LTE2OS40MmgtNjUuOTg0djE2OS40MmMwIDYxLjA4Mi0yNC41MiA5MC41MDgtNjkuMTAyIDkwLjUwOC00NC41ODYgMC02OS4xMDUtMjkuNDI2LTY5LjEwNS05MC41MDh2LTY2LjQzYzAtNzQuMDA4LTM1LjY2OC0xMDIuOTktMTA3LTEwMi45OWgtOTMuNjI1djYwLjE4NyIvPjxwYXRoIGQ9Im03NDQuNTUgNDYyLjc4YzIzLjE4MyAwIDQyLjM1NS0xOS4xNzIgNDIuMzU1LTQyLjM1NSAwLTIzLjE4NC0xOS4xNzItNDIuMzU2LTQyLjM1NS00Mi4zNTYtMjMuMTg0IDAtNDIuMzU2IDE5LjE3Mi00Mi4zNTYgNDIuMzU2IDAgMjMuMTgzIDE5LjE3MiA0Mi4zNTUgNDIuMzU2IDQyLjM1NXoiLz48cGF0aCBkPSJtNzExLjU2IDMyMC4xMWg2NS45ODR2LTMxMi45OGgtNjUuOTg0eiIvPjxwYXRoIGQ9Im0xMDA4LjQgMzI3LjI1YzMyLjU0IDAgNTkuMjktNi4yNDIgODUuMTUtMTcuODM2bC0yMC45NS01NS43MjZjLTI1Ljg2IDkuODA0LTQ1LjAzIDEzLjM3NS02NC4yIDEzLjM3NS00OS45MzYgMC04Mi4wMzctMzUuNjY4LTgyLjAzNy0xMDMuNDQgMC02Ny43NjYgMzIuMTAxLTEwMy40MyA4Mi4wMzctMTAzLjQzIDIwLjUxIDAgMzkuNjggNC4wMTE3IDY3Ljc2IDE1LjE1NmwyMi43NC01NS43MjdjLTI4LjUzLTEyLjkzLTYwLjYzLTE5LjYxNy05MC41LTE5LjYxNy05MC45NTUgMC0xNDguOTEgNjEuMDc4LTE0OC45MSAxNjMuNjIgMCAxMDIuNTQgNTcuOTU3IDE2My42MiAxNDguOTEgMTYzLjYyeiIvPjxwYXRoIGQ9Im0xMjg2LjggMzI3LjI1YzIwLjk1IDAgNDIuOC00LjQ2MSA1OS43NC0xMC42OTlsLTE5LjYyLTU2LjYyMWMtMTIuNDggNC45MDItMjUuNDEgNy4xMzMtNDAuMTIgNy4xMzMtMzguMzQgMC01Ny45Ni0yNy42NDUtNTcuOTYtODEuNTkgMC00Ny43MDMgMC44OS05OS40MjIgMS43OC0xNzguMzRoLTY1Ljk4Yy0wLjg5IDc4LjkxNC0xLjc4IDEzMC42My0xLjc4IDE3OC4zNCAwIDk2LjMwMSA0My42OSAxNDEuNzggMTIzLjk0IDE0MS43OHoiLz48cGF0aCBkPSJtMTUyNy45IDMyNy4yNGMtOTMuNjMgMC0xNTEuNTgtNjEuMDgtMTUxLjU4LTE2My42MiAwLTEwMi41NCA1Ny45NTItMTYzLjYyIDE1MS41OC0xNjMuNjJzMTUxLjU4IDYxLjA4IDE1MS41OCAxNjMuNjJjMCAxMDIuNTQtNTcuOTUyIDE2My42Mi0xNTEuNTggMTYzLjYyem0wLTYwLjE5YzUyLjYxIDAgODQuNzEyLTM1LjY2MyA4NC43MTItMTAzLjQzIDAtNjcuNzY1LTMyLjEwMi0xMDMuNDMtODQuNzEyLTEwMy40My01Mi42MSAwLTg0LjcxMiAzNS42NjctODQuNzEyIDEwMy40MyAwIDY3Ljc3IDMyLjEwMiAxMDMuNDMgODQuNzEyIDEwMy40M3oiLz48cGF0aCBkPSJtMTg4OCAzMjcuMjVjOTAuOTUgMCAxMzcuMzItNTEuNzE5IDEzNy4zMi0xNTAuN3YtNjYuNDNjMC0zMS42NTIgMTIuOTMtNDIuODAxIDQxLjAxLTQyLjgwMWg5My42M3YtNjAuMTg3aC05My42M2MtNzEuMzMgMC0xMDcgMjguOTgtMTA3IDEwMi45OXY2Ni40M2MwIDYxLjA4Mi0yNC41MiA5MC41MDgtNzEuMzMgOTAuNTA4LTQ3LjI2IDAtNzEuMzQtMjkuNDI2LTcxLjM0LTkwLjUwOHYtMTY5LjQyaC02NS45OHYxNjkuNDJjMCA5OC45NzYgNDYuMzcgMTUwLjcgMTM3LjMyIDE1MC43eiIvPjxwYXRoIGQ9Im0yMjE2LjIgNjcuMzIxYy0xNi41NCAwLTMwLjA4OC0xMy4zOTktMzAuMDg4LTMwLjEwMyAwLTE2LjY5NSAxMy41NDgtMzAuMDg4IDMwLjA4OC0zMC4wODggMTYuNTMgMCAzMC4xMDIgMTMuMzkzIDMwLjEwMiAzMC4wODggMCAxNi43MDMtMTMuNTcyIDMwLjEwMy0zMC4xMDIgMzAuMTAzem0wLTYuMDM1MmMxMy4zOSAwIDIzLjk4LTEwLjc1MSAyMy45OC0yNC4wNjcgMC0xMy4zMDktMTAuNTktMjQuMDUzLTIzLjk4LTI0LjA1My0xMy4zMSAwLTIzLjg5MiAxMC43NDQtMjMuODkyIDI0LjA1MyAwIDEzLjMxNiAxMC41ODIgMjQuMDY3IDIzLjg5MiAyNC4wNjd6bS0xMS44MjEtNy42MDI1di0zMi45MTVoNi4xMDg0djEzLjI0MmgzLjg5NjVsNy43NjM3LTEzLjI0Mmg2LjcwOWwtNy45Mzk1IDEzLjQ3N2M0Ljg3IDEuMTU2MyA4LjE4ODUgNC42Mjc5IDguMTg4NSA5LjUwNjggMCA1Ljc4NTItMy44MDc5IDkuOTMxNi0xMS4zMzggOS45MzE2em02LjEwODQtNS4yMTQ4aDcuMDMxM2MzLjgxIDAgNS43MTI5LTEuODIyMyA1LjcxMjktNC43MTY4cy0xLjkwMjktNC43MDIxLTUuNzEyOS00LjcwMjFoLTcuMDMxM3oiIGRpc3BsYXk9Im5vbmUiLz48L2c+PC9zdmc+);height:0.75em;width:3.5em}
.blogo-kingston{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIzLjMyIDAgMTcuMzU5IDI0IiByb2xlPSJpbWciIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+PHBhdGggZD0iTTE0LjEyMy4wMDA3Yy0uNTQ0Mi0uMDAzOC0xLjAzMDEuMDA4LTEuNDM4OS4wMjA0QzcuMTg1LjE2OTcgNC4yMTE1IDEuNzA1NyA0LjIxMTUgMS43MDU3cy0uMjk2Ny4xOTg4LS4xNDguODQyOGMwIDAgLjA5OTMuNzkyMS4xOTgzIDEuMTM5bC4wNDk0LjA5OTZjLS4wOTkuMDk5LS40OTU4LjI5NzMtLjY0NDUuNDk1NC0uMzQ2OC40NDYtLjA0OTMgMi40NzcyLS4wNDkzIDIuNDc3Mi4zNDY4IDIuMTMwMy42OTM4IDIuNTI2NS42OTM4IDIuNTI2NXMuNDk1Ni42NDM2IDEuMTg5MiAxLjA4OTVjLjI5NzMuMTQ4Ni4yNDc3LjQ5NTQuMjQ3Ny40OTU0TDMuMzIwMyAyNGgxNi4zNDkybC0zLjQxODctNy40ODA4Yy42OTM2IDAgMi4xMzA2LjM0NjQgMi45MjMyLTEuODgzLjc0MzItMi4xMzAzIDEuMTM5Ny01LjM1MDIgMS4xODkzLTYuMjkxNS4wOTktLjk0MTQtLjA5OTktMi45MjMzLS4wNTAzLTMuNDE4NyAwLS4xNDg2LjM0NzMtLjY0NDIuMzQ3My0uOTQxNS4wNDk2LS40NDU5LS4wMDA2LS44NDE4LS4wOTk2LTEuNTg1LS4wNDk2LS4yOTcyLS4wOTgzLS42NDQtLjE5NzQtLjk5MDgtLjA0OTYtLjI0NzgtLjA5OTktLjM5NjQtLjI5OC0uNDk1NUMxNy45MS4xNzAxIDE1Ljc1NTUuMDEyNCAxNC4xMjMuMDAwN1ptLTEuNDM4OS40MTcxYy41NDUgMCA1LjEwMjctLjA0OTIgNy4yMzMuODkyMi4xOTgzLjE0ODYuMDQ5OC44OTE1LS4wNDkzIDEuMjg3OS0uMDQ5NS4yOTcyLS4zOTY3LjM5NjctLjM5NjcuMzk2Ny0uMzQ2OC4wOTktLjQ0Ni4zNDY0LS40NDYuMzQ2NHMuNDQ1OCA0LjMxMDIuNDk1NCA0LjQ1ODljLjA0OTUuMTk4MS0uMTQ4NS4xOTgxLS41NDQ4LjI0NzctLjE5ODIgMC0yLjQ3NzIuMDQ5My0yLjQ3NzIuMDQ5M3MtLjQ5NTYtLjA0OTEtLjQ0Ni0uMzQ2NGMwLS4xOTgxLjA5OTItLjU5NS4xOTgzLS41OTVoLjQ0NjFzLjk5MS4wNDk3LjY5MzgtLjA0OTRsLTEuMDQwMi0uMjQ3N3MtLjI0ODMuMDAwNC0uMzQ3NC4xNDljLS4wNDk1LjE0ODYtLjI5Ny45NDE1LS4yOTcuOTQxNXMtLjAwMDIuMDQ5MS4wNDkzLjA5ODdjLjA0OTUuMDQ5NSAyLjU3NjggMS44ODMgMi41NzY4IDEuODgzcy0yLjEzMTEtLjE5OS0yLjc3NTItLjA1MDNjLS42NDQuMTQ4Ni0xLjk4MTMuODQyMi0yLjgyMzUuOTkwOC0uODQyMi4xNDg3LTMuOTYzNi40OTU1LTQuMTYxOC40OTU1bC0xLjIzODYtNS4zNXMtLjE0ODQtMS4zMzc1LTEuNTM1Ni0xLjI4OGMtMS4wNDA0LjA0OTUtMS4xODkuMjk2Ny0xLjIzODYuMzk1OC0uMDk5LjE5ODEgMCAuMzk2NyAwIC4zOTY3bDMuMzY5MyA1Ljc0NjhzLTIuMjc5Mi0xLjA4OTYtMy4xNzEtMi4zMjgyYy0uNDk1NC0uNjQ0LS45NDE2LTMuODY0NS0uNjQ0NC00LjQwOTUuMjk3My0uNDk1NCAyLjEzMDYtLjg5MTUgMi45MjMzLS43OTI1LjM5NjMuMDQ5Ni43NDMzLjQ0NTIuOTQxNS42OTI5LjA0OTUuMDk5LjA5ODUuMDUwMS4xNDguMDk5NiAwIDAtLjE5ODItMS4yMzgzLS45OTA5LTEuMjg3OS0xLjEzOTQtLjA5OS0yLjM3NzQuMzQ2NC0yLjM3NzQuMzQ2NHMtLjA5OTUtLjAwMDQtLjE0OS0uMTQ5Yy0uMDQ5Ni0uMTk4Mi0uMTk4NC0xLjIzODYtLjE5ODQtMS4yMzg2cy4wNDk1LS4xOTguMjQ3Ny0uMjk3YzAgMCAzLjIyMDktMS40ODYzIDguMDI2NS0xLjQ4NjN6bS42NDM1IDEuNDI3M2MtLjA3MDQuMDAzLS4wOTg3LjAwOTYtLjA5ODcuMDA5Ni0yLjA4MDguODQyMy0zLjc2NSAyLjY3NS0zLjc2NSAyLjU3NTkuMTk4MS4wNDk1LjU5NCAwIC41OTQgMCAxLjgzMzItMS41ODU0IDMuNDE4Ny0yLjIyOTUgMy40MTg3LTIuMjI5NSAxLjMzNzcgMCAzLjYxNjUuNzkyNyAzLjc2NS43NDMyLjA0OTYgMCAuMDQ5OC0uMjQ3NS0uMDQ5My0uMjk3LS4yNDc3LS4wNDk2LS43NDMzLS4yOTczLTEuNjg0Ni0uNDk1NS0xLjM3NDgtLjI5NzMtMS45Njg4LS4zMTYtMi4xODAxLS4zMDY3Wm02Ljc4OCAxLjM5NzJjLjE5ODEuMDQ5Ni4xOTguMDQ5LjI5Ny4xNDguMTQ4Ni4wOTkyLjA5OTEuMzk2NiAwIC40NDYxLS4wOTkuMDk5MS0uMTQ4NC0uMDk4OC0uNzkyNS0uMDQ5MyAwIDAgLjI5NzMtLjU5NDMuNDk1NS0uNTQ0OHptLTQuODcxMS4xMDE2Yy0uMzYyMy0uMDE4Ni0uODY0MS4wNDY5LTEuNDIxNS4xOTU1LS43NDMxLjE5ODItMi4yMjk0Ljk0MTUtMi4yMjk0Ljk0MTUuNTk0NS4yNDc3IDEuNTg2MS4zNDY4IDIuNTI3NS40OTU0IDEuMDQwNC4wOTkxIDIuMTc5LS40NDYgMi4xNzktLjQ0Ni0uMDQ5NS0uMTQ4Ny0uMzk2My0xLjA0MDgtLjc0My0xLjE0LS4wODY4LS4wMjQ3LS4xOTE5LS4wNDAyLS4zMTI2LS4wNDY0em0uNzg2NyA3LjQwMTVjLjcyNDIuMDE3NCAxLjU3NTkuMTAxMiAyLjQ0OS4zMjQxIDAgMCAuNDk1Ny4zOTY0LjQ0NjEuNzQzMiAwIDAtMy41NjcuMTk4LTQuOTU0My0uOTQxNiAwIDAgLjg1Mi0uMTU0OCAyLjA1OTItLjEyNTd6bS05LjczODMuMTc2IDEuNTM1NiAxLjA0MDMgMi41MjY1IDExLjU0MjlIMy45MTQ1Wm0xMS44MDMyIDEuNDU1NGE4LjQ3OSA4LjQ3OSAwIDAgMSAuNzMxNS4wMzFzLjI5NzMuMjQ3NS0uNDk1NCAxLjA0MDFjLS45OTA5Ljk0MTQtMi43MjU2IDEuNjg0My00LjI2MTUgMS4yODggMCAwIC41NjY0LTIuMzUxIDQuMDI1NC0yLjM1OTF6bS04LjA4NzUgNC4xOTE4czMuMTIxNiAxLjkzMjMgMy42MTcgMi42NzU1bC4zNDY0IDQuMzEwOGgtMi4yNzg3Wm01LjMwMDcgMy45NjM0czEuODMzNSAxLjY4NTIgMi4zNzg1IDMuMDIyOWgtMy4wNzEzeiIvPjwvc3ZnPg==);height:1.05em;width:0.76em}
.blogo-corsair{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwIDAuNDEyIDI0IDIzLjE3NSIgcm9sZT0iaW1nIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxwYXRoIGQ9Ik0xMy4wNzIuNDEyczEuOTEzIDMuODgxIDEuNTYzIDUuNWMwIDAgNC45ODcgMS42MTIgNS41NCA0LjI3MiAwIDAgMi43My0zLjU5NC03LjEwMy05Ljc3MnpNNy45MDggNC4wNjdzMS42NzggMi42MjUgMS40MTcgNC4zNWwyLjgxOCAxLjA2N2ExNy41NiAxNy41NiAwIDAgMC0uOTkxLTMuMjQ4em0zLjc4NC42OTFhMTQuMTYyIDE0LjE2MiAwIDAgMSAuMTYzIDEzLjc5NCAxNy43MDIgMTcuNzAyIDAgMCAwIC41OTQtNi41ODVjLS4wMTctLjE4Ni0uMDMxLS4zNjgtLjA1My0uNTVMNi45MDggNy43NTlhMTQuMTMgMTQuMTMgMCAwIDEgMS4xMzMgNC40NjUgMTQuMDIgMTQuMDIgMCAwIDEtMS4zMDUgNy4zNDcgMTcuNzUgMTcuNzUgMCAwIDAgLjQ0Mi01Ljk4OC45Mi45MiAwIDAgMS0uMDIyLS4yNDNsLTUuMTMzLTIuNzI2YTExLjYzOSAxMS42MzkgMCAwIDEgMS4wNzUgMy45M0ExMS43ODUgMTEuNzg1IDAgMCAxIDAgMjMuNTg3YzIxLjkxLTkuMjkgMjIuNzk1LTMuMTczIDIyLjc5NS0zLjE3M3MxLjY1Ni0yLjE2NCAxLjA4NS00LjUxQzIzLjEyOCAxMi43OSAxMS42OTIgNC43NTkgMTEuNjkyIDQuNzU5ek0zLjA0IDcuMjQ1czEuNjI5IDIuMDkgMS4zNjMgMy44MTVsMi41NjcuNjM3YTIwLjM1NyAyMC4zNTcgMCAwIDAtLjg2My0yLjc4OHoiLz48L3N2Zz4=);height:1em;width:1.04em}
.blogo-gskill{--m:url(data:image/png;base64,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);height:1em;width:1.93em}
.blogo-adata{--m:url(data:image/svg+xml;base64,PHN2ZyB2aWV3Qm94PSIwIDAgNzkuMzc1IDExLjYxNCIgeG1sbnM6aW5rc2NhcGU9Imh0dHA6Ly93d3cuaW5rc2NhcGUub3JnL25hbWVzcGFjZXMvaW5rc2NhcGUiIHhtbG5zOnNvZGlwb2RpPSJodHRwOi8vc29kaXBvZGkuc291cmNlZm9yZ2UubmV0L0RURC9zb2RpcG9kaS0wLmR0ZCIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB4bWxuczpzdmc9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj48ZGVmcyAvPjxnIHRyYW5zZm9ybT0idHJhbnNsYXRlKC02Ny41OTgwNDQsLTE2OS4zOTc2MykiPjxnIHRyYW5zZm9ybT0ibWF0cml4KDAuNDUwMzk4MDUsMCwwLC0wLjQ1MDM5ODA1LDEzMy40NzAxMSwxNzYuOTEyOTcpIiA+PHBhdGggc3R5bGU9ImZpbGw6IzA0MzM4ZTtmaWxsLW9wYWNpdHk6MTtmaWxsLXJ1bGU6bm9uemVybztzdHJva2U6bm9uZSIgZD0iTSAwLDAgNi4yMDksMTEuOTEyIDguMjAzLDExLjkwNyBDIDguODA1LDExLjg3IDkuMjA3LDExLjY1NCA5LjUyNywxMS4xMDUgTCAxNS4zNjUsMCBaIG0gMTcuNDk4LDEzLjQ4OCBjIC0xLjEyNSwyLjAzOCAtMS43NTIsMi40NyAtNS4yMTUsMi40NyBsIC04LjE0NiwwLjAwOSAtMTMuMzY2LC0yNC44OCA1LjE1NywtMC4wMDkgMi42MDksNC44MyBoIDE4LjkwOCBsIDIuNzEzLC00LjgyMSBIIDI5Ljk4IFogTSAtNjEuNTA0LDAgbCA2LjIwOSwxMS45MTIgMS45OSwtMC4wMDUgYyAwLjYwMiwtMC4wMzcgMS4wMSwtMC4yNTMgMS4zMjgsLTAuODAyIEwgLTQ2LjEzOSwwIFogbSAxMS43OTksMTUuOTU4IC04LjE0NSwwLjAwOSAtMTMuMzY3LC0yNC44OCA1LjE1NiwtMC4wMDkgMi42MTYsNC44MyBoIDE4LjkwMiBsIDIuNzE3LC00LjgyMSBoIDkuODIyIGwgLTEyLjQ4MiwyMi40MDEgYyAtMS4xMjUsMi4wMzggLTEuNzQ4LDIuNDcgLTUuMjE5LDIuNDcgTSAtMTM2LjU0MSwwIGwgNi4yMSwxMS45MTIgMS45ODgsLTAuMDA1IGMgMC42MDEsLTAuMDM3IDEuMDA3LC0wLjI1MyAxLjMyOSwtMC44MDIgTCAtMTIxLjE3OSwwIFogbSAxMS44MDEsMTUuOTU4IC04LjE1MSwwLjAwOSAtMTMuMzYyLC0yNC44OCA1LjE1MiwtMC4wMDkgMi42MTQsNC44MyBoIDE4LjkwNSBsIDIuNzE0LC00LjgyMSBoIDkuODIyIGwgLTEyLjQ3OSwyMi40MDEgYyAtMS4xMjMsMi4wMzggLTEuNzUxLDIuNDcgLTUuMjE1LDIuNDcgbSAxMjAuNjg3LC0wLjI0OSAtMzMuNTI5LDAuMDEzIDAuMDA2LC00LjMzIGggMTIuOTkyIGwgMC4wMTgsLTIwLjIyMiBoIDcuODAyIGwgMC4wMSwxOC4xODQgYyAtMC4wMDQsMC43OSAwLjA4NiwxLjMzNSAwLjI2NCwxLjU4NCAwLjE2MiwwLjIzNCAwLjQyLDAuNDA0IDEuMjEzLDAuNDE2IDAsMCAwLjAxMSwtMC4wMDQgMC4wMzUsLTAuMDA0IEggLTQuMDIzIFogTSAtODguMTg2LC01LjI5IGggLTkuNjcgbCAwLjAyMywxOC4yMzMgOS42MDgsLTAuMDMzIGMgMC4wMywwLjAwNCAwLjA1MywwLjAwNCAwLjA4LDAuMDA0IDUuMjQxLC0wLjAyOSA4LjQzNCwtMi4zNjIgOC40NjMsLTkuMTEyIC0wLjAyMSwtNS44NjggLTMuMjM4LC05LjAzNCAtOC41MDQsLTkuMDkyIG0gLTAuMDc0LDIxLjk3NiAtMTYuNTc1LC0wLjAwNCAwLjAwOSwtMjUuNzgyIGggMC4xNTkgbCAxNi40NDQsMC4wMTYgaCAwLjA2OSBjIDUuNTU0LDAgOS42NDIsMC43MzIgMTIuMzYzLDIuNzI1IDIuNzE5LDEuOTk3IDQuMDIsNS4yNDUgNC4wMTQsMTAuMTYxIDAuMDI3LDkuOTE4IC01LjEzOSwxMi44ODQgLTE2LjQ4MywxMi44ODQiIC8+PC9nPjwvZz48L3N2Zz4=);height:0.7em;width:4.78em}
td.up{color:var(--tx)} td.down{color:var(--rx)}
/* Quiet detail line under a process row: what it's doing (streams, players) */
tr.detail td{border-top:none;padding:0 0 9px calc(1.15em + 7px);font-size:12.5px;font-weight:400;color:var(--muted);text-align:left;white-space:normal}
tr.detail .warn{color:var(--warn)}
#procNote{color:var(--muted);font-size:12.5px;margin-top:6px}
/* Storage: one row per drive - name, usage bar, used/total, disk health, read/write speed */
.drive{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr) 9.5em 7.5em 14.8em;gap:14px;align-items:center;padding:9px 0;font-variant-numeric:tabular-nums}
.drive+.drive{border-top:1px solid var(--border)}
.drive b{font-weight:600}
.drive .dname{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.drive .dname span{color:var(--muted);margin-left:6px}
.bar{height:10px;border-radius:5px;background:var(--grid);overflow:hidden}
.bar i{display:block;height:100%;background:var(--mem)}
.bar.warn i{background:var(--warn)} .bar.crit i{background:var(--bad)}
.dsize{text-align:right;white-space:nowrap}
.dhealth{text-align:right;white-space:nowrap;font-weight:600}
.dhealth.ok{color:var(--ok)} .dhealth.warn{color:var(--warn)} .dhealth.bad{color:var(--bad)} .dhealth.unknown{color:var(--muted);font-weight:400}
/* Read/write: two fixed-width cells so the column never shifts as numbers change */
.dio{display:flex;justify-content:flex-end;gap:10px;white-space:nowrap;color:var(--muted)}
.dio span{display:inline-block;width:6.9em;text-align:right}
.dio i{font-style:normal;opacity:.7;margin-right:.35em}
.dio .ioact{color:var(--text)} .dio .iobusy{color:var(--warn)} .dio .iohot{color:var(--bad)}
@media (max-width:700px){.drive{grid-template-columns:1fr auto;grid-template-areas:"name health" "bar bar" "size io";gap:6px 10px}
  .drive .dname{grid-area:name} .drive .bar{grid-area:bar} .drive .dsize{grid-area:size;text-align:left;color:var(--muted)} .drive .dhealth{grid-area:health} .drive .dio{grid-area:io}}
@media (max-width:700px){th,td{padding-left:5px;padding-right:5px}td{font-size:14px}}
/* Sound on/off for alerts (bell icons from Lucide) */
#sound{font:inherit;font-size:12.5px;color:var(--muted);background:none;border:1px solid var(--border);border-radius:999px;padding:1px 9px;margin-left:10px;cursor:pointer;display:inline-flex;align-items:center;gap:5px;white-space:nowrap}
#sound:hover,#sound[data-on="1"]{color:var(--text)}
#sound .ticon{width:13px;height:13px}
header{flex-wrap:wrap}
#sound .v-on,#sound[data-on="1"] .v-off{display:none}
#sound[data-on="1"] .v-on{display:block}
/* Alerts: banners that slide down from the top, newest first */
#toasts{position:fixed;top:0;left:50%;transform:translateX(-50%);width:min(460px,calc(100% - 32px));z-index:10;display:flex;flex-direction:column;gap:8px;padding-top:12px;pointer-events:none}
.toast{pointer-events:auto;display:flex;gap:10px;align-items:flex-start;background:var(--card);border:1px solid var(--border);border-radius:10px;padding:10px 12px;box-shadow:0 6px 24px rgba(0,0,0,.18);transform:translateY(-150%);opacity:0;transition:transform .35s ease,opacity .35s ease}
.toast.show{transform:none;opacity:1}
.toast .plogo{flex:none;margin:1px 0 0}
.toast div{flex:1;min-width:0}
.toast b{display:block;font-weight:600}
.toast small{display:block;color:var(--muted);font-size:12.5px}
.toast button{flex:none;font:inherit;font-size:20px;line-height:1;color:var(--muted);background:none;border:0;cursor:pointer;padding:0 2px}
.toast button:hover{color:var(--text)}
@media (prefers-reduced-motion:reduce){.toast{transform:none;transition:opacity .2s}}
</style>
</head>
<body>
<header><div><h1>SRRVRR</h1><span id="uptime"></span><span id="restart" hidden>Restart pending</span></div><div><span id="status">Connecting&hellip;</span><button id="sound" type="button" title="Play a soft ding with each alert"><svg class="ticon v-on" viewBox="0 0 24 24" aria-hidden="true"><path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/></svg><svg class="ticon v-off" viewBox="0 0 24 24" aria-hidden="true"><path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M17 17H4a1 1 0 0 1-.74-1.673C4.59 13.956 6 12.499 6 8a6 6 0 0 1 .258-1.742"/><path d="m2 2 20 20"/><path d="M8.668 3.01A6 6 0 0 1 18 8c0 2.687.77 4.653 1.707 6.05"/></svg><span>Sound off</span></button></div></header>
<div id="toasts" aria-live="polite"></div>
<main>
  <section class="card"><div class="top"><span class="label"><span id="cpuIcon" data-v=""><svg class="ticon v-generic" viewBox="0 0 24 24" aria-hidden="true"><rect width="16" height="16" x="4" y="4" rx="2"/><rect width="6" height="6" x="9" y="9" rx="1"/><path d="M15 2v2M15 20v2M2 15h2M2 9h2M20 15h2M20 9h2M9 2v2M9 20v2"/></svg><svg class="ticon brand v-amd" viewBox="106.4 0 33.32 33.33" aria-label="AMD"><polygon points="130.64 9.08 115.75 9.08 106.68 0 139.72 0 139.72 33.05 130.64 23.97 130.64 9.08"/><polygon points="115.74 23.98 115.74 10.9 106.4 20.24 106.4 33.33 119.48 33.33 128.82 23.98 115.74 23.98"/></svg><svg class="ticon brand v-intel" viewBox="4.7 2.2 357 150.4" aria-label="Intel"><rect x="4.7" y="5.2" width="28.1" height="28.1"/><path d="M32.1,151.6V50.3H5.4v101.2h26.7V151.6z M208.9,152.6v-24.8c-3.9,0-7.2-0.2-9.6-0.6c-2.8-0.4-4.9-1.4-6.3-2.8 c-1.4-1.4-2.3-3.4-2.8-6.1c-0.4-2.5-0.6-5.8-0.6-9.8V73.2h19.3V50.3h-19.3V10.9h-26.7v97.9c0,8.3,0.7,15.3,2.1,20.9 c1.4,5.5,3.8,10,7.1,13.4s7.7,5.8,13,7.3c5.4,1.5,12.2,2.2,20.3,2.2L208.9,152.6L208.9,152.6z M361.7,151.6V3.1H335v148.5H361.7z M137.2,60.3c-7.4-8-17.8-12-31-12c-6.4,0-12.3,1.3-17.5,3.9C83.4,54.8,79,58.4,75.4,63L74,64.9v-1.7V50.3H47.7v101.2h26.5V97.6v3.7 c0-0.6,0-1.2,0-1.8c0.3-9.5,2.6-16.5,7-21c4.7-4.8,10.4-7.2,16.9-7.2c7.7,0,13.6,2.4,17.5,7c3.8,4.6,5.8,11.1,5.8,19.4l0,0V98l0,0 l0,0v53.5h26.9V94.1C148.4,79.7,144.6,68.3,137.2,60.3z M321.2,100.8c0-7.3-1.3-14.1-3.8-20.5c-2.6-6.3-6.2-11.9-10.7-16.7 c-4.6-4.8-10.1-8.5-16.5-11.2s-13.5-4-21.2-4c-7.3,0-14.2,1.4-20.6,4.1c-6.4,2.8-12,6.5-16.7,11.2s-8.5,10.3-11.2,16.7 c-2.8,6.4-4.1,13.3-4.1,20.6c0,7.3,1.3,14.2,3.9,20.6c2.6,6.4,6.3,12,10.9,16.7c4.6,4.7,10.3,8.5,16.9,11.2 c6.6,2.8,13.9,4.2,21.7,4.2c22.6,0,36.6-10.3,45-19.9l-19.2-14.6c-4,4.8-13.6,11.3-25.6,11.3c-7.5,0-13.7-1.7-18.4-5.2 c-4.7-3.4-7.9-8.2-9.6-14.1l-0.3-0.9h79.5L321.2,100.8L321.2,100.8z M241.9,91.5c0-7.4,8.5-20.3,26.8-20.4 c18.3,0,26.9,12.9,26.9,20.3L241.9,91.5z"/></svg></span>CPU</span><span class="value"><span class="temp" id="cpuTemp"></span><span id="cpuV">&ndash;</span></span></div>
    <div class="sub" id="cpuS">&nbsp;</div><canvas id="cpuC"></canvas></section>
  <section class="card"><div class="top"><span class="label"><span id="memIcon" data-v=""><svg class="ticon v-generic" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 19v-3M10 19v-3M14 19v-3M18 19v-3M8 11V9M16 11V9M12 11V9M2 15h20"/><path d="M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v1.1a2 2 0 0 0 0 3.837V17a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-5.1a2 2 0 0 0 0-3.837Z"/></svg><i class="blogo" id="memLogo" aria-hidden="true"></i></span>Memory</span><span class="value"><span class="temp" id="memTemp"></span><span id="memV">&ndash;</span></span></div>
    <div class="sub" id="memS">&nbsp;</div><canvas id="memC"></canvas></section>
  <section class="card"><div class="top"><span class="label"><span id="gpuIcon" data-v=""><svg class="ticon v-generic" viewBox="0 0 24 24" aria-hidden="true"><path d="M2 21V3M2 5h18a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H2.26M7 17v3a1 1 0 0 0 1 1h5a1 1 0 0 0 1-1v-3"/><circle cx="16" cy="11" r="2"/><circle cx="8" cy="11" r="2"/></svg><svg class="ticon brand v-nvidia" viewBox="0 0 271.5 179.7" aria-label="NVIDIA"><path d="M101.3,53.6V37.4c1.6-0.1,3.2-0.2,4.8-0.2c44.4-1.4,73.5,38.2,73.5,38.2S148.2,119,114.5,119c-4.5,0-8.9-0.7-13.1-2.1V67.7c17.3,2.1,20.8,9.7,31.1,27l23.1-19.4c0,0-16.9-22.1-45.3-22.1C107.3,53.1,104.3,53.3,101.3,53.6 M101.3,0v24.2c1.6-0.1,3.2-0.2,4.8-0.3c61.7-2.1,102,50.6,102,50.6s-46.2,56.2-94.3,56.2c-4.2,0-8.3-0.4-12.4-1.1v15c3.4,0.4,6.9,0.7,10.3,0.7c44.8,0,77.2-22.9,108.6-49.9c5.2,4.2,26.5,14.3,30.9,18.7c-29.8,25-99.3,45.1-138.7,45.1c-3.8,0-7.4-0.2-11-0.6v21.1h170.2V0L101.3,0z M101.3,116.9v12.8c-41.4-7.4-52.9-50.5-52.9-50.5s19.9-22,52.9-25.6v14h-0.1c-17.3-2.1-30.9,14.1-30.9,14.1S78,109,101.3,116.9 M27.8,77.4c0,0,24.5-36.2,73.6-40V24.2C47,28.6,0,74.6,0,74.6s26.6,77,101.3,84v-14C46.5,137.8,27.8,77.4,27.8,77.4z"/></svg><svg class="ticon brand v-amd" viewBox="106.4 0 33.32 33.33" aria-label="AMD"><polygon points="130.64 9.08 115.75 9.08 106.68 0 139.72 0 139.72 33.05 130.64 23.97 130.64 9.08"/><polygon points="115.74 23.98 115.74 10.9 106.4 20.24 106.4 33.33 119.48 33.33 128.82 23.98 115.74 23.98"/></svg><svg class="ticon brand v-intel" viewBox="4.7 2.2 357 150.4" aria-label="Intel"><rect x="4.7" y="5.2" width="28.1" height="28.1"/><path d="M32.1,151.6V50.3H5.4v101.2h26.7V151.6z M208.9,152.6v-24.8c-3.9,0-7.2-0.2-9.6-0.6c-2.8-0.4-4.9-1.4-6.3-2.8 c-1.4-1.4-2.3-3.4-2.8-6.1c-0.4-2.5-0.6-5.8-0.6-9.8V73.2h19.3V50.3h-19.3V10.9h-26.7v97.9c0,8.3,0.7,15.3,2.1,20.9 c1.4,5.5,3.8,10,7.1,13.4s7.7,5.8,13,7.3c5.4,1.5,12.2,2.2,20.3,2.2L208.9,152.6L208.9,152.6z M361.7,151.6V3.1H335v148.5H361.7z M137.2,60.3c-7.4-8-17.8-12-31-12c-6.4,0-12.3,1.3-17.5,3.9C83.4,54.8,79,58.4,75.4,63L74,64.9v-1.7V50.3H47.7v101.2h26.5V97.6v3.7 c0-0.6,0-1.2,0-1.8c0.3-9.5,2.6-16.5,7-21c4.7-4.8,10.4-7.2,16.9-7.2c7.7,0,13.6,2.4,17.5,7c3.8,4.6,5.8,11.1,5.8,19.4l0,0V98l0,0 l0,0v53.5h26.9V94.1C148.4,79.7,144.6,68.3,137.2,60.3z M321.2,100.8c0-7.3-1.3-14.1-3.8-20.5c-2.6-6.3-6.2-11.9-10.7-16.7 c-4.6-4.8-10.1-8.5-16.5-11.2s-13.5-4-21.2-4c-7.3,0-14.2,1.4-20.6,4.1c-6.4,2.8-12,6.5-16.7,11.2s-8.5,10.3-11.2,16.7 c-2.8,6.4-4.1,13.3-4.1,20.6c0,7.3,1.3,14.2,3.9,20.6c2.6,6.4,6.3,12,10.9,16.7c4.6,4.7,10.3,8.5,16.9,11.2 c6.6,2.8,13.9,4.2,21.7,4.2c22.6,0,36.6-10.3,45-19.9l-19.2-14.6c-4,4.8-13.6,11.3-25.6,11.3c-7.5,0-13.7-1.7-18.4-5.2 c-4.7-3.4-7.9-8.2-9.6-14.1l-0.3-0.9h79.5L321.2,100.8L321.2,100.8z M241.9,91.5c0-7.4,8.5-20.3,26.8-20.4 c18.3,0,26.9,12.9,26.9,20.3L241.9,91.5z"/></svg></span>GPU</span><span class="value"><span class="temp" id="gpuTemp"></span><span id="gpuV">&ndash;</span></span></div>
    <div class="sub" id="gpuS">&nbsp;</div><canvas id="gpuC"></canvas></section>
  <section class="card"><div class="top"><span class="label"><svg class="ticon" viewBox="0 0 24 24" aria-hidden="true"><rect x="16" y="16" width="6" height="6" rx="1"/><rect x="2" y="16" width="6" height="6" rx="1"/><rect x="9" y="2" width="6" height="6" rx="1"/><path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3M12 12V8"/></svg>Network</span><span class="value" id="netV">&ndash;</span></div>
    <div class="sub" id="netS">&nbsp;</div><canvas id="netC"></canvas></section>
  <section class="card wide" id="procCard"><div class="label">Processes</div>
    <div class="scroll"><table>
      <colgroup><col style="width:24%"><col style="width:12%"><col style="width:12%"><col style="width:12%"><col style="width:20%"><col style="width:20%"></colgroup>
      <thead><tr><th>Process</th><th>CPU</th><th>Memory</th><th>GPU</th><th>Up</th><th>Down</th></tr></thead>
      <tbody id="procs"></tbody>
    </table></div>
    <div id="procNote" hidden></div></section>
  <section class="card wide" id="driveCard" hidden><div class="label"><svg class="ticon" viewBox="0 0 24 24" aria-hidden="true"><path d="M22 12H2M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11zM6 16h.01M10 16h.01"/></svg>Storage</div>
    <div id="drives"></div></section>
</main>
<script>
const N = 60, hist = {cpu: [], mem: [], gpu: [], rx: [], tx: []};
let lastTs = 0;
const $ = id => document.getElementById(id);
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const push = (a, v) => { a.push(v); if (a.length > N) a.shift(); };
const gb = b => (b / 1073741824).toFixed(1);
function bits(Bps) {
  const b = Bps * 8;
  if (b >= 1e9) return (b / 1e9).toFixed(2) + ' Gbps';
  if (b >= 1e6) return (b / 1e6).toFixed(1) + ' Mbps';
  if (b >= 1e3) return (b / 1e3).toFixed(0) + ' Kbps';
  return b.toFixed(0) + ' bps';
}
function niceMax(v) {               // round the network scale up to 1/2/5 x 10^n bits
  const b = Math.max(v * 8, 1e5), p = Math.pow(10, Math.floor(Math.log10(b)));
  for (const m of [1, 2, 5, 10]) if (b <= m * p) return m * p / 8;
}
function draw(id, series, max, scaleLabel) {
  const c = $(id), r = devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
  if (c.width !== w * r || c.height !== h * r) { c.width = w * r; c.height = h * r; }
  const g = c.getContext('2d');
  g.setTransform(r, 0, 0, r, 0, 0);
  g.clearRect(0, 0, w, h);
  g.strokeStyle = css('--grid'); g.lineWidth = 1;
  for (let i = 0; i <= 4; i++) { const y = Math.round((h - 1) * i / 4) + .5; g.beginPath(); g.moveTo(0, y); g.lineTo(w, y); g.stroke(); }
  for (const s of series) {
    const d = s.data; if (!d.length) continue;
    const x = i => w - (d.length - 1 - i) * w / (N - 1), y = v => h - 1 - Math.min(v / max, 1) * (h - 2);
    g.beginPath();
    d.forEach((v, i) => i ? g.lineTo(x(i), y(v)) : g.moveTo(x(i), y(v)));
    g.strokeStyle = s.color; g.lineWidth = 1.5; g.setLineDash(s.dash || []); g.stroke(); g.setLineDash([]);
    if (s.fill) { g.lineTo(x(d.length - 1), h); g.lineTo(x(0), h); g.closePath(); g.globalAlpha = .15; g.fillStyle = s.color; g.fill(); g.globalAlpha = 1; }
  }
  if (scaleLabel) { g.fillStyle = css('--muted'); g.font = '11px system-ui,sans-serif'; g.fillText(scaleLabel, 4, 12); }
}
function since(sec) {               // 273600 -> "3 days, 4 hours"
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  const unit = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
  return d ? unit(d, 'day') + ', ' + unit(h, 'hour') : h ? unit(h, 'hour') + ', ' + unit(m, 'minute') : unit(m, 'minute');
}
// A tile's temperature: amber from `warn`, red from `hot`. When temperatures can't be read,
// an amber "Temp n/a" with the reason on hover; a tile with no sensor (e.g. most DDR4) shows none.
function showTemp(id, t, warn, hot, error, each) {
  const el = $(id), deg = String.fromCharCode(176) + 'C';
  el.textContent = t != null ? Math.round(t) + deg : error ? 'Temp n/a' : '';
  el.className = 'temp' + (t != null ? (t >= hot ? ' hot' : t >= warn ? ' warn' : '') : error ? ' warn' : '');
  el.title = t == null && error ? 'Temperature unavailable: ' + error : (each || []).map(x => x.name + ': ' + x.t + deg).join('\n');
}
function render(s) {
  if (s.uptime != null) $('uptime').textContent = 'Up ' + since(s.uptime);
  showTemp('cpuTemp', s.cpuTemp, 80, 90, s.tempError, s.cpuTemps);       // CPU package: amber at 80, red at 90
  showTemp('memTemp', s.memTemp, 70, 80, s.tempError, s.memTemps);       // hottest stick: amber at 70, red at 80
  $('restart').hidden = !s.restartPending;
  $('restart').title = s.restartReason ? 'Waiting on: ' + s.restartReason : '';
  $('cpuV').textContent = s.cpu.toFixed(0) + '%';
  const dot = ' ' + String.fromCharCode(183) + ' ';
  $('cpuIcon').dataset.v = s.cpuVendor || '';
  $('cpuS').textContent = (s.cpuName ? s.cpuName + dot : '') + s.cores + ' logical processors';
  const memPct = 100 * s.memUsed / s.memTotal;
  $('memV').textContent = memPct.toFixed(0) + '%';
  $('memIcon').dataset.v = s.memVendor || '';
  $('memLogo').className = 'blogo' + (s.memVendor ? ' blogo-' + s.memVendor : '');
  $('memLogo').title = s.memLabel || '';
  $('memS').textContent = (s.memLabel ? s.memLabel + dot : '') + gb(s.memUsed) + ' / ' + gb(s.memTotal) + ' GB in use';
  // Hover: each stick's slot, maker, part number, size and the speed it runs at now.
  $('memS').title = (s.memSticks || []).map(m => m.slot + ': ' + [m.maker, m.part].filter(Boolean).join(' ') +
    ', ' + (m.size / 1073741824).toFixed(0) + ' GB' + (m.mts ? ', ' + m.mts + ' MT/s' : '')).join('\n');
  $('gpuIcon').dataset.v = s.gpuVendor || '';
  const t = s.gpuTemp;                // degrees C from nvidia-smi; amber at 80, red at 90
  $('gpuTemp').textContent = t == null ? '' : t + String.fromCharCode(176) + 'C';
  $('gpuTemp').className = 'temp' + (t >= 90 ? ' hot' : t >= 80 ? ' warn' : '');
  if (s.hasGpu) {
    $('gpuV').textContent = s.gpu.toFixed(0) + '%';
    $('gpuS').textContent = (s.gpuEngine ? s.gpuEngine.toUpperCase() + ' engine \u00b7 ' : '') + gb(s.gpuMem) + ' GB dedicated memory';
    const card = (s.gpuNote ? s.gpuNote + ', showing ' : '') + (s.gpuLabel || (s.gpuNote ? 'all GPUs' : ''));
    if (card) $('gpuS').textContent = card + ' ' + String.fromCharCode(183) + ' ' + $('gpuS').textContent;
  } else {
    $('gpuV').textContent = 'N/A';
    $('gpuS').textContent = 'No GPU counters on this machine';
  }
  $('netV').textContent = bits(s.rx + s.tx);
  $('netS').innerHTML = '<span class="key"><i style="background:var(--rx)"></i>Receive ' + bits(s.rx) +
    '</span><span class="key"><i style="background:var(--tx)"></i>Send ' + bits(s.tx) + '</span>';
  draw('cpuC', [{data: hist.cpu, color: css('--cpu'), fill: true}], 100);
  draw('memC', [{data: hist.mem, color: css('--mem'), fill: true}], 100);
  draw('gpuC', [{data: hist.gpu, color: css('--gpu'), fill: true}], 100);
  const netMax = niceMax(Math.max(...hist.rx, ...hist.tx, 0));
  draw('netC', [{data: hist.rx, color: css('--rx'), fill: true}, {data: hist.tx, color: css('--tx'), dash: [4, 3]}], netMax, bits(netMax));
  renderProcs(s);
  renderDrives(s);
  watchValheim(s);
  watchPlex(s);
}
function size(b) {                  // bytes -> "931 GB" / "7.3 TB", counted in 1024s like Windows does
  const TB = 1099511627776, GB = 1073741824;
  return b >= TB ? (b / TB).toFixed(1) + ' TB' : (b / GB).toFixed(0) + ' GB';
}
// Disk speeds are in bytes per second (the convention for storage; network speeds use bits).
function speed(b) {                 // bytes per second -> "0 B/s", "812 KB/s", "12.3 MB/s"
  const u = ['B/s', 'KB/s', 'MB/s', 'GB/s']; let i = 0;
  b = b || 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return (i && b < 100 ? b.toFixed(1) : b.toFixed(0)) + ' ' + u[i];
}
const ioPeak = {};                  // fastest speed seen per drive this session; raises the ceiling if needed
// One fixed-width cell: label, value, and a color for how close it is to the drive's ceiling.
function ioCell(label, b, ceiling) {
  const share = b / ceiling;
  const cls = share >= 0.9 ? 'iohot' : share >= 0.7 ? 'iobusy' : b > 0 ? 'ioact' : '';   // red at 90%, amber at 70%
  return '<span class="' + cls + '"><i>' + label + '</i>' + speed(b) + '</span>';
}
function ioCells(d, x) {
  if (!x) return '<div class="dio"></div>';
  ioPeak[d.letter] = Math.max(ioPeak[d.letter] || 0, x.r, x.w);
  const ceiling = Math.max(d.ceiling || 500e6, ioPeak[d.letter]);
  const hover = 'Read ' + speed(x.r) + ', write ' + speed(x.w) + '. Colors compare against about ' +
    Math.round(ceiling / 1e6) + ' MB/s, ' + (ceiling > (d.ceiling || 0) ? 'the fastest seen on this drive' :
    'typical for a ' + (d.kind || 'drive')) + ': amber at 70%, red at 90%.';
  return '<div class="dio" title="' + hover + '">' + ioCell('R', x.r, ceiling) + ioCell('W', x.w, ceiling) + '</div>';
}
function renderDrives(s) {
  const drives = s.drives || [], io = s.diskIO || {};
  $('driveCard').hidden = !drives.length;
  $('drives').innerHTML = drives.map(d => {
    const used = d.size - d.free, pct = d.size ? 100 * used / d.size : 0;
    const level = pct >= 95 ? 'crit' : pct >= 85 ? 'warn' : '';        // amber at 85% full, red at 95%
    const h = d.health || '', cls = h === 'Healthy' ? 'ok' : h === 'Warning' ? 'warn' : h === 'Unhealthy' ? 'bad' : 'unknown';
    const title = (d.disk ? d.disk + ': ' : '') + (h || 'health not reported');
    return '<div class="drive"><div class="dname"><b>' + d.letter + '</b><span>' + (d.label || 'Local Disk') + '</span></div>' +
      '<div class="bar ' + level + '"><i style="width:' + pct.toFixed(1) + '%"></i></div>' +
      '<div class="dsize">' + size(used) + ' / ' + size(d.size) + ' &middot; ' + pct.toFixed(0) + '%</div>' +
      '<div class="dhealth ' + cls + '" title="' + title + '">' + (h || 'Unknown') + '</div>' +
      ioCells(d, io[d.letter]) + '</div>';
  }).join('');
}
// Text from other programs (show titles, player names) is escaped before it goes into the page.
const esc = t => String(t == null ? '' : t).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
const plural = (n, w) => n + ' ' + w + (n === 1 ? '' : 's');
// One muted line under a running process: a short summary, details on hover.
function detail(p, a) {
  if (!a) return '';
  let text = '', hover = [];
  if (a.error) {
    // A running server that stops answering is a real problem (amber); setup differences stay quiet.
    text = (p.name === 'Valheim' ? 'Player count' : esc(p.name) + ' details') + ' unavailable (' + esc(a.error) + ')' +
      (p.name === 'Valheim' && p.coresUsed != null ? ' &middot; using ' + p.coresUsed.toFixed(1) + ' cores' : '');
    if (a.alert) text = '<span class="warn">' + text + '</span>';
  }
  else if (p.name === 'Valheim') {
    const slow = a.replyMs >= 250;      // a sluggish reply suggests the game loop is struggling
    text = (a.players ? plural(a.players, 'player') : 'No players') +
      ' &middot; ' + (slow ? '<span class="warn">' : '') + 'responding in ' + a.replyMs + ' ms' + (slow ? '</span>' : '') +
      (p.coresUsed != null ? ' &middot; using ' + p.coresUsed.toFixed(1) + ' cores' : '');
    hover = (a.names || []).map(n => n.name + ' (' + since(n.minutes * 60) + ')');
    if (a.players && !hover.length) hover = ['Player names not reported by the server'];
  }
  else if (p.name === 'Plex') {
    text = a.streams ? plural(a.streams, 'stream') + ' &middot; ' +
      (a.transcoding ? a.transcoding + ' transcoding' : 'direct play') : 'No one watching';
    hover = (a.items || []).map(i => i.user + ': ' + i.title + (plexDevice(i) ? ' on ' + plexDevice(i) : '') + ' (' + (i.playback || 'direct play') + ')');
  }
  if (!text) return '';
  return '<tr class="detail"><td colspan="6" title="' + hover.map(esc).join('&#10;') + '">' + text + '</td></tr>';
}
function renderProcs(s) {
  const pct = v => (v < 10 ? v.toFixed(1) : v.toFixed(0)) + '%';
  const rate = v => v == null ? 'n/a' : bits(v);
  const name = p => (p.icon ? '<i class="plogo plogo-' + p.icon + '"></i>' : '') + p.name;
  $('procs').innerHTML = (s.services || []).map(p => p.online
    ? '<tr><td>' + name(p) + '</td><td>' + pct(p.cpu) + '</td><td>' + pct(p.mem) + '</td><td>' +
      (s.hasGpu ? pct(p.gpu) : 'N/A') + '</td><td class="up">' + rate(p.tx) + '</td><td class="down">' + rate(p.rx) + '</td></tr>' +
      detail(p, (s.activity || {})[p.name])
    : '<tr><td>' + name(p) + '</td><td class="offline" colspan="5">Offline</td></tr>').join('');
  $('procCard').hidden = !(s.services || []).length;   // every process turned off in the config
  $('procNote').hidden = !s.netError;
  $('procNote').textContent = s.netError ? 'Per-process network unavailable: ' + s.netError + '.' : '';
}
// --- Alerts: a banner that slides down from the top, and a soft ding when sound is on.
// Browsers only play sound after someone has clicked or tapped the page, so the header
// button turns sound on (remembered in this browser), and after a reload one click
// anywhere on the page allows it again.
let audio = null, soundOn = false, lastDing = 0;
try { soundOn = localStorage.getItem('srrvrr.sound') === '1'; } catch (e) {}
const soundAllowed = () => !navigator.userActivation || navigator.userActivation.hasBeenActive;
function ding() {
  if (!soundOn || !soundAllowed() || Date.now() - lastDing < 500) return;   // several alerts at once: one ding
  lastDing = Date.now();
  try {
    audio = audio || new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === 'suspended') audio.resume();
    // One sine tone at 880 Hz that starts at once and fades out over about a second.
    const t = audio.currentTime, o = audio.createOscillator(), g = audio.createGain();
    o.type = 'sine'; o.frequency.value = 880;
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(0.15, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 1.1);
    o.connect(g); g.connect(audio.destination);
    o.start(t); o.stop(t + 1.2);
  } catch (e) {}
}
let armed = soundAllowed();          // false after a reload, until the page is clicked
function showSound() {
  $('sound').dataset.on = soundOn ? '1' : '';
  $('sound').lastChild.textContent = !soundOn ? 'Sound off' : armed ? 'Sound on' : 'Sound on: tap to allow';
}
$('sound').onclick = () => {
  if (!(soundOn && !armed)) {        // when sound is on but not yet allowed, this click only allows it
    soundOn = !soundOn;
    try { localStorage.setItem('srrvrr.sound', soundOn ? '1' : '0'); } catch (e) {}
  }
  armed = true; showSound(); ding(); // a sample ding
};
document.addEventListener('click', () => { if (!armed) { armed = true; showSound(); } });
showSound();
// A banner: title, a line or two of detail, and a close button. It closes by itself
// after 15 seconds of the page being on screen, so alerts that arrive in a background
// tab are still there when you come back.
function notify(icon, title, lines) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.innerHTML = (icon ? '<i class="plogo plogo-' + icon + '"></i>' : '') + '<div><b>' + esc(title) + '</b>' +
    lines.filter(Boolean).map(l => '<small>' + esc(l) + '</small>').join('') +
    '</div><button type="button" title="Dismiss" aria-label="Dismiss">&times;</button>';
  let left = 15;
  const timer = setInterval(() => { if (!document.hidden && --left <= 0) close(); }, 1000);
  function close() { clearInterval(timer); el.classList.remove('show'); setTimeout(() => el.remove(), 400); }
  el.lastChild.onclick = close;
  $('toasts').prepend(el);
  while ($('toasts').children.length > 4) $('toasts').lastChild.remove();
  requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add('show')));
  ding();
}
// Valheim: compare each new answer from the server (every 10 seconds) with the last one.
// The first answer after the page opens only sets the starting point, so nothing old
// pops up. Names are used when the server reports them.
let lastValheim = null;
function watchValheim(s) {
  const a = (s.activity || {}).Valheim;
  if (!a || a.error || a.players == null) return;
  const names = (a.names || []).map(n => n.name);
  if (lastValheim && a.players !== lastValheim.players) {
    const up = a.players > lastValheim.players, n = Math.abs(a.players - lastValheim.players);
    const who = up ? names.filter(x => !lastValheim.names.includes(x)) : lastValheim.names.filter(x => !names.includes(x));
    notify('valheim', (who.length ? who.join(', ') : n === 1 ? 'A player' : n + ' players') + (up ? ' joined' : ' left') + ' Valheim',
      [(a.players ? plural(a.players, 'player') : 'No players') + ' online']);
  }
  lastValheim = {players: a.players, names: names};
}
// Plex: a banner for each new stream, told apart by Plex's session ID, so pausing and
// resuming doesn't count. Says what, who, on which device, and how it's being played.
const plexDevice = i => !i.device ? i.app || '' : i.app && i.app !== i.device ? i.device + ' (' + i.app + ')' : i.device;
const plexRes = r => /^\d+$/.test(r || '') ? r + 'p' : r === '4k' ? '4K' : String(r || '').toUpperCase();
let plexKeys = null;
function watchPlex(s) {
  const a = (s.activity || {}).Plex;
  if (!a || a.error) return;
  const items = a.items || [];
  if (plexKeys) items.filter(i => i.key && !plexKeys.includes(i.key)).forEach(i => {
    const arrow = ' ' + String.fromCharCode(8594) + ' ';
    const how = i.playback === 'transcode'
      ? 'Transcoding ' + plexRes(i.source) + (i.target ? arrow + plexRes(i.target) : '') + (i.hardware ? ' on the GPU' : ' on the CPU')
      : (i.playback === 'direct stream' ? 'Direct stream' : 'Direct play') + (i.source ? ' ' + String.fromCharCode(183) + ' ' + plexRes(i.source) : '');
    const rate = i.kbps ? ' ' + String.fromCharCode(183) + ' ' + (i.kbps >= 1000 ? (i.kbps / 1000).toFixed(1) + ' Mbps' : i.kbps + ' Kbps') : '';
    notify('plex', 'Plex: ' + i.title, [(i.user || 'Someone') + (plexDevice(i) ? ' on ' + plexDevice(i) : ''), how + rate]);
  });
  plexKeys = items.map(i => i.key);
}
async function tick() {
  try {
    const s = await (await fetch('/stats', {cache: 'no-store'})).json();
    if (s.ready && s.ts !== lastTs) {
      lastTs = s.ts;
      push(hist.cpu, s.cpu); push(hist.mem, 100 * s.memUsed / s.memTotal); push(hist.gpu, s.gpu || 0);
      push(hist.rx, s.rx); push(hist.tx, s.tx);
      render(s);
    }
    $('status').className = s.error ? 'bad' : '';
    $('status').textContent = s.error ? 'Counter error: ' + s.error : (s.ready ? 'Live \u00b7 updates every second' : 'Starting\u2026');
  } catch (e) {
    $('status').className = 'bad';
    $('status').textContent = 'Disconnected, retrying\u2026';
  }
  setTimeout(tick, 500);
}
tick();
</script>
</body>
</html>
'@

# --- HTTP server --------------------------------------------------------------
Set-Step 'Setting up the Windows Firewall rule'
# Other PCs can only reach the page through the firewall, so the rule is always
# set up, and rebuilt on every start to match the current settings.
try {
    $firewallArgs = @{ Port = $settings.Port; Scope = $settings.FirewallScope; Addresses = $settings.FirewallAddresses }
    Invoke-Reported -Arguments $firewallArgs -Script {
        param($Port, $Scope, $Addresses)
        $rule = @{ Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $Port }
        # Also removes the rules from before the rename to SRRVRR ('System Monitor').
        Get-NetFirewallRule -DisplayName 'SRRVRR', 'SRRVRR (blocked)', 'System Monitor', 'System Monitor (blocked)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
        switch ($Scope) {
            'LocalSubnet' { New-NetFirewallRule -DisplayName 'SRRVRR' @rule -RemoteAddress LocalSubnet -Action Allow -ErrorAction Stop | Out-Null }
            'Allowlist'   { New-NetFirewallRule -DisplayName 'SRRVRR' @rule -RemoteAddress $Addresses -Action Allow -ErrorAction Stop | Out-Null }
            'Blocklist'   {
                # Local network, minus the listed addresses (Windows applies Block rules first).
                New-NetFirewallRule -DisplayName 'SRRVRR' @rule -RemoteAddress LocalSubnet -Action Allow -ErrorAction Stop | Out-Null
                New-NetFirewallRule -DisplayName 'SRRVRR (blocked)' @rule -RemoteAddress $Addresses -Action Block -ErrorAction Stop | Out-Null
            }
        }
    } | Out-Null
    $who = if ($settings.FirewallScope -in 'Allowlist', 'Blocklist') { "$($settings.FirewallScope): $($settings.FirewallAddresses -join ', ')" } else { $settings.FirewallScope }
    Write-Status "Firewall: port $($settings.Port) open ($who)."
} catch {
    Write-Status -Warning "Could not update the firewall rule (needs administrator): $($_.Exception.Message)"
}

Set-Step 'Starting the web page server'
# Listens on every address this machine has: its network IP, its name and localhost.
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$($settings.Port)/")
try {
    $listener.Start()
    $url = "http://$($env:COMPUTERNAME):$($settings.Port)"
    # Also show the network IP (of the adapter with the default route), which works even where names don't.
    try {
        $ip = Invoke-Reported -Script {
            $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
            (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1).IPAddress
        } | Select-Object -First 1
        if ($ip) { $url += "  or  http://${ip}:$($settings.Port)" }
    } catch { }
} catch {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$($settings.Port)/")
    $listener.Start()
    $url = "http://localhost:$($settings.Port)"
    Write-Status -Warning 'Not running as administrator, so only this machine can open the page.'
}

# A nod to SimCity 2000 and The Sims, whose loading screens famously did this too.
Set-Step 'Reticulating Splines...'
Stop-StartupSpinner
Write-Host "SRRVRR running at $url"

# A spinner on the last console line shows the monitor is alive. Skipped when
# output goes to a file instead of a console window.
$spinner = -not [Console]::IsOutputRedirected
$spinFrames = '|', '\', '-', '/'
$spinFrame = 0
$lastSpin = [DateTime]::MinValue
function Show-Spinner {
    if (-not $spinner) { return }
    $now = [DateTime]::UtcNow
    if (($now - $script:lastSpin).TotalMilliseconds -lt 150) { return }
    $script:lastSpin = $now
    [Console]::Write("`r  $($spinFrames[$script:spinFrame++ % 4])  Running... press Ctrl+C to stop ")
}
if ($spinner) { try { [Console]::CursorVisible = $false } catch { } }

function Send-Response($ctx, [string]$body, [string]$type) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $ctx.Response.ContentType = $type
    $ctx.Response.Headers['Cache-Control'] = 'no-store'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

try {
    while ($listener.IsListening) {
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(50)) { Show-Spinner }   # short waits keep Ctrl+C responsive
        Show-Spinner
        $ctx = $listener.EndGetContext($pending)
        try {
            if ($ctx.Request.Url.AbsolutePath -eq '/stats') {
                $snapshot = @{}
                foreach ($k in @($state.Keys)) { $snapshot[$k] = $state[$k] }
                $snapshot.uptime = [int]((Get-Date) - $bootTime).TotalSeconds
                Send-Response $ctx ($snapshot | ConvertTo-Json -Compress -Depth 6) 'application/json; charset=utf-8'
            } else {
                Send-Response $ctx $html 'text/html; charset=utf-8'
            }
        } catch { }   # browser went away mid-response
    }
} finally {
    if ($spinner) { [Console]::WriteLine("`r  Stopped.                                "); try { [Console]::CursorVisible = $true } catch { } }
    $listener.Stop()
    if ($netPerProcess) { [ProcessNetTrace]::Stop() }
    $worker.Stop()
    $runspace.Close()
    $slowWorker.Stop()
    $slowRunspace.Close()
}
