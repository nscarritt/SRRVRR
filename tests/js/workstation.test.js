// T90 to T93: the Workstation's page functions in web/app.js, run under Node (node --test tests/js).
// Loaded as app.test.js does: app.js runs its page code on load in a sandbox of harmless stand-ins. Top-level
// `function` declarations of app.js are properties of the sandbox (`const` ones aren't), so declare the new page
// functions with `function name(...)`. One region per story; add tests only inside your own.
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
const sandbox = {
  module: { exports: {} }, document: anything(), window: anything(), navigator: anything(), localStorage: anything(),
  Audio: anything(), AudioContext: anything(), fetch: () => new Promise(() => {}), setInterval: () => 0,
  setTimeout: () => 0, clearInterval: () => {}, requestAnimationFrame: () => 0, console,
};
vm.runInNewContext(source, sandbox);
const page = sandbox;
// A stand-in for the element a card renders into: only innerHTML and hidden are set (spec section 8).
const fakeElement = () => ({ innerHTML: '', hidden: true });

// #region 90 Roles and the host name (#90)
// In a block, so these names can't clash with another region's when the stories are stacked.
{
// An object made inside the sandbox has the sandbox's own Object.prototype, and deepStrictEqual compares
// prototypes, so a result is copied into a plain object of this realm before it's compared.
const plain = o => Object.assign({}, o);
const SERVER_CARDS = { proc: true, vram: false, ai: false, top: false };

test('T90-11 cardsFor(\'server\'): the Processes card and none of the Workstation cards', () => {
  assert.strictEqual(typeof page.cardsFor, 'function', 'cardsFor is a top-level function in app.js');
  assert.deepStrictEqual(plain(page.cardsFor('server')), SERVER_CARDS);
});

test('T90-11 cardsFor(\'workstation\'): Video memory, AI server and Top programs, and no Processes card', () => {
  assert.strictEqual(typeof page.cardsFor, 'function', 'cardsFor is a top-level function in app.js');
  assert.deepStrictEqual(plain(page.cardsFor('workstation')), { proc: false, vram: true, ai: true, top: true });
});

test('T90-11 cardsFor with no role (an older SRRVRR\'s /stats) or any other role gives the server\'s cards', () => {
  assert.strictEqual(typeof page.cardsFor, 'function', 'cardsFor is a top-level function in app.js');
  assert.deepStrictEqual(plain(page.cardsFor(undefined)), SERVER_CARDS);
  assert.deepStrictEqual(plain(page.cardsFor('desktop')), SERVER_CARDS);
});

test('T90-12 hostTitle is the host name from /stats, or SRRVRR when there is none', () => {
  assert.strictEqual(typeof page.hostTitle, 'function', 'hostTitle is a top-level function in app.js');
  assert.strictEqual(page.hostTitle({ hostName: 'DEV-PC' }), 'DEV-PC');
  assert.strictEqual(page.hostTitle({}), 'SRRVRR');
});
}
// #endregion 90

// #region 91 Video memory and GPU detail (#91)
{
  // Copied out of the sandbox: its arrays have their own Array prototype, which deepStrictEqual rejects.
  const plain = x => JSON.parse(JSON.stringify(x));
  const GiB = 2 ** 30;
  const dot = ' ' + String.fromCharCode(183) + ' ';
  const html = fs.readFileSync(path.join(__dirname, '..', '..', 'web', 'index.html'), 'utf8');
  const junk = /undefined|NaN|null/;

  test('T91-12 vramTile: dedicated of the total, the shared line, not spilling', () => {
    const t = plain(page.vramTile({ gpuMem: 17.8 * GiB, gpuMemTotal: 24 * GiB, gpuShared: 0.1 * GiB, gpuSpill: false }));
    assert.strictEqual(t.value, '17.8 / 24 GB');
    assert.strictEqual(t.sub, 'shared 0.1 GB');
    assert.strictEqual(t.spill, false);
    assert.strictEqual(typeof t.title, 'string');
  });

  test('T91-12 vramTile while spilling: spill true, and the badge reads Spilling into RAM', () => {
    const t = plain(page.vramTile({ gpuMem: 23.6 * GiB, gpuMemTotal: 24 * GiB, gpuShared: 2.1 * GiB, gpuSpill: true }));
    assert.strictEqual(t.spill, true);
    assert.strictEqual(t.value, '23.6 / 24 GB');
    assert.strictEqual(t.sub, 'shared 2.1 GB');
    // vramTile gives no badge text (plan, Shared interfaces): the badge's text is in the page's markup or script.
    assert.ok(html.includes('Spilling into RAM') || source.includes('Spilling into RAM'), 'the vramBadge text "Spilling into RAM"');
  });

  test('T91-12 vramTile with gpuMemTotal 0 or missing: n/a and no spill, with no error', () => {
    for (const s of [{ gpuMem: 0, gpuMemTotal: 0, gpuShared: 0, gpuSpill: false }, { gpuMem: 0, gpuShared: 0, gpuSpill: false }, {}]) {
      const t = plain(page.vramTile(s));
      assert.strictEqual(t.value, 'n/a', JSON.stringify(s));
      assert.strictEqual(t.spill, false, JSON.stringify(s));
      for (const v of [t.value, t.sub, t.title]) if (typeof v === 'string') assert.ok(!junk.test(v), JSON.stringify(t));
    }
  });

  test('T91-12 a Workstation with no NVIDIA card or no GPU counters: the tile says n/a, no spill, no GPU detail or badge', () => {
    // What such a PC sends: no nvidia-smi fields, no card total (Review Focus 3).
    const s = { role: 'workstation', hasGpu: false, gpu: 0, gpuMem: 0, gpuShared: 0, gpuSpill: false, gpuMemTotal: 0 };
    assert.strictEqual(page.vramTile(s).value, 'n/a');
    assert.strictEqual(page.vramTile(s).spill, false);
    assert.strictEqual(page.gpuDetailText(s), '', 'an empty detail line, so the GPU tile keeps today\'s line');
    assert.strictEqual(page.gpuBadge(s.gpuLimits), '');
    assert.strictEqual(page.gpuBadge(null), '');
  });

  test('T91-13 gpuDetailText: power of the limit, the clock and the fan; missing parts left out', () => {
    const full = { gpuPower: 312, gpuPowerLimit: 450, gpuClock: 2610, gpuClockMax: 3105, gpuFan: 48, gpuPState: 'P2', gpuLimits: ['power'] };
    const without = (k, v) => Object.assign({}, full, { [k]: v });
    assert.strictEqual(page.gpuDetailText(full), '312 of 450 W' + dot + '2,610 MHz' + dot + 'fan 48%');
    assert.strictEqual(page.gpuDetailText(without('gpuPowerLimit', null)), '312 W' + dot + '2,610 MHz' + dot + 'fan 48%');
    const noLimit = Object.assign({}, full); delete noLimit.gpuPowerLimit;
    assert.strictEqual(page.gpuDetailText(noLimit), '312 W' + dot + '2,610 MHz' + dot + 'fan 48%');
    assert.strictEqual(page.gpuDetailText(without('gpuFan', null)), '312 of 450 W' + dot + '2,610 MHz');
    assert.strictEqual(page.gpuDetailText(without('gpuFan', 0)), '312 of 450 W' + dot + '2,610 MHz' + dot + 'fan 0%',
      'a fan at 0% is a reading, not a missing part');
    assert.strictEqual(page.gpuDetailText({}), '');
    assert.strictEqual(page.gpuDetailText({ gpu: 12, gpuMem: GiB, gpuEngine: '3D' }), '', 'a Server reading has no detail');
  });

  test('T91-13 gpuBadge: Hot first, then Power limit, then Slowed, else nothing', () => {
    assert.strictEqual(page.gpuBadge(['power']), 'Power limit');
    assert.strictEqual(page.gpuBadge(['power', 'thermal']), 'Hot');
    assert.strictEqual(page.gpuBadge(['slowed']), 'Slowed');
    assert.strictEqual(page.gpuBadge([]), '');
    assert.strictEqual(page.gpuBadge(['power', 'thermal', 'slowed']), 'Hot');
    assert.strictEqual(page.gpuBadge(['slowed', 'power']), 'Power limit');
    assert.strictEqual(page.gpuBadge(undefined), '');
  });

  test('T91-14 bannerFor vram-spill and vram-spill-ended, and the Flagged row', () => {
    const b = plain(page.bannerFor({ id: 1, type: 'vram-spill', severity: 'warn', banner: true, logged: true, data: { dedicatedGb: 23.1, sharedGb: 2.0 } }));
    assert.strictEqual(b.title, 'Video memory full: spilling into RAM');
    assert.deepStrictEqual(b.lines, ['Work on the GPU will be slow']);
    const e = plain(page.bannerFor({ id: 2, type: 'vram-spill-ended', severity: 'info', banner: false, logged: true, data: {} }));
    assert.strictEqual(e.title, 'Video memory no longer spilling');
    assert.ok(!/undefined|null/.test(e.title + ' ' + e.lines.join(' ')));
    const row = page.flaggedHtml([{ id: 2, time: Date.UTC(2026, 10, 6, 19, 42), type: 'vram-spill-ended', severity: 'info', data: {} }], 31, 'UTC');
    assert.ok(row.includes('Video memory no longer spilling'), row);
  });

  test('T91-15 fillFromHistory fills vram and vramShared (and leaves them empty from a Server)', () => {
    assert.ok(vm.runInContext("LINES.includes('vram') && LINES.includes('vramShared')", sandbox), 'LINES has vram and vramShared');
    const lines = { cpu: [1], mem: [2], gpu: [3], rx: [4], tx: [5] };
    const h = plain(page.fillFromHistory({ version: 1, newestMs: 5000, stepMs: 1000,
      lines: Object.assign({ vram: [17.81, null, 17.9], vramShared: [0.1, null, 2.05] }, lines) }));
    assert.deepStrictEqual(h.vram, [17.81, null, 17.9]);
    assert.deepStrictEqual(h.vramShared, [0.1, null, 2.05]);
    const server = plain(page.fillFromHistory({ version: 1, newestMs: 5000, stepMs: 1000, lines }));
    assert.deepStrictEqual(server.vram, []);
    assert.deepStrictEqual(server.vramShared, []);
  });

  test('T91-15 pushReading pushes video memory in GiB, and null for both lines without gpuShared', () => {
    vm.runInContext('lastSecMs = 0', sandbox);
    const base = { cpu: 1, memUsed: 1, memTotal: 2, gpu: 0, rx: 0, tx: 0, ready: true };
    page.pushReading(Object.assign({ ts: 1793900000000, gpuMem: 17.75 * GiB, gpuShared: 1.25 * GiB, gpuMemTotal: 24 * GiB }, base));
    const hist = vm.runInContext('hist', sandbox);
    assert.ok(Array.isArray(hist.vram) && Array.isArray(hist.vramShared), 'hist has vram and vramShared');
    const last = n => hist[n][hist[n].length - 1];
    assert.strictEqual(last('vram'), 17.75);
    assert.strictEqual(last('vramShared'), 1.25);
    const length = hist.vram.length;
    page.pushReading(Object.assign({ ts: 1793900001000, gpuMem: GiB }, base));   // a Server reading: no gpuShared
    assert.strictEqual(hist.vram.length, length + 1);
    assert.strictEqual(last('vram'), null);
    assert.strictEqual(last('vramShared'), null);
    assert.strictEqual(last('cpu'), 1);
  });
}
// #endregion 91

// #region 92 Memory detail and top programs (#92)
{
  // Block-scoped, so these names can't clash with the other regions'.
  const GiB = 2 ** 30;
  const dot = ' ' + String.fromCharCode(183) + ' ';
  const isFunction = name => assert.strictEqual(typeof page[name], 'function', 'app.js has a top-level function ' + name);

  test('T92-09 memDetailText: committed of the limit, paging, and amber at 90% committed', () => {
    isFunction('memDetailText');
    const r = page.memDetailText({ memCommit: 31 * GiB, memCommitLimit: 96 * GiB, memPageIn: 0 });
    assert.strictEqual(r.text, 'Committed 31 of 96 GB' + dot + 'paging 0 MB/s');
    assert.strictEqual(r.warn, false);
    assert.strictEqual(page.memDetailText({ memCommit: 90 * GiB, memCommitLimit: 100 * GiB, memPageIn: 0 }).warn, true);
    // No paging number yet (the first reading after a start): the commit part alone.
    assert.strictEqual(page.memDetailText({ memCommit: 31 * GiB, memCommitLimit: 96 * GiB, memPageIn: null }).text,
      'Committed 31 of 96 GB');
  });

  test('T92-10 topRowsHtml escapes program names and keeps the order; renderTopCard renders only into the element given', () => {
    isFunction('topRowsHtml');
    isFunction('renderTopCard');
    const evil = '<img src=x onerror=alert(1)>';
    const top = [
      { name: 'gameapp', count: 1, vram: 6 * GiB, mem: 1.8 * GiB, cpu: 25 },
      { name: evil, count: 1, vram: 1 * GiB, mem: 0.5 * GiB, cpu: null },   // cpu null: a program new since the last reading
      { name: 'browser', count: 3, vram: 0.6 * GiB, mem: 1.4 * GiB, cpu: 2.9 },
    ];
    const html = page.topRowsHtml(top);
    assert.strictEqual(typeof html, 'string');
    // The name shows as text, never as markup (Review Focus 2).
    assert.ok(!/<img/i.test(html), 'no <img element in ' + html);
    assert.ok(html.includes('&lt;img src=x onerror=alert(1)&gt;'), 'the name escaped by esc');
    // Rows in the order given (the server sorts them).
    const at = [html.indexOf('gameapp'), html.indexOf('&lt;img'), html.indexOf('browser')];
    assert.ok(at[0] >= 0 && at[0] < at[1] && at[1] < at[2], 'rows in order: ' + at.join(', '));
    // A grouped program shows its count in brackets; a single process shows none (spec section 1's sketch).
    assert.ok(html.includes('(3)'), 'browser (3)');
    assert.ok(!html.split('&lt;img src=x onerror=alert(1)&gt;').join('').includes('(1)'), 'no count for a single process');
    // The overlap line, and no total (spec section 5).
    assert.match(html, /share some video memory/);
    assert.ok(!/null|undefined|NaN/.test(html), 'a missing CPU number shows as nothing wrong: ' + html);

    // Render from the data passed in (spec section 8): only innerHTML and hidden on the element given.
    const set = [];
    const el = new Proxy(fakeElement(), { set: (t, k, v) => { set.push(k); t[k] = v; return true; } });
    page.renderTopCard(el, { top });
    assert.strictEqual(el.hidden, false);
    assert.strictEqual(el.innerHTML, page.topRowsHtml(top));
    page.renderTopCard(el, {});
    assert.strictEqual(el.hidden, true, 'hidden again without top');
    assert.ok(set.every(k => k === 'innerHTML' || k === 'hidden'), 'set only innerHTML and hidden: ' + set.join(', '));
  });

  test('T92-11 wslText: the WSL VM of its cap, amber at 90%, not running, running with no number, and a default cap', () => {
    isFunction('wslText');
    const w = page.wslText({ running: true, mem: 31.2 * GiB, cap: 48 * GiB, capSource: 'config' });
    assert.strictEqual(w.text, 'WSL VM 31.2 of 48 GB');
    assert.strictEqual(w.warn, false);
    assert.strictEqual(page.wslText({ running: true, mem: 9 * GiB, cap: 10 * GiB, capSource: 'config' }).warn, true);
    assert.strictEqual(page.wslText({ running: false, mem: null, cap: 48 * GiB, capSource: 'config' }).text, 'WSL VM: not running');
    assert.strictEqual(page.wslText({ running: true, mem: null, cap: 48 * GiB, capSource: 'config' }).text, 'WSL VM: running');
    const d = page.wslText({ running: true, mem: 12 * GiB, cap: 32 * GiB, capSource: 'default' });
    assert.match(d.title, /default/);
    assert.match(d.title, /half of RAM/);
  });
}
// #endregion 92

// #region 93 The AI server (#93)
// Spec section 6 (the states, "holds", "for 6 min", "last done"), section 7 and section 8 (render from data passed
// in); plan "The page": aiRowsHtml(ai, wsl, timeZone), renderAiCard(el, s), bannerFor. In a block, so its names
// never clash with another region's.
{
  const plain = x => JSON.parse(JSON.stringify(x));
  const GiB = 2 ** 30;
  // A row as Update-AiWatch makes it; off and starting rows carry no readings.
  const row = o => Object.assign({ name: 'Main', state: 'idle', queue: 0, workingSec: null, holds: Math.round(15.2 * GiB),
    vramTotal: Math.round(23.5 * GiB), vramFree: Math.round(8.4 * GiB), version: '0.3.99', lastDoneTs: null, lastDoneSec: null }, o);
  const bare = o => row(Object.assign({ queue: null, holds: null, vramTotal: null, vramFree: null, version: null }, o));
  const LABELS = { off: 'Off', starting: 'Starting', idle: 'Idle', working: 'Working', 'not-answering': 'Not answering', unknown: 'Unknown reply' };
  const word = label => new RegExp('(^|[^A-Za-z])' + label + '([^A-Za-z]|$)');
  const titles = html => Array.from(String(html).matchAll(/title="([^"]*)"/g), m => m[1]);
  const wsl = { running: true, mem: Math.round(31.2 * GiB), cap: 48 * GiB, capSource: 'config' };

  const states = [
    ['off', bare({ state: 'off' })],
    ['starting', bare({ state: 'starting' })],
    ['idle', row({ state: 'idle' })],
    ['working', row({ state: 'working', queue: 2, workingSec: 360 })],
    ['not-answering', row({ state: 'not-answering' })],
    ['unknown', bare({ state: 'unknown' })],
  ];
  for (const [state, r] of states) {
    test('T93-15 aiRowsHtml: ' + state + ' shows "' + LABELS[state] + '" and the entry name, and no other state', () => {
      const html = String(page.aiRowsHtml([r], null, 'UTC'));
      assert.match(html, word(LABELS[state]));
      assert.match(html, /Main/);
      for (const [other, label] of Object.entries(LABELS)) {
        if (other !== state && !LABELS[state].includes(label)) assert.doesNotMatch(html, word(label), state + ' row shows ' + label);
      }
      assert.doesNotMatch(html, /undefined|null|NaN/);
    });
  }

  test('T93-15 aiRowsHtml: working with queue 2 for 360 s, and queue 1', () => {
    assert.match(String(page.aiRowsHtml([row({ state: 'working', queue: 2, workingSec: 360 })], null, 'UTC')), /2 queued, for 6 min/);
    assert.match(String(page.aiRowsHtml([row({ state: 'working', queue: 1, workingSec: 360 })], null, 'UTC')), /1 queued/);
  });

  test('T93-15 aiRowsHtml: idle and working rows say "holds 15.2 GB"', () => {
    assert.match(String(page.aiRowsHtml([row({ state: 'idle' })], null, 'UTC')), /holds 15\.2 GB/);
    assert.match(String(page.aiRowsHtml([row({ state: 'working', queue: 2, workingSec: 360 })], null, 'UTC')), /holds 15\.2 GB/);
  });

  test('T93-15 aiRowsHtml: a lastDone is "last done 7:42 PM, 14 min", its time through fmtTime', () => {
    const ts = Date.UTC(2026, 10, 6, 19, 42);
    assert.strictEqual(page.fmtTime(ts, 'UTC'), '7:42 PM');
    const html = String(page.aiRowsHtml([row({ state: 'idle', lastDoneTs: ts, lastDoneSec: 840 })], null, 'UTC'));
    assert.match(html, /last done 7:42 PM, 14 min/);
    // On a working row too: the last batch stays shown while the next one runs (spec section 1's sketch).
    const working = String(page.aiRowsHtml([row({ state: 'working', queue: 2, workingSec: 360, lastDoneTs: ts, lastDoneSec: 840 })], null, 'UTC'));
    assert.match(working, /last done 7:42 PM, 14 min/);
  });

  test('T93-15 aiRowsHtml: each row has a title with the card as ComfyUI sees it (vramTotal, vramFree) and its version', () => {
    const a = row({ name: 'Main', vramTotal: Math.round(23.5 * GiB), vramFree: Math.round(8.4 * GiB), version: '0.3.99' });
    const b = row({ name: 'Second', vramTotal: Math.round(11.5 * GiB), vramFree: Math.round(2.5 * GiB), version: '0.4.1' });
    for (const [r, total, free, version] of [[a, '23.5', '8.4', '0.3.99'], [b, '11.5', '2.5', '0.4.1']]) {
      const t = titles(page.aiRowsHtml([r], null, 'UTC')).filter(x => x.includes(version));
      assert.ok(t.length >= 1, r.name + ': a title with the version ' + version);
      assert.ok(t.some(x => x.includes(total) && x.includes(free)), r.name + ': its title has ' + total + ' and ' + free + ' GB');
    }
  });

  test('T93-15 aiRowsHtml: HTML in a name or a ComfyUI version shows as text', () => {
    const evil = row({ name: '<img src=x onerror=alert(1)>', version: '<script>alert(1)</script>' });
    const html = String(page.aiRowsHtml([evil], wsl, 'UTC'));
    assert.doesNotMatch(html, /<img src=x|<script>/i);
    assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
    assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
    const quote = String(page.aiRowsHtml([row({ version: '0.3" onmouseover="alert(1)' })], null, 'UTC'));
    assert.doesNotMatch(quote, /"\s*onmouseover=/, 'a quote in the version never ends the title attribute');
  });

  test('T93-15 renderAiCard: hidden with no ai or an empty list; shown with two rows and the WSL VM row; sets only innerHTML and hidden', () => {
    const none = fakeElement();
    page.renderAiCard(none, { role: 'workstation', wsl });
    assert.strictEqual(none.hidden, true);
    const empty = fakeElement();
    page.renderAiCard(empty, { role: 'workstation', ai: [], wsl });
    assert.strictEqual(empty.hidden, true);
    const two = fakeElement();
    page.renderAiCard(two, { role: 'workstation', ai: [row({ name: 'Main' }), bare({ name: 'Second', state: 'off' })], wsl });
    assert.strictEqual(two.hidden, false);
    assert.match(two.innerHTML, /Main/);
    assert.match(two.innerHTML, /Second/);
    assert.match(two.innerHTML, /WSL VM/);
    assert.deepStrictEqual(Object.keys(two).sort(), ['hidden', 'innerHTML']);
    // From the data passed in, not the page's globals: a second host's card in another element is its own.
    const other = fakeElement();
    page.renderAiCard(other, { role: 'workstation', ai: [row({ name: 'Elsewhere' })], wsl: { running: false, mem: null, cap: 16 * GiB, capSource: 'default' } });
    assert.match(other.innerHTML, /Elsewhere/);
    assert.doesNotMatch(other.innerHTML, /Second/);
    assert.doesNotMatch(two.innerHTML, /Elsewhere/);
  });

  test('T93-16 bannerFor: ai-job-done (840 s) and ai-stopped-answering', () => {
    const done = plain(page.bannerFor({ id: 1, banner: true, type: 'ai-job-done', data: { name: 'Main', seconds: 840 } }));
    assert.strictEqual(done.title, 'AI job finished');
    assert.deepStrictEqual(done.lines, ['Main, took 14 min']);
    const stopped = plain(page.bannerFor({ id: 2, banner: true, type: 'ai-stopped-answering', data: { name: 'Main' } }));
    assert.strictEqual(stopped.title, 'AI server stopped answering during a job');
    assert.deepStrictEqual(stopped.lines, ['Main']);
  });
}
// #endregion 93

void test; void assert; void page; void fakeElement;
