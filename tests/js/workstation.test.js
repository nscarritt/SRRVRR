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
// #endregion 92

// #region 93 The AI server (#93)
// #endregion 93

void test; void assert; void page; void fakeElement;
