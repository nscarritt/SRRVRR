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

$totalRam = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
$state = [hashtable]::Synchronized(@{
    ready = $false
    host  = $env:COMPUTERNAME
    cores = [int]$env:NUMBER_OF_PROCESSORS
    memTotal = $totalRam
    hasGpu = $hasGpu
})

# --- Background sampler: one reading per second -------------------------------
# Reads whole counter categories at once (much faster than Get-Counter when there
# are hundreds of GPU engine instances) and works out each value from the change
# since the previous read.
$sampler = {
    param($state, $categories, $cpuCounter, $totalRam)
    $cats = @{}
    foreach ($n in $categories) { $cats[$n] = New-Object System.Diagnostics.PerformanceCounterCategory $n }
    $prev = $null

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

            if ($prev) {
                $cpu = 0
                $cpuValues = Get-Values $cpuCounter[0] $cpuCounter[1]
                foreach ($k in $cpuValues.Keys) { if ($k -eq '_Total') { $cpu = $cpuValues[$k] } }

                # Like Task Manager: add up every process on each engine, then report the busiest engine.
                $engines = @{}
                $util = Get-Values 'GPU Engine' 'Utilization Percentage'
                foreach ($k in $util.Keys) {
                    if ($k -match 'luid_(\w+?_\w+?)_phys_(\d+)_eng_(\d+)_engtype_(.*)$') {
                        $key = "$($matches[1])|$($matches[2])|$($matches[3])"
                        if (-not $engines.ContainsKey($key)) { $engines[$key] = @{ v = 0.0; t = $matches[4] } }
                        $engines[$key].v += $util[$k]
                    }
                }
                $gpu = 0; $gpuEngine = ''
                foreach ($e in $engines.Values) { if ($e.v -gt $gpu) { $gpu = $e.v; $gpuEngine = $e.t } }

                $state.cpu = [math]::Round([math]::Min(100, $cpu), 1)
                $state.memUsed = $totalRam - (Get-Sum (Get-Values 'Memory' 'Available Bytes'))
                $state.rx = [math]::Round((Get-Sum (Get-Values 'Network Interface' 'Bytes Received/sec')))
                $state.tx = [math]::Round((Get-Sum (Get-Values 'Network Interface' 'Bytes Sent/sec')))
                $state.gpu = [math]::Round([math]::Min(100, $gpu), 1)
                $state.gpuEngine = $gpuEngine
                $state.gpuMem = Get-Sum (Get-Values 'GPU Adapter Memory' 'Dedicated Usage')
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
[void]$worker.AddScript($sampler).AddArgument($state).AddArgument($categories).AddArgument($cpuCounter).AddArgument($totalRam)
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
    $worker.Stop()
    $runspace.Close()
}
