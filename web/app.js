// The graphs keep 15 minutes (900 seconds) and show the last 60 s or all 15 min, as chosen (remembered per browser).
const N = 900, LINES = ['cpu', 'mem', 'gpu', 'rx', 'tx'];
let hist = {cpu: [], mem: [], gpu: [], rx: [], tx: []};
let lastTs = 0, range = 60;
const missing = v => v == null || Number.isNaN(v);
function rangeFromStorage(storage) {
  try { return storage.getItem('srrvrr.range') === '900' ? 900 : 60; } catch (e) { return 60; }
}
function saveRange(storage, r) { try { storage.setItem('srrvrr.range', String(r)); } catch (e) {} }
const visibleSlice = (buffer, r) => buffer.slice(-r);
// [1, 2, null, 5] -> [[{i:0,v:1}, {i:1,v:2}], [{i:3,v:5}]]: a missing second is a gap in the line.
function toSegments(values) {
  const out = []; let cur = null;
  values.forEach((v, i) => {
    if (missing(v)) { cur = null; return; }
    if (!cur) { cur = []; out.push(cur); }
    cur.push({i, v});
  });
  return out;
}
// /history -> the page's buffers (only the lines the page draws; nulls kept as gaps).
function fillFromHistory(json) {
  const h = {newestMs: json.newestMs};
  for (const n of LINES) h[n] = Array.isArray(json.lines && json.lines[n]) ? json.lines[n].slice(-N) : [];
  return h;
}
const shouldRefetchHistory = (wasDown, nowOk) => wasDown && nowOk;
// More than 5 s since the last reading (a background tab whose timers the browser slowed): the server has them all.
const needsHistory = (lastMs, ts) => lastMs > 0 && Math.floor(ts / 1000) * 1000 - lastMs > 5000;
// Reading localStorage itself throws when site data is blocked, so it's fetched through this.
const store = () => { try { return localStorage; } catch (e) { return null; } };
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
function draw(id, series, max, scaleLabel, span) {
  const c = $(id), r = devicePixelRatio || 1, w = c.clientWidth, h = c.clientHeight;
  if (c.width !== w * r || c.height !== h * r) { c.width = w * r; c.height = h * r; }
  const g = c.getContext('2d');
  g.setTransform(r, 0, 0, r, 0, 0);
  g.clearRect(0, 0, w, h);
  g.strokeStyle = css('--grid'); g.lineWidth = 1;
  for (let i = 0; i <= 4; i++) { const y = Math.round((h - 1) * i / 4) + .5; g.beginPath(); g.moveTo(0, y); g.lineTo(w, y); g.stroke(); }
  for (const s of series) {
    const d = s.data; if (!d.length) continue;
    const x = i => w - (d.length - 1 - i) * w / (span - 1), y = v => h - 1 - Math.min(v / max, 1) * (h - 2);
    for (const seg of toSegments(d)) {
      g.beginPath();
      seg.forEach((p, k) => k ? g.lineTo(x(p.i), y(p.v)) : g.moveTo(x(p.i), y(p.v)));
      g.strokeStyle = s.color; g.lineWidth = span > 60 ? 1 : 1.5; g.setLineDash(s.dash || []); g.stroke(); g.setLineDash([]);
      if (s.fill) { g.lineTo(x(seg[seg.length - 1].i), h); g.lineTo(x(seg[0].i), h); g.closePath(); g.globalAlpha = .15; g.fillStyle = s.color; g.fill(); g.globalAlpha = 1; }
    }
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
  el.className = 'temp' + (t != null ? (t >= hot ? ' hot' : t >= warn ? ' warn' : '') : error || none ? ' none' : '');
  el.title = t == null && error ? 'Temperature unavailable: ' + error : t == null && none ? none : (each || []).map(x => x.name + ': ' + x.t + deg).join('\n');
}
// The sensors were read (the CPU answered) but no memory stick reported a temperature.
function memNoSensor(s) {
  if (s.memTemp != null || s.cpuTemp == null || s.tempError) return '';
  const parts = [...new Set((s.memSticks || []).map(x => [x.maker, x.part].filter(Boolean).join(' ')).filter(Boolean))];
  return 'These memory sticks don\'t report a temperature' + (parts.length ? ' (' + parts.join(', ') + ')' : '') +
    '. Most DDR4 has no sensor; DDR5 does.';
}
// The version in the header: the text as given; amber, with a hover note, unless it is a release (v1.2.3).
function showVersion(v, el) {
  el = el || $('version');
  el.textContent = v;
  const release = /^v\d+\.\d+\.\d+$/.test(v);
  el.className = release ? '' : 'warn';
  el.title = release ? '' : 'Not a release build';
}
function render(s) {
  if (s.uptime != null) $('uptime').textContent = 'Up ' + since(s.uptime);
  if (typeof s.version === 'string') showVersion(s.version);
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
  drawGraphs();
  renderProcs(s);
  renderDrives(s);
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
function soundFromStorage(storage) {
  try { return storage.getItem('srrvrr.sound') === '1'; } catch (e) { return false; }
}
function saveSound(storage, on) { try { storage.setItem('srrvrr.sound', on ? '1' : '0'); } catch (e) {} }
let audio = null, soundOn = soundFromStorage(store()), lastDing = 0;
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
    saveSound(store(), soundOn);
  }
  armed = true; showSound(); ding(); // a sample ding
};
document.addEventListener('click', () => { if (!armed) { armed = true; showSound(); } });
showSound();
// A banner: title, a line or two of detail, and a close button. It closes by itself
// after 15 seconds of the page being on screen, so alerts that arrive in a background
// tab are still there when you come back. quiet: no ding (for small notes).
function notify(icon, title, lines, quiet) {
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
  if (!quiet) ding();
}
// --- Events are decided on the server (spec section 4). The page asks /stats?since=<the newest id it has seen> and
// shows a banner for each new event the server marks for one. The first answer only sets the starting point, so
// nothing old pops up when the page opens; while Maintenance is on, nothing shows and nothing dings.
const statsUrl = id => id == null ? '/stats' : '/stats?since=' + id;
// The newest id in a /stats answer (lastEventId or any event's id), never going backwards; null until there is one.
function nextSince(s, current) {
  let n = typeof current === 'number' ? current : null;
  const ids = ((s && s.events) || []).map(e => e && e.id);
  if (s) ids.push(s.lastEventId);
  for (const id of ids) if (typeof id === 'number' && (n == null || id > n)) n = id;
  return n;
}
const shouldBanner =(e, m) => !!(e && e.banner && !e.maintenance && !(m && m.on));
// One /stats answer -> the banners to show, the next `since`, whether to say some were skipped (more than 50 new
// events), and whether a logged event arrived (the Flagged list then reloads). Ids up to `current` were seen already.
function takeEvents(s, current) {
  const next = nextSince(s, current), quiet = !!(s && s.maintenance && s.maintenance.on);
  if (current == null) return {since: next, banners: [], more: false, flagged: false};
  const seen = new Set();
  const fresh = ((s && s.events) || []).filter(e => e && typeof e.id === 'number' && e.id > current && !seen.has(e.id) && seen.add(e.id));
  return {since: next, banners: fresh.filter(e => shouldBanner(e, s.maintenance)).map(bannerFor),
    more: !!(s && s.eventsTruncated) && !quiet, flagged: fresh.some(e => e.logged)};
}
// Plex: the device a stream plays on, with the app when it differs (for the row's hover). Plex streams raise no
// alerts (#57: short episodes made them constant).
const plexDevice = i => !i.device ? i.app || '' : i.app && i.app !== i.device ? i.device + ' (' + i.app + ')' : i.device;
// Valheim: who joined or left (names when the server reports them), and how many are on now.
function playerBanner(d, up) {
  const who = [].concat(d.who || []), n = Math.abs(d.change) || 1;
  return {icon: 'valheim', title: (who.length ? who.join(', ') : n === 1 ? 'A player' : n + ' players') + (up ? ' joined' : ' left') + ' Valheim',
    lines: [(d.players ? plural(d.players, 'player') : 'No players') + ' online']};
}
const serviceIcon = n => n === 'Valheim' ? 'valheim' : n === 'Plex' ? 'plex' : '';
// An event -> {icon, title, lines} for its banner, and for its row in the Flagged list (types with no banner too).
function bannerFor(e) {
  const d = (e && e.data) || {}, name = d.name || 'A service', drive = 'Drive ' + (d.letter || '');
  const b = (icon, title, lines) => ({icon: icon, title: title, lines: lines.filter(Boolean)});
  switch (e && e.type) {
    case 'player-join': return playerBanner(d, true);
    case 'player-leave': return playerBanner(d, false);
    case 'service-offline': return b(serviceIcon(name), name + ' went offline', ['It is no longer running.']);
    case 'service-back': return b(serviceIcon(name), name + ' is back online', ['It is running again.']);
    case 'query-stopped': return b(serviceIcon(name), name + ' stopped answering', ['It is running, but not answering status checks.', d.error && 'Reason: ' + d.error]);
    case 'query-back': return b(serviceIcon(name), name + ' is answering again', []);
    case 'drive-health': return b('', drive + ' health: ' + (d.health || 'unknown'), [d.was && 'It was ' + d.was + ' before.']);
    case 'data-drive-missing': return b('', drive + ' is missing', ['Windows can no longer see it.', d.was && 'It was ' + d.was + ' before.']);
    case 'data-fallback': return b('', 'Saving to the local data folder', ['SRRVRR could not use its usual data folder.', d.reason]);
    case 'share-found': return b('', 'The data folder is shared on the network', ['Other computers may be able to read or change its files.', d.reason]);
    case 'history-save-failed': return b('', 'Could not save the graph history', ['The live graphs still work.', d.error]);
    case 'restart-pending': return b('', 'Windows is waiting to restart', [d.reason]);
    case 'sampler-error': return b('', 'A reading failed', [d.error]);
    case 'worker-stopped': return b('', 'A background task stopped', [d.name, d.error]);
    case 'maintenance-on': return b('', 'Maintenance turned on', []);
    case 'maintenance-off': return b('', 'Maintenance turned off', []);
    case 'started': return b('', 'SRRVRR started', [d.reason]);
    case 'stopped': return b('', 'SRRVRR stopped', [d.reason]);
  }
  return b('', String((e && e.type) || 'Event').replace(/-/g, ' '), []);
}
// --- Maintenance: a checkbox kept on the server, so it applies to every browser. "Maintenance until 15:30" is in
// the browser's own time zone (the tests pass one).
function clock(ms, timeZone) {
  if (typeof ms !== 'number') return '';
  try { return new Intl.DateTimeFormat('en-GB', {hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: timeZone}).format(ms); } catch (e) { return ''; }
}
function maintenanceText(m, timeZone) {
  if (!m || !m.on) return '';
  const t = clock(m.untilMs, timeZone);
  return t ? 'Maintenance until ' + t : 'Maintenance on';
}
function maintenanceError(status) {
  return status === 429 ? 'Too many changes, try again in a few seconds.'
    : status === 403 ? 'The server refused the change from this page (403).'
    : status === 400 ? 'The server did not accept the change (400).'
    : status ? 'Could not change Maintenance (error ' + status + ').' : 'Could not reach SRRVRR to change Maintenance.';
}
let maint = {on: false, untilMs: 0}, maintBusy = false;
function showMaint(m) {
  if (m) maint = m;
  if (maintBusy) return;              // a change is on its way: don't flip the box back meanwhile
  $('maintBox').checked = !!maint.on;
  $('maint').dataset.on = maint.on ? '1' : '';
  $('maintText').textContent = maintenanceText(maint) || 'Maintenance';
}
async function setMaintenance(on) {
  let err = '';
  maintBusy = true; $('maintBox').disabled = true;
  try {
    const r = await fetch('/maintenance', {method: 'POST', cache: 'no-store',
      headers: {'X-SRRVRR': '1', 'Content-Type': 'application/json'}, body: JSON.stringify({on: on})});
    if (r.ok) maint = await r.json(); else err = maintenanceError(r.status);
  } catch (e) { err = maintenanceError(0); }
  maintBusy = false; $('maintBox').disabled = false;
  $('maintErr').textContent = err; $('maintErr').hidden = !err;
  showMaint();
}
$('maintBox').onchange = () => setMaintenance($('maintBox').checked);
// --- The Flagged list: the logged events of the last 31 days (fewer if the logs are kept fewer), newest first.
const flaggedDays = keep => Math.min(31, keep >= 1 ? Math.floor(keep) : 31);
const SEVERITY = {flag: 'Flag', warn: 'Warning', info: 'Info'};
function stamp(ms, timeZone) {        // "4 Nov, 15:30"
  if (typeof ms !== 'number') return '';
  try {
    return new Intl.DateTimeFormat('en-GB', {day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23', timeZone: timeZone}).format(ms);
  } catch (e) { return ''; }
}
const flaggedError = status => '<div class="ferr">Couldn\'t load the Flagged list' +
  (status === 400 ? ': the server didn\'t accept the request (400).' : status ? ' (error ' + status + ').' : '.') + '</div>';
function flaggedHtml(events, days, timeZone) {
  if (!Array.isArray(events)) return flaggedError(0);
  const list = events.filter(e => e && typeof e === 'object').sort((x, y) => (y.id || 0) - (x.id || 0));
  if (!list.length) return '<div class="fnone">Nothing flagged in the last ' + plural(days, 'day') + '.</div>';
  return list.slice(0, 100).map(e => {
    const sev = ['flag', 'warn', 'info'].includes(e.severity) ? e.severity : 'info', t = bannerFor(e);
    return '<div class="frow"><span class="fsev ' + sev + '">' + SEVERITY[sev] + '</span><span class="ftime">' + esc(stamp(e.time, timeZone)) +
      '</span><span class="ftext" title="' + t.lines.map(esc).join('&#10;') + '">' + esc(t.title) +
      (e.maintenance ? ' <small>(during maintenance)</small>' : '') + '</span></div>';
  }).join('') + (list.length > 100 ? '<div class="fnone">and ' + (list.length - 100) + ' older</div>' : '');
}
async function loadFlagged(keep) {
  const days = flaggedDays(keep);
  try {
    const r = await fetch('/events?days=' + days, {cache: 'no-store'});
    $('flagged').innerHTML = r.ok ? flaggedHtml((await r.json()).events, days) : flaggedError(r.status);
  } catch (e) { $('flagged').innerHTML = flaggedError(0); }
}
let eventSince = null, flaggedAsked = false;
function showEvents(s) {
  const r = takeEvents(s, eventSince);
  eventSince = r.since;
  for (const b of r.banners) notify(b.icon, b.title, b.lines);
  if (r.more) notify('', 'More events than shown', ['Some alerts were skipped. The logged ones are in the Flagged list.'], true);
  if (s.maintenance) showMaint(s.maintenance);
  // The first answer gives how many days the logs keep, so the list loads then, and again when a logged event arrives.
  if (!flaggedAsked || r.flagged) { flaggedAsked = true; loadFlagged(s.logRetentionDays); }
}
function drawGraphs() {
  const v = n => visibleSlice(hist[n], range);
  draw('cpuC', [{data: v('cpu'), color: css('--cpu'), fill: true}], 100, '', range);
  draw('memC', [{data: v('mem'), color: css('--mem'), fill: true}], 100, '', range);
  draw('gpuC', [{data: v('gpu'), color: css('--gpu'), fill: true}], 100, '', range);
  const netMax = niceMax(Math.max(0, ...v('rx').concat(v('tx')).filter(x => !missing(x))));
  draw('netC', [{data: v('rx'), color: css('--rx'), fill: true}, {data: v('tx'), color: css('--tx'), dash: [4, 3]}], netMax, bits(netMax), range);
}
// --- The 60 s / 15 min buttons.
function showRange() {
  for (const b of document.querySelectorAll('#range button')) b.setAttribute('aria-pressed', String(+b.dataset.r === range));
}
range = rangeFromStorage(store());
for (const b of document.querySelectorAll('#range button')) {
  b.onclick = () => { range = +b.dataset.r; saveRange(store(), range); showRange(); drawGraphs(); };
}
showRange();
// --- The server keeps 15 minutes of readings, so a new page (or one coming back after a lost connection) starts
// with full graphs. A second with no reading (SRRVRR stopped, or the page lost touch) is a gap in the line.
let lastSecMs = 0, wasDown = false;
async function loadHistory() {
  try {
    const h = fillFromHistory(await (await fetch('/history', {cache: 'no-store'})).json());
    for (const n of LINES) hist[n] = h[n];
    lastSecMs = h.newestMs || 0;
  } catch (e) {}
}
function pushReading(s) {
  const sec = Math.floor(s.ts / 1000) * 1000;
  if (lastSecMs && sec <= lastSecMs) return;                       // already in the history
  const skipped = lastSecMs ? Math.min(N, Math.round((sec - lastSecMs) / 1000) - 1) : 0;
  for (let i = 0; i < skipped; i++) for (const n of LINES) push(hist[n], null);
  push(hist.cpu, s.cpu); push(hist.mem, 100 * s.memUsed / s.memTotal); push(hist.gpu, s.gpu || 0);
  push(hist.rx, s.rx); push(hist.tx, s.tx);
  lastSecMs = sec;
}
async function tick() {
  try {
    const s = await (await fetch(statsUrl(eventSince), {cache: 'no-store'})).json();
    if (shouldRefetchHistory(wasDown, true) || needsHistory(lastSecMs, s.ts)) await loadHistory();
    wasDown = false;
    if (s.ready && s.ts !== lastTs) {
      lastTs = s.ts;
      pushReading(s);
      render(s);
    }
    showEvents(s);
    $('status').className = s.error ? 'bad' : '';
    $('status').textContent = s.error ? 'Counter error: ' + s.error : (s.ready ? 'Live \u00b7 updates every second' : 'Starting\u2026');
  } catch (e) {
    wasDown = true;
    $('status').className = 'bad';
    $('status').textContent = 'Disconnected, retrying\u2026';
  }
  setTimeout(tick, 500);
}
loadHistory().then(tick);
// For tests under Node: the page's pure functions (tests/js). Browsers have no 'module', so this does nothing there.
if (typeof module !== 'undefined') {
  module.exports = { bits, niceMax, since, size, speed, rangeFromStorage, saveRange, visibleSlice, toSegments, fillFromHistory, shouldRefetchHistory, needsHistory,
    statsUrl, nextSince, shouldBanner, takeEvents, bannerFor, plexDevice, maintenanceText, maintenanceError,
    flaggedDays, flaggedHtml, flaggedError, soundFromStorage, saveSound, showVersion };
}
