// T50-45 to T50-50: the page's banners from server events, Maintenance, the sound toggle and the Flagged list
// (web/app.js), run under Node.
'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function anything() {
  const fn = function () { return proxy; };
  const proxy = new Proxy(fn, {
    get: (t, k) => (k === Symbol.toPrimitive ? () => 0 : k === 'then' ? undefined : proxy),
    set: () => true,
    apply: () => proxy,
    construct: () => proxy,
  });
  return proxy;
}

const source = fs.readFileSync(path.join(__dirname, '..', '..', 'web', 'app.js'), 'utf8');
function newSandbox() {
  return {
    module: { exports: {} }, document: anything(), window: anything(), navigator: anything(), localStorage: anything(),
    Audio: anything(), AudioContext: anything(), fetch: () => new Promise(() => {}), setInterval: () => 0,
    setTimeout: () => 0, clearInterval: () => {}, requestAnimationFrame: () => 0, console,
  };
}
const sandbox = newSandbox();
vm.runInNewContext(source, sandbox);
const app = sandbox.module.exports;
// Copied out of the sandbox: its arrays have their own Array prototype, which deepStrictEqual rejects.
const plain = x => JSON.parse(JSON.stringify(x));

function memoryStorage(initial) {
  const m = new Map(Object.entries(initial || {}));
  return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), map: m };
}
function ev(id, type, banner, logged, data, extra) {
  return Object.assign({ id, time: 1793805000000 + id, type, severity: 'info', key: type, data: data || {},
    maintenance: false, banner, logged }, extra || {});
}

test('T50-45 the first /stats answer only sets since: no banner, and the next request asks since that id', () => {
  assert.strictEqual(app.statsUrl(null), '/stats');
  const r = app.takeEvents({ ready: true, lastEventId: 500, events: [] }, null);
  assert.strictEqual(r.since, 500);
  assert.strictEqual(r.banners.length, 0);
  assert.strictEqual(r.more, false);
  assert.strictEqual(app.statsUrl(r.since), '/stats?since=500');
  // Even if a first answer carried events, nothing old pops up.
  const old = app.takeEvents({ lastEventId: 502, events: [ev(501, 'player-join', true, false, { players: 1, change: 1, who: [] })] }, null);
  assert.strictEqual(old.banners.length, 0);
  assert.strictEqual(old.since, 502);
});

test('T50-46 banners for banner events only, once each; since moves to the newest id; duplicates ignored', () => {
  const events = [
    ev(501, 'player-join', true, false, { players: 1, change: 1, who: ['Ragnar'] }),
    ev(502, 'restart-pending', false, true, { reason: 'updates' }),
    ev(503, 'drive-health', true, true, { letter: 'H:', health: 'Warning', was: 'Healthy' }, { severity: 'flag' }),
  ];
  const r = app.takeEvents({ lastEventId: 503, events }, 500);
  assert.strictEqual(r.since, 503);
  assert.deepStrictEqual(plain(r.banners).map(b => b.title), ['Ragnar joined Valheim', 'Drive H: health: Warning']);
  assert.strictEqual(r.flagged, true);
  assert.strictEqual(r.more, false);

  const again = app.takeEvents({ lastEventId: 503, events }, r.since);
  assert.strictEqual(again.banners.length, 0);
  assert.strictEqual(again.since, 503);
  assert.strictEqual(again.flagged, false);

  const twice = app.takeEvents({ lastEventId: 504, events: [ev(504, 'service-offline', true, true, { name: 'Plex' }),
    ev(504, 'service-offline', true, true, { name: 'Plex' })] }, 503);
  assert.strictEqual(twice.banners.length, 1);
  assert.strictEqual(twice.since, 504);
});

test('T50-46 a truncated answer still advances since and says more events than shown', () => {
  const events = [];
  for (let id = 505; id < 555; id++) events.push(ev(id, 'sampler-error', false, true, { error: 'x' }));
  const r = app.takeEvents({ lastEventId: 600, events, eventsTruncated: true }, 504);
  assert.strictEqual(r.since, 600);
  assert.strictEqual(r.more, true);
  assert.strictEqual(r.banners.length, 0);
  assert.strictEqual(app.takeEvents({ lastEventId: 600, events: [] }, 600).more, false);
  assert.strictEqual(app.nextSince({ lastEventId: 400, events: [] }, 600), 600);   // never goes backwards
  assert.strictEqual(app.nextSince({}, null), null);
});

test('T50-47 while Maintenance is on: no banner (so no ding), and no "more events" note', () => {
  const m = { on: true, untilMs: Date.UTC(2026, 10, 4, 15, 30) };
  const events = [ev(501, 'player-join', true, false, { players: 1, change: 1, who: [] }),
    ev(502, 'service-offline', true, true, { name: 'Valheim' })];
  const r = app.takeEvents({ lastEventId: 502, events, maintenance: m, eventsTruncated: true }, 500);
  assert.strictEqual(r.banners.length, 0);
  assert.strictEqual(r.more, false);
  assert.strictEqual(r.since, 502);
  assert.strictEqual(app.shouldBanner(events[1], m), false);
  assert.strictEqual(app.shouldBanner(events[1], { on: false, untilMs: 0 }), true);
  assert.strictEqual(app.shouldBanner(Object.assign({}, events[1], { maintenance: true }), { on: false }), false);
  assert.strictEqual(app.shouldBanner(ev(503, 'started', false, true), { on: false }), false);
});

test('T50-47 T63-03 "Maintenance until 3:30 PM" in the browser\'s own time zone (two zones)', () => {
  const m = { on: true, untilMs: Date.UTC(2026, 10, 4, 15, 30) };
  assert.strictEqual(app.maintenanceText(m, 'UTC'), 'Maintenance until 3:30 PM');
  assert.strictEqual(app.maintenanceText(m, 'Asia/Tokyo'), 'Maintenance until 12:30 AM');
  assert.strictEqual(app.maintenanceText({ on: false, untilMs: 0 }, 'UTC'), '');
  assert.match(app.maintenanceError(429), /too many changes, try again in a few seconds/i);
  assert.match(app.maintenanceError(403), /403/);
  assert.match(app.maintenanceError(400), /400/);
  assert.ok(app.maintenanceError(0).length > 0);
});

// Golden values: what the v0.6.0 page's watchValheim (commit 90afdd6) passed to notify for the same change. Plex streams no
// longer raise alerts (#57).
const golden = [
  ['Valheim: one joins, named (1 Ragnar -> 2 Ragnar, Lagertha)', { type: 'player-join', data: { players: 2, change: 1, who: ['Lagertha'] } },
    'valheim', 'Lagertha joined Valheim', ['2 players online']],
  ['Valheim: two join, named (0 -> 2)', { type: 'player-join', data: { players: 2, change: 2, who: ['Ragnar', 'Lagertha'] } },
    'valheim', 'Ragnar, Lagertha joined Valheim', ['2 players online']],
  ['Valheim: one joins, no names (0 -> 1)', { type: 'player-join', data: { players: 1, change: 1, who: [] } },
    'valheim', 'A player joined Valheim', ['1 player online']],
  ['Valheim: three join, no names (1 -> 4)', { type: 'player-join', data: { players: 4, change: 3, who: [] } },
    'valheim', '3 players joined Valheim', ['4 players online']],
  ['Valheim: one leaves, named (2 -> 1)', { type: 'player-leave', data: { players: 1, change: 1, who: ['Lagertha'] } },
    'valheim', 'Lagertha left Valheim', ['1 player online']],
  ['Valheim: one leaves, no names (3 -> 2)', { type: 'player-leave', data: { players: 2, change: 1, who: [] } },
    'valheim', 'A player left Valheim', ['2 players online']],
  ['Valheim: everyone leaves, no names (2 -> 0)', { type: 'player-leave', data: { players: 0, change: 2, who: [] } },
    'valheim', '2 players left Valheim', ['No players online']],
];
for (const [name, e, icon, title, lines] of golden) {
  test('T50-48 ' + name + ': the same banner as v0.6.0', () => {
    const b = plain(app.bannerFor(Object.assign({ id: 1, banner: true }, e)));
    assert.strictEqual(b.icon, icon);
    assert.strictEqual(b.title, title);
    assert.deepStrictEqual(b.lines, lines);
  });
}

test('T50-48 every bannered server event gets a plain title', () => {
  const types = ['service-offline', 'service-back', 'query-stopped', 'query-back', 'drive-health', 'data-drive-missing',
    'data-fallback', 'share-found', 'history-save-failed'];
  for (const t of types) {
    const b = plain(app.bannerFor({ id: 1, type: t, data: { name: 'Valheim', error: 'timed out', letter: 'H:', health: 'Warning', was: 'Healthy', reason: 'r' } }));
    assert.ok(b.title.length > 0, t);
    assert.ok(!/undefined|null/.test(b.title + b.lines.join(' ')), t);
  }
  assert.strictEqual(app.bannerFor({ type: 'service-offline', data: { name: 'Valheim' } }).title, 'Valheim went offline');
});

test('T50-49 sound: the same storage key as v0.6.0; a storage error leaves sound off', () => {
  assert.strictEqual(app.soundFromStorage(memoryStorage({ 'srrvrr.sound': '1' })), true);
  assert.strictEqual(app.soundFromStorage(memoryStorage({ 'srrvrr.sound': '0' })), false);
  assert.strictEqual(app.soundFromStorage(memoryStorage()), false);
  assert.strictEqual(app.soundFromStorage({ getItem: () => { throw new Error('blocked'); } }), false);
  assert.strictEqual(app.soundFromStorage(null), false);
  const s = memoryStorage();
  app.saveSound(s, true);
  assert.strictEqual(s.map.get('srrvrr.sound'), '1');
  app.saveSound(s, false);
  assert.strictEqual(s.map.get('srrvrr.sound'), '0');
  assert.doesNotThrow(() => app.saveSound({ setItem: () => { throw new Error('blocked'); } }, true));
});

test('T50-49 the page still loads when reading localStorage itself throws (site data blocked)', () => {
  const box = newSandbox();
  Object.defineProperty(box, 'localStorage', { get: () => { throw new Error('SecurityError'); } });
  assert.doesNotThrow(() => vm.runInNewContext(source, box));
  assert.strictEqual(typeof box.module.exports.soundFromStorage, 'function');
});

test('T63-01 fmtTime: 12-hour times in a fixed zone, with a plain space before AM/PM', () => {
  const at = (h, m) => Date.UTC(2026, 10, 6, h, m);
  assert.strictEqual(app.fmtTime(at(19, 42), 'UTC'), '7:42 PM');
  assert.strictEqual(app.fmtTime(at(0, 0), 'UTC'), '12:00 AM');
  assert.strictEqual(app.fmtTime(at(12, 0), 'UTC'), '12:00 PM');
  assert.strictEqual(app.fmtTime(at(9, 5), 'UTC'), '9:05 AM');
  assert.strictEqual(app.fmtTime('x', 'UTC'), '');
  assert.strictEqual(app.fmtTime(at(9, 5), 'Not/AZone'), '');
});

test('T63-02 fmtTime with a date', () => {
  assert.strictEqual(app.fmtTime(Date.UTC(2026, 10, 6, 19, 42), 'UTC', true), 'Nov 6, 7:42 PM');
});

test('T63-04 a banner ends with the time of its event; a page-made banner with the time it appeared', () => {
  const t = Date.UTC(2026, 10, 6, 19, 42);
  const e = Object.assign(ev(601, 'service-offline', true, true, { name: 'Plex' }), { time: t });
  const r = app.takeEvents({ lastEventId: 601, events: [e] }, 600);
  assert.strictEqual(r.banners[0].time, t);
  const lines = plain(app.bannerLines(r.banners[0].lines, r.banners[0].time, 'UTC'));
  assert.deepStrictEqual(lines, ['It is no longer running.', '7:42 PM']);
  assert.deepStrictEqual(plain(app.bannerLines(['Some alerts were skipped.'], Date.UTC(2026, 10, 6, 0, 5), 'UTC')),
    ['Some alerts were skipped.', '12:05 AM']);
  assert.deepStrictEqual(plain(app.bannerLines([], t, 'UTC')), ['7:42 PM']);
  // the Flagged list's hover text has no time line of its own
  assert.deepStrictEqual(plain(app.bannerFor(e).lines), ['It is no longer running.']);
});

test('T63-05 a banner closes on the 60th visible second, not before, and hidden seconds do not count', () => {
  let hidden = false;
  const tick = app.bannerTicker(() => hidden, 60);
  for (let i = 0; i < 59; i++) assert.strictEqual(tick(), false, 'visible second ' + (i + 1));
  hidden = true;
  for (let i = 0; i < 120; i++) assert.strictEqual(tick(), false, 'hidden second ' + (i + 1));
  hidden = false;
  assert.strictEqual(tick(), true);
  assert.strictEqual(app.bannerTicker(() => false)(), false);   // the default is 60, not 1
});

test('T50-50 T63-06 the Flagged list: 20 events newest first, with severity and time', () => {
  const sevs = ['flag', 'warn', 'info'];
  const events = [];
  for (let i = 1; i <= 20; i++) {
    events.push({ id: 1000 + i, time: Date.UTC(2026, 10, 4, 15, 0) + i * 60000, type: 'service-offline',
      severity: sevs[i % 3], maintenance: false, data: { name: 'Svc' + i } });
  }
  const html = app.flaggedHtml(events, 31, 'UTC');
  assert.strictEqual(html.split('class="frow"').length - 1, 20);
  let last = -1;
  for (let i = 20; i >= 1; i--) {
    const at = html.indexOf('Svc' + i + ' went offline');
    assert.ok(at > last, 'Svc' + i + ' is after the newer ones');
    last = at;
  }
  assert.ok(html.indexOf('3:20 PM') < html.indexOf('3:19 PM'));
  assert.match(html, /Nov 4, 3:20 PM/);
  assert.ok(!/15:\d\d/.test(html));
  assert.match(html, /class="fsev flag">Flag</);
  assert.match(html, /class="fsev warn">Warning</);
  assert.match(html, /class="fsev info">Info</);
});

test('T50-50 the Flagged list: none, a 400, a failure, and names escaped', () => {
  assert.match(app.flaggedHtml([], 31, 'UTC'), /Nothing flagged in the last 31 days\./);
  assert.match(app.flaggedHtml([], 7, 'UTC'), /Nothing flagged in the last 7 days\./);
  assert.strictEqual(app.flaggedDays(31), 31);
  assert.strictEqual(app.flaggedDays(7), 7);
  assert.strictEqual(app.flaggedDays(90), 31);
  assert.strictEqual(app.flaggedDays(undefined), 31);
  assert.match(app.flaggedError(400), /class="ferr"/);
  assert.match(app.flaggedError(400), /400/);
  assert.match(app.flaggedError(0), /class="ferr"/);
  assert.match(app.flaggedHtml(undefined, 31, 'UTC'), /class="ferr"/);
  const html = app.flaggedHtml([{ id: 1, time: 0, type: 'service-offline', severity: '<x>', data: { name: '<b>Odd</b>' } }], 31, 'UTC');
  assert.ok(html.includes('&lt;b&gt;Odd&lt;/b&gt;'));
  assert.ok(!html.includes('<b>Odd'));
  assert.match(html, /class="fsev info"/);
});
