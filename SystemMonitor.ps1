<#
  SystemMonitor.ps1 - a tiny live CPU / memory / GPU / network monitor.

  Run it on the machine you want to watch, then open http://<that-machine>:8099
  in any browser. Press Ctrl+C in this window to stop it.

  Settings (port, listen address, firewall, GPU, processes) live in
  SystemMonitor.config.psd1 next to this script; copy
  SystemMonitor.config.example.psd1 to create it. Run as administrator so other
  PCs can open the page and the firewall rule can be managed.
#>
param(
    [int]$Port,              # overrides Port from the config file
    [switch]$OpenFirewall    # overrides OpenFirewall from the config file
)

$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------
# Defaults, replaced by anything set in SystemMonitor.config.psd1. That file is
# not part of the code (see .gitignore), so updates never overwrite it.
$settings = @{
    Port              = 8099
    ListenAddress     = '+'
    OpenFirewall      = $true
    FirewallScope     = 'LocalSubnet'
    FirewallAddresses = @()
    AllowPublicAddresses = $false
    PreferredGpu      = ''
    GpuFallback       = 'Dedicated'
    Processes         = @{}
}
$configPath = Join-Path $PSScriptRoot 'SystemMonitor.config.psd1'
if (Test-Path -LiteralPath $configPath) {
    $config = Import-PowerShellDataFile -LiteralPath $configPath
    foreach ($k in $config.Keys) {
        if ($settings.ContainsKey($k)) { $settings[$k] = $config[$k] }
        else { Write-Warning "Unknown setting '$k' in $configPath (ignored)." }
    }
    Write-Host "Settings loaded from $configPath"
} else {
    Write-Host 'No SystemMonitor.config.psd1 found, using default settings. Copy SystemMonitor.config.example.psd1 to SystemMonitor.config.psd1 to change them.'
}
if ($PSBoundParameters.ContainsKey('Port')) { $settings.Port = $Port }
if ($OpenFirewall) { $settings.OpenFirewall = $true }

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
    Write-Warning ("SECURITY: AllowPublicAddresses is on. The firewall will let these INTERNET addresses open the page, " +
        "which has no password and no encryption: $($public -join ', '). You accept this risk; see the README security warning.")
}
$fallbacks = 'Dedicated', 'Integrated', 'All'
if ($settings.GpuFallback -notin $fallbacks) { throw "GpuFallback must be one of: $($fallbacks -join ', ')" }

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
if ($cat::CounterExists('Working Set - Private', 'Process')) { $categories += 'Process' }   # per-process memory, as Task Manager counts it

# Windows lists each graphics card under this registry key with the same ID
# (LUID) the GPU counters use, which lets us pick out one card.
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
        $gpus[$luid] = [pscustomobject]@{ Name = $adapter.Description; Luid = $luid; Dedicated = [int64]$adapter.DedicatedVideoMemory }
    }
}
$gpu = $null; $gpuNote = $null
if ($settings.PreferredGpu) {
    $gpu = $gpus.Values | Where-Object { $_.Name -like "*$($settings.PreferredGpu)*" } | Select-Object -First 1
    if (-not $gpu) { $gpuNote = "$($settings.PreferredGpu) not found"; Write-Warning "No GPU matching '$($settings.PreferredGpu)'; using GpuFallback '$($settings.GpuFallback)'." }
}
if (-not $gpu -and $gpus.Count) {
    # A graphics card has far more dedicated video memory than built-in graphics.
    if ($settings.GpuFallback -eq 'Dedicated')  { $gpu = $gpus.Values | Sort-Object Dedicated -Descending | Select-Object -First 1 }
    if ($settings.GpuFallback -eq 'Integrated') { $gpu = $gpus.Values | Sort-Object Dedicated | Select-Object -First 1 }
}
$gpuLuid = if ($gpu) { $gpu.Luid } else { $null }
$gpuLabel = if ($gpu) { $gpu.Name } else { $null }

$totalRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$state = [hashtable]::Synchronized(@{
    ready = $false
    host  = $env:COMPUTERNAME
    cores = [int]$env:NUMBER_OF_PROCESSORS
    memTotal = $totalRam
    hasGpu = $hasGpu
    gpuLabel = $gpuLabel
    gpuNote = $gpuNote
})

# --- Per-process network ------------------------------------------------------
# Windows has no per-process network counter, so this listens to the kernel's
# network events (the same source Resource Monitor uses) and adds up bytes per
# process ID. Needs administrator.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class ProcessNetTrace {
    const string SessionName = "SystemMonitorNet";
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

    public static void Stop() {
        IntPtr p = NewProperties();
        ControlTraceW(0, SessionName, p, 1);     // EVENT_TRACE_CONTROL_STOP
        Marshal.FreeHGlobal(p);
    }

    public static bool Start() {
        if (IntPtr.Size != 8) { Error = "needs 64-bit PowerShell"; return false; }
        Stop();                                  // clear a session left behind by an earlier run
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

$runspace = [runspacefactory]::CreateRunspace()
$runspace.Open()
$worker = [powershell]::Create()
$worker.Runspace = $runspace
[void]$worker.AddScript($sampler).AddArgument($state).AddArgument($categories).AddArgument($cpuCounter).AddArgument($totalRam).AddArgument($services).AddArgument($netPerProcess).AddArgument($gpuLuid)
[void]$worker.BeginInvoke()

# --- Web page -----------------------------------------------------------------
$html = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>System Monitor</title>
<style>
:root{--bg:#f4f5f7;--card:#fff;--text:#1b1f24;--muted:#667080;--grid:rgba(0,0,0,.07);--border:#e2e5e9;
  --cpu:#1f7ae0;--mem:#8e44c9;--gpu:#139068;--rx:#d9661f;--tx:#c2185b;--bad:#d33}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--card:#1b1e23;--text:#e8eaed;--muted:#9aa3ad;--grid:rgba(255,255,255,.07);--border:#2a2f36;
  --cpu:#4c9bff;--mem:#b67cf0;--gpu:#3ccf98;--rx:#ff9a52;--tx:#f2669a;--bad:#ff6b6b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:14px/1.4 system-ui,"Segoe UI",sans-serif}
header{display:flex;align-items:baseline;justify-content:space-between;gap:12px;max-width:1100px;margin:0 auto;padding:20px 24px 0}
h1{font-size:18px;margin:0;font-weight:600}
#status{color:var(--muted);font-size:13px}
#status.bad{color:var(--bad)}
main{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:16px;max-width:1100px;margin:0 auto;padding:16px 24px 24px}
@media (max-width:700px){header{padding:16px 16px 0}main{grid-template-columns:1fr;padding:12px 16px 16px}}
.card{background:var(--card);border:1px solid var(--border);border-radius:10px;padding:14px 16px 12px;min-width:0}
.top{display:flex;justify-content:space-between;align-items:baseline;gap:8px}
.label{font-weight:600;font-size:22px;display:inline-flex;align-items:center;gap:8px}   /* ~85% of the 26px metric */
/* Tile icons: CPU, memory and network from Lucide (lucide.dev, ISC license); NVIDIA eye mark from nvidia.com */
.ticon{height:1em;width:1em;flex:none;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.ticon.brand{width:auto;fill:currentColor;stroke:none}
.value{font-size:26px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap}
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
td.up{color:var(--tx)} td.down{color:var(--rx)}
#procNote{color:var(--muted);font-size:12.5px;margin-top:6px}
@media (max-width:700px){th,td{padding-left:5px;padding-right:5px}td{font-size:14px}}
</style>
</head>
<body>
<header><h1 id="host">System Monitor</h1><span id="status">Connecting&hellip;</span></header>
<main>
  <section class="card"><div class="top"><span class="label"><svg class="ticon" viewBox="0 0 24 24" aria-hidden="true"><rect width="16" height="16" x="4" y="4" rx="2"/><rect width="6" height="6" x="9" y="9" rx="1"/><path d="M15 2v2M15 20v2M2 15h2M2 9h2M20 15h2M20 9h2M9 2v2M9 20v2"/></svg>CPU</span><span class="value" id="cpuV">&ndash;</span></div>
    <div class="sub" id="cpuS">&nbsp;</div><canvas id="cpuC"></canvas></section>
  <section class="card"><div class="top"><span class="label"><svg class="ticon" viewBox="0 0 24 24" aria-hidden="true"><path d="M6 19v-3M10 19v-3M14 19v-3M18 19v-3M8 11V9M16 11V9M12 11V9M2 15h20"/><path d="M2 7a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v1.1a2 2 0 0 0 0 3.837V17a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-5.1a2 2 0 0 0 0-3.837Z"/></svg>Memory</span><span class="value" id="memV">&ndash;</span></div>
    <div class="sub" id="memS">&nbsp;</div><canvas id="memC"></canvas></section>
  <section class="card"><div class="top"><span class="label"><svg class="ticon brand" viewBox="0 0 271.5 179.7" aria-label="NVIDIA"><path d="M101.3,53.6V37.4c1.6-0.1,3.2-0.2,4.8-0.2c44.4-1.4,73.5,38.2,73.5,38.2S148.2,119,114.5,119c-4.5,0-8.9-0.7-13.1-2.1V67.7c17.3,2.1,20.8,9.7,31.1,27l23.1-19.4c0,0-16.9-22.1-45.3-22.1C107.3,53.1,104.3,53.3,101.3,53.6 M101.3,0v24.2c1.6-0.1,3.2-0.2,4.8-0.3c61.7-2.1,102,50.6,102,50.6s-46.2,56.2-94.3,56.2c-4.2,0-8.3-0.4-12.4-1.1v15c3.4,0.4,6.9,0.7,10.3,0.7c44.8,0,77.2-22.9,108.6-49.9c5.2,4.2,26.5,14.3,30.9,18.7c-29.8,25-99.3,45.1-138.7,45.1c-3.8,0-7.4-0.2-11-0.6v21.1h170.2V0L101.3,0z M101.3,116.9v12.8c-41.4-7.4-52.9-50.5-52.9-50.5s19.9-22,52.9-25.6v14h-0.1c-17.3-2.1-30.9,14.1-30.9,14.1S78,109,101.3,116.9 M27.8,77.4c0,0,24.5-36.2,73.6-40V24.2C47,28.6,0,74.6,0,74.6s26.6,77,101.3,84v-14C46.5,137.8,27.8,77.4,27.8,77.4z"/></svg>GPU</span><span class="value" id="gpuV">&ndash;</span></div>
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
function render(s) {
  document.title = s.host + ' \u00b7 System Monitor';
  $('host').textContent = s.host;
  $('cpuV').textContent = s.cpu.toFixed(0) + '%';
  $('cpuS').textContent = s.cores + ' logical processors';
  const memPct = 100 * s.memUsed / s.memTotal;
  $('memV').textContent = memPct.toFixed(0) + '%';
  $('memS').textContent = gb(s.memUsed) + ' / ' + gb(s.memTotal) + ' GB in use';
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
}
function renderProcs(s) {
  const pct = v => (v < 10 ? v.toFixed(1) : v.toFixed(0)) + '%';
  const rate = v => v == null ? 'n/a' : bits(v);
  const name = p => (p.icon ? '<i class="plogo plogo-' + p.icon + '"></i>' : '') + p.name;
  $('procs').innerHTML = (s.services || []).map(p => p.online
    ? '<tr><td>' + name(p) + '</td><td>' + pct(p.cpu) + '</td><td>' + pct(p.mem) + '</td><td>' +
      (s.hasGpu ? pct(p.gpu) : 'N/A') + '</td><td class="up">' + rate(p.tx) + '</td><td class="down">' + rate(p.rx) + '</td></tr>'
    : '<tr><td>' + name(p) + '</td><td class="offline" colspan="5">Offline</td></tr>').join('');
  $('procCard').hidden = !(s.services || []).length;   // every process turned off in the config
  $('procNote').hidden = !s.netError;
  $('procNote').textContent = s.netError ? 'Per-process network unavailable: ' + s.netError + '.' : '';
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
# Rebuilt on every start so the rules always match the current settings.
if ($settings.OpenFirewall) {
    try {
        $rule = @{ Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $settings.Port }
        Get-NetFirewallRule -DisplayName 'System Monitor', 'System Monitor (blocked)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction Stop
        switch ($settings.FirewallScope) {
            'LocalSubnet' { New-NetFirewallRule -DisplayName 'System Monitor' @rule -RemoteAddress LocalSubnet -Action Allow -ErrorAction Stop | Out-Null }
            'Allowlist'   { New-NetFirewallRule -DisplayName 'System Monitor' @rule -RemoteAddress $settings.FirewallAddresses -Action Allow -ErrorAction Stop | Out-Null }
            'Blocklist'   {
                # Local network, minus the listed addresses (Windows applies Block rules first).
                New-NetFirewallRule -DisplayName 'System Monitor' @rule -RemoteAddress LocalSubnet -Action Allow -ErrorAction Stop | Out-Null
                New-NetFirewallRule -DisplayName 'System Monitor (blocked)' @rule -RemoteAddress $settings.FirewallAddresses -Action Block -ErrorAction Stop | Out-Null
            }
        }
        $who = if ($settings.FirewallScope -in 'Allowlist', 'Blocklist') { "$($settings.FirewallScope): $($settings.FirewallAddresses -join ', ')" } else { $settings.FirewallScope }
        Write-Host "Firewall: port $($settings.Port) open ($who)."
    } catch {
        Write-Warning "Could not update the firewall rule (needs administrator): $($_.Exception.Message)"
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://$($settings.ListenAddress):$($settings.Port)/")
try {
    $listener.Start()
    $shownAddress = if ($settings.ListenAddress -eq '+') { $env:COMPUTERNAME } else { $settings.ListenAddress }
    $url = "http://${shownAddress}:$($settings.Port)"
} catch {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$($settings.Port)/")
    $listener.Start()
    $url = "http://localhost:$($settings.Port)"
    Write-Warning "Could not listen on '$($settings.ListenAddress)' (needs administrator, or the address isn't on this machine), so only this machine can open the page."
}
Write-Host "System Monitor running at $url"

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
                Send-Response $ctx ($snapshot | ConvertTo-Json -Compress) 'application/json'
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
}
