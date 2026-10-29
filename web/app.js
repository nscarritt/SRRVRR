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
// none: hover text for "No sensor", shown when the sensors were read but this part has none.
function showTemp(id, t, warn, hot, error, each, none) {
  const el = $(id), deg = String.fromCharCode(176) + 'C';
  el.textContent = t != null ? Math.round(t) + deg : error ? 'Temp n/a' : none ? 'No sensor' : '';
  el.className = 'temp' + (t != null ? (t >= hot ? ' hot' : t >= warn ? ' warn' : '') : error ? ' warn' : none ? ' none' : '');
  el.title = t == null && error ? 'Temperature unavailable: ' + error : t == null && none ? none : (each || []).map(x => x.name + ': ' + x.t + deg).join('\n');
}
// The sensors were read (the CPU answered) but no memory stick reported a temperature.
function memNoSensor(s) {
  if (s.memTemp != null || s.cpuTemp == null || s.tempError) return '';
  const parts = [...new Set((s.memSticks || []).map(x => [x.maker, x.part].filter(Boolean).join(' ')).filter(Boolean))];
  return 'These memory sticks don\'t report a temperature' + (parts.length ? ' (' + parts.join(', ') + ')' : '') +
    '. Most DDR4 has no sensor; DDR5 does.';
}
function render(s) {
  if (s.uptime != null) $('uptime').textContent = 'Up ' + since(s.uptime);
  showTemp('cpuTemp', s.cpuTemp, 80, 90, s.tempError, s.cpuTemps);       // CPU package: amber at 80, red at 90
  showTemp('memTemp', s.memTemp, 70, 80, s.tempError, s.memTemps, memNoSensor(s)); // hottest stick: amber at 70, red at 80
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
// For tests under Node: the page's pure functions (tests/js). Browsers have no 'module', so this does nothing there.
if (typeof module !== 'undefined') { module.exports = { bits, niceMax, since, size, speed }; }
