<#
  SystemMonitor.ps1 - a tiny live CPU / memory / GPU / network monitor.

  Run it on the machine you want to watch, then open http://<that-machine>:8099
  in any browser. Press Ctrl+C in this window to stop it.

  Run as administrator so other PCs can open the page. Add -OpenFirewall once
  to allow the port through Windows Firewall (local network only).
#>
param(
    [int]$Port = 8099,
    [switch]$OpenFirewall
)

$ErrorActionPreference = 'Stop'

# --- GPU to watch -------------------------------------------------------------
# Part of the graphics card's name as shown in Device Manager > Display adapters.
# Only that card is counted on the GPU tile and in the table, so integrated
# graphics are ignored. Set to '' to count every GPU.
$gpuName = 'T600'

# --- Processes shown in the table under the graphs ----------------------------
# name:  label on the page
# main:  process that must be running for the row to show as online
# match: every process counted toward the row (wildcards allowed)
$services = @(
    @{ name = 'Valheim'; main = 'valheim_server';    match = 'valheim_server' }
    @{ name = 'Plex';    main = 'Plex Media Server'; match = 'Plex*' }   # includes Plex Transcoder etc.
)

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
# (LUID) the GPU counters use, which lets us pick out the card by name.
$gpuLuid = $null; $gpuLabel = $null
if ($hasGpu -and $gpuName) {
    $live = (New-Object System.Diagnostics.PerformanceCounterCategory 'GPU Adapter Memory').GetInstanceNames()
    foreach ($key in Get-ChildItem HKLM:\SOFTWARE\Microsoft\DirectX -ErrorAction SilentlyContinue) {
        $adapter = Get-ItemProperty $key.PSPath
        if ($adapter.Description -notlike "*$gpuName*" -or $null -eq $adapter.AdapterLuid) { continue }
        $l = [int64]$adapter.AdapterLuid
        $luid = '0x{0:x8}_0x{1:x8}' -f ($l -shr 32), ($l -band 4294967295)
        if ($live | Where-Object { $_ -like "luid_${luid}_*" }) { $gpuLuid = $luid; $gpuLabel = $adapter.Description; break }
    }
    if (-not $gpuLuid) { Write-Warning "No GPU matching '$gpuName' found; counting all GPUs." }
}

$totalRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$state = [hashtable]::Synchronized(@{
    ready = $false
    host  = $env:COMPUTERNAME
    cores = [int]$env:NUMBER_OF_PROCESSORS
    memTotal = $totalRam
    hasGpu = $hasGpu
    gpuLabel = $gpuLabel
    gpuMissing = if ($hasGpu -and $gpuName -and -not $gpuLuid) { $gpuName } else { $null }
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
                        $rows += @{ name = $svc.name; online = $false }
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
.label{font-weight:600}
.value{font-size:26px;font-weight:600;font-variant-numeric:tabular-nums;white-space:nowrap}
.sub{color:var(--muted);font-size:12.5px;min-height:18px;font-variant-numeric:tabular-nums}
canvas{display:block;width:100%;height:120px;margin-top:8px}
.key{display:inline-flex;align-items:center;gap:5px;margin-right:12px}
.key i{width:10px;height:3px;border-radius:2px;display:inline-block}
.wide{grid-column:1/-1}
.scroll{overflow-x:auto}
table{width:100%;border-collapse:collapse;margin-top:6px;font-variant-numeric:tabular-nums}
th{color:var(--muted);font-weight:500;font-size:12.5px;text-align:right;padding:6px 10px;border-bottom:1px solid var(--border);white-space:nowrap}
td{text-align:right;padding:9px 10px;font-size:15px;white-space:nowrap}
tr+tr td{border-top:1px solid var(--border)}
th:first-child,td:first-child{text-align:left;padding-left:0;font-weight:600}
td.offline{text-align:left;color:var(--muted)}
td.up{color:var(--tx)} td.down{color:var(--rx)}
#procNote{color:var(--muted);font-size:12.5px;margin-top:6px}
@media (max-width:700px){th,td{padding-left:5px;padding-right:5px}td{font-size:14px}}
</style>
</head>
<body>
<header><h1 id="host">System Monitor</h1><span id="status">Connecting&hellip;</span></header>
<main>
  <section class="card"><div class="top"><span class="label">CPU</span><span class="value" id="cpuV">&ndash;</span></div>
    <div class="sub" id="cpuS">&nbsp;</div><canvas id="cpuC"></canvas></section>
  <section class="card"><div class="top"><span class="label">Memory</span><span class="value" id="memV">&ndash;</span></div>
    <div class="sub" id="memS">&nbsp;</div><canvas id="memC"></canvas></section>
  <section class="card"><div class="top"><span class="label">GPU</span><span class="value" id="gpuV">&ndash;</span></div>
    <div class="sub" id="gpuS">&nbsp;</div><canvas id="gpuC"></canvas></section>
  <section class="card"><div class="top"><span class="label">Network</span><span class="value" id="netV">&ndash;</span></div>
    <div class="sub" id="netS">&nbsp;</div><canvas id="netC"></canvas></section>
  <section class="card wide"><div class="label">Processes</div>
    <div class="scroll"><table>
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
    const card = s.gpuLabel || (s.gpuMissing ? s.gpuMissing + ' not found, showing all GPUs' : '');
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
  $('procs').innerHTML = (s.services || []).map(p => p.online
    ? '<tr><td>' + p.name + '</td><td>' + pct(p.cpu) + '</td><td>' + pct(p.mem) + '</td><td>' +
      (s.hasGpu ? pct(p.gpu) : 'N/A') + '</td><td class="up">' + rate(p.tx) + '</td><td class="down">' + rate(p.rx) + '</td></tr>'
    : '<tr><td>' + p.name + '</td><td class="offline" colspan="5">Offline</td></tr>').join('');
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
if ($OpenFirewall -and -not (Get-NetFirewallRule -DisplayName 'System Monitor' -ErrorAction SilentlyContinue)) {
    try {
        New-NetFirewallRule -DisplayName 'System Monitor' -Direction Inbound -Protocol TCP -LocalPort $Port `
            -RemoteAddress LocalSubnet -Action Allow | Out-Null
        Write-Host "Firewall rule 'System Monitor' added for port $Port (local network only)."
    } catch {
        Write-Warning 'Could not add the firewall rule (needs administrator).'
    }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$Port/")
try {
    $listener.Start()
    $url = "http://$($env:COMPUTERNAME):$Port"
} catch {
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$Port/")
    $listener.Start()
    $url = "http://localhost:$Port"
    Write-Warning 'Not running as administrator, so only this machine can open the page.'
}
Write-Host "System Monitor running at $url  (Ctrl+C to stop)"

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
        while (-not $pending.AsyncWaitHandle.WaitOne(250)) { }   # short waits keep Ctrl+C responsive
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
    $listener.Stop()
    if ($netPerProcess) { [ProcessNetTrace]::Stop() }
    $worker.Stop()
    $runspace.Close()
}
