// T76-17, T76-18: the Transfers card's page functions in web/app.js, run under Node (node --test tests/js).
// Loaded as app.test.js does: app.js runs its page code on load in a sandbox of harmless stand-ins. Top-level
// functions of app.js are properties of the sandbox; they aren't in module.exports.
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
const app = sandbox.module.exports;
const page = sandbox;

const link = {percent: 94, bytesPerSec: 117500000, speedBits: 1e9};
const drive = {letter: 'D:', percent: 98, queue: 4};
const cpu = {percent: 91};

test('T76-17 bottleneckText names the network link with its percent of the link speed', () => {
  const t = page.bottleneckText({name: 'link', percent: 94, link, drive, cpu});
  assert.strictEqual(t.line, 'Bottleneck: the network link, 94% of 1 Gb/s');
});

test('T76-17 bottleneckText names the share\'s drive with its letter, busy percent and queue', () => {
  const t = page.bottleneckText({name: 'drive', percent: 98, link, drive, cpu});
  assert.strictEqual(t.line, 'Bottleneck: the share\'s drive (D:), 98% busy, queue 4');
});

test('T76-17 bottleneckText names the CPU', () => {
  const t = page.bottleneckText({name: 'cpu', percent: 91, link, drive, cpu});
  assert.strictEqual(t.line, 'Bottleneck: the CPU, 91%');
});

test('T76-17 bottleneckText says not the server, and idle', () => {
  assert.strictEqual(page.bottleneckText({name: 'none', percent: 79.9, link, drive, cpu}).line, 'Not the server: the client or the path to it');
  assert.strictEqual(page.bottleneckText({name: 'idle', percent: null, link, drive: null, cpu}).line, 'Idle');
});

test('T76-17 the small print always has the three numbers, whatever the name', () => {
  for (const name of ['link', 'drive', 'cpu', 'none']) {
    const small = page.bottleneckText({name, percent: 90, link, drive, cpu}).small;
    assert.match(small, /Link 94% of 1 Gb\/s/);
    assert.match(small, /Drive D: 98% busy, queue 4/);
    assert.match(small, /CPU 91%/);
  }
});

test('T76-17 the small print says n/a for a number the server could not give', () => {
  const small = page.bottleneckText({name: 'idle', percent: null, link: null, drive: null, cpu}).small;
  assert.match(small, /Link n\/a/);
  assert.match(small, /Drive n\/a/);
  assert.match(small, /CPU 91%/);
});

test('T76-17 link speeds read as Gb/s, Mb/s and Kb/s', () => {
  assert.strictEqual(page.linkSpeed(1e9), '1 Gb/s');
  assert.strictEqual(page.linkSpeed(2.5e9), '2.5 Gb/s');
  assert.strictEqual(page.linkSpeed(1e8), '100 Mb/s');
  assert.strictEqual(page.linkSpeed(5e5), '500 Kb/s');
});

test('T76-17 a named resource is amber, red from 95%; not the server and idle are quiet', () => {
  assert.strictEqual(page.bottleneckTone({name: 'link', percent: 94}), 'warn');
  assert.strictEqual(page.bottleneckTone({name: 'cpu', percent: 95}), 'hot');
  assert.strictEqual(page.bottleneckTone({name: 'none', percent: 70}), 'quiet');
  assert.strictEqual(page.bottleneckTone({name: 'idle', percent: null}), 'quiet');
});

test('T76-18 shareRowsHtml has a row per share with its drive, speeds and open files, and escapes the name', () => {
  const html = page.shareRowsHtml({available: true, reason: null, shares: [
    {name: 'projects', drive: 'D:', readBps: 3 * 1048576, writeBps: 0, openFiles: 4},
    {name: 'a<b>&"c', drive: null, readBps: 0, writeBps: 2048, openFiles: 1},
  ]});
  assert.strictEqual((html.match(/<tr>/g) || []).length, 2);
  assert.match(html, /projects/);
  assert.match(html, /D:/);
  assert.match(html, /3\.0 MB\/s/);
  assert.match(html, /2\.0 KB\/s/);
  assert.match(html, /<td>4<\/td>/);
  assert.ok(html.includes('a&lt;b&gt;&amp;&quot;c'), 'the name is escaped');
  assert.ok(!html.includes('<b>'), 'no raw markup from a share name');
});

test('T76-18 shareRowsHtml says why when the counters are not available, and when nothing moves', () => {
  const off = page.shareRowsHtml({available: false, reason: 'SMB counters are not available', shares: []});
  assert.match(off, /SMB counters are not available/);
  assert.strictEqual((off.match(/<tr>/g) || []).length, 1);
  const quiet = page.shareRowsHtml({available: true, reason: null, shares: []});
  assert.match(quiet, /No share traffic or open files/);
});

test('T76-18 fillFromHistory fills smbRead and smbWrite, and leaves them empty for a history without them', () => {
  const h = app.fillFromHistory({newestMs: 5000, lines: {cpu: [1, 2], smbRead: [10, null, 30], smbWrite: [0, 5]}});
  assert.deepStrictEqual(Array.from(h.smbRead), [10, null, 30]);
  assert.deepStrictEqual(Array.from(h.smbWrite), [0, 5]);
  const old = app.fillFromHistory({newestMs: 5000, lines: {cpu: [1, 2]}});
  assert.deepStrictEqual(Array.from(old.smbRead), []);
  assert.deepStrictEqual(Array.from(old.smbWrite), []);
});

test('T76-18 the shares\' totals for the graph come from the share rows, and are null when unavailable', () => {
  const t = {available: true, shares: [{readBps: 100, writeBps: 5}, {readBps: 50, writeBps: 0}]};
  assert.deepStrictEqual({...page.smbTotals(t)}, {read: 150, write: 5});
  assert.strictEqual(page.smbTotals({available: false, shares: []}), null);
  assert.strictEqual(page.smbTotals(undefined), null);
});

test('T76-18 the graph scale is a round number of bytes per second, at least 100 KB/s', () => {
  assert.strictEqual(page.niceBytes(0), 100 * 1024);
  assert.strictEqual(page.niceBytes(5 * 1048576), 5 * 1048576);
  assert.strictEqual(page.niceBytes(3 * 1048576), 5 * 1048576);
  assert.strictEqual(page.niceBytes(120 * 1048576), 200 * 1048576);
  for (const v of [1, 2e5, 7.7e6, 4e8, 2e9]) assert.ok(page.niceBytes(v) >= v, `${v} fits its scale`);
});