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
# Defaults, replaced by anything set in SRRVRR.config.psd1. That file is not part of the code (see .gitignore),
# so updates never overwrite it. Loading and validation are in modules\Settings.psm1.
Import-Module -Name (Join-Path $PSScriptRoot 'modules\Settings.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'modules\Web.psm1') -Force
$loaded = if ($PSBoundParameters.ContainsKey('Port')) { Import-SrrSettings -Folder $PSScriptRoot -Port $Port } else { Import-SrrSettings -Folder $PSScriptRoot }
foreach ($n in $loaded.Notes) { if ($n.Level -eq 'Warning') { Write-Status -Warning $n.Text } else { Write-Status $n.Text } }
$settings = $loaded.Settings

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
    tickMs = $null   # the fast sampler's own time per reading, once it has one
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
# since the previous read. The math is in modules\Counters.psm1.
$sampler = {
    param($state, $categories, $cpuCounter, $totalRam, $services, $netPerProcess, $gpuLuid, $modulePath)
    # The module is loaded here, by full path, so a missing or broken file shows on the page instead of leaving
    # it on "Starting..." with no reason.
    try { Import-Module -Name $modulePath -Force -ErrorAction Stop }
    catch { $state.error = "Couldn't load modules\Counters.psm1: $($_.Exception.Message)"; return }
    $cats = @{}
    foreach ($n in $categories) { $cats[$n] = New-Object System.Diagnostics.PerformanceCounterCategory $n }
    $reader = { $s = @{}; foreach ($n in $cats.Keys) { $s[$n] = $cats[$n].ReadCategory() }; $s }.GetNewClosure()
    $tracer = { if ($netPerProcess) { [ProcessNetTrace]::Drain() } else { $null } }.GetNewClosure()
    $ctx = New-FastTickContext -Reader $reader -Processes { Get-Process } -Tracer $tracer -Services $services `
        -TotalRam $totalRam -GpuLuid $gpuLuid -Cores ([Environment]::ProcessorCount) -CpuCounter $cpuCounter `
        -TickStopwatch (New-Object System.Diagnostics.Stopwatch) -IntervalStopwatch ([System.Diagnostics.Stopwatch]::StartNew())
    $prev = $null
    while ($true) {
        $started = [DateTime]::UtcNow
        $prev = Invoke-FastTick -State $state -Context $ctx -Previous $prev -Now ([DateTimeOffset]::Now)
        $wait = 1000 - ([DateTime]::UtcNow - $started).TotalMilliseconds
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}

Set-Step 'Starting the background samplers'
# Each runspace imports SRRVRR's own modules by full path, never by name (at the top of its script).
$samplerSession = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$samplerSession.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
$runspace = [runspacefactory]::CreateRunspace($samplerSession)
$runspace.Open()
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void]$worker.AddScript($sampler).AddArgument($state).AddArgument($categories).AddArgument($cpuCounter).AddArgument($totalRam).AddArgument($services).AddArgument($netPerProcess).AddArgument($gpuLuid).AddArgument((Join-Path $PSScriptRoot 'modules\Counters.psm1'))
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
# The page itself is in web\ (index.html, app.js, style.css, img\), read from disk on every request.

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

# A request whose Host names anything but this machine is refused (Get-HostIdentity, modules\Web.psm1).
$webContext = @{
    State    = $state
    WebRoot  = Join-Path $PSScriptRoot 'web'
    Identity = Get-HostIdentity
    BootTime = [DateTimeOffset]$bootTime
    Clock    = { [DateTimeOffset]::Now }
    LogError = { param($message) [Console]::WriteLine(''); Write-Host "  $message" -ForegroundColor Yellow }
}
$identityRead = [DateTime]::UtcNow

try {
    while ($listener.IsListening) {
        $pending = $listener.BeginGetContext($null, $null)
        while (-not $pending.AsyncWaitHandle.WaitOne(50)) { Show-Spinner }   # short waits keep Ctrl+C responsive
        Show-Spinner
        $ctx = $listener.EndGetContext($pending)
        # Addresses can change (a new DHCP lease), so the allowlist is rebuilt once a minute.
        if (([DateTime]::UtcNow - $identityRead).TotalSeconds -ge 60) {
            try { $webContext.Identity = Get-HostIdentity } catch { }
            $identityRead = [DateTime]::UtcNow
        }
        Invoke-SrrRequest -ListenerContext $ctx -Context $webContext
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
