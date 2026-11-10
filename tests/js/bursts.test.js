// T77-15: the page's banners and Flagged rows for write bursts (web/app.js), run under Node (node --test tests/js).
// app.js runs its page code on load, so it's loaded into a sandbox where every browser object is a harmless stand-in;
// its top-level functions are then properties of the sandbox.
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
// Copied out of the sandbox: its arrays have their own Array prototype, which deepStrictEqual rejects.
const plain = x => JSON.parse(JSON.stringify(x));

function burst(id, type, data, extra) {
  return Object.assign({ id, time: 1793805000000 + id, type, severity: 'flag', key: type + '|192.0.2.10|1', data,
    maintenance: false, banner: type === 'write-burst', logged: true }, extra || {});
}
const named = {
  pc: 'Desk PC', address: '192.0.2.10', account: 'EXAMPLE\\maria', shares: ['Code', 'Photos'], files: 612, bytes: 7340032, startMs: 5000,
  folders: [
    { share: 'Photos', path: 'Trips\\2026', files: 300 }, { share: 'Photos', path: 'Trips', files: 200 }, { share: 'Code', path: 'a', files: 50 },
    { share: 'Code', path: 'b', files: 40 }, { share: 'Code', path: 'c', files: 30 }, { share: 'Code', path: 'd', files: 20 },
  ],
};
const unelevated = { pc: 'a PC (needs administrator)', session: '42', shares: ['Code'], files: 700, bytes: 1024, startMs: 5000 };

test('T77-15 a burst from a named PC: its name, files, shares and at most 5 folders', () => {
  const b = plain(sandbox.bannerFor(burst(1, 'write-burst', named)));
  assert.strictEqual(b.title, 'Write burst from Desk PC');
  assert.ok(b.lines.includes('612 files opened, 7 MB written so far'));
  assert.ok(b.lines.includes('Shares: Code, Photos'));
  assert.ok(b.lines.some(l => /192\.0\.2\.10/.test(l) && /EXAMPLE\\maria/.test(l)));
  const folders = b.lines.filter(l => /\(\d+ files?\)$/.test(l) && !/opened/.test(l));
  assert.strictEqual(folders.length, 5);
  assert.strictEqual(folders[0], 'Photos\\Trips\\2026 (300 files)');
  assert.ok(!b.lines.some(l => /\bd \(20 files\)/.test(l)), 'a sixth folder is left out');
});

test('T77-15 a burst from an unelevated copy says a PC (needs administrator), with no folders', () => {
  const b = plain(sandbox.bannerFor(burst(2, 'write-burst', unelevated)));
  assert.strictEqual(b.title, 'Write burst from a PC (needs administrator)');
  assert.ok(b.lines.includes('700 files opened, 1 KB written so far'));
  assert.ok(b.lines.includes('Shares: Code'));
  assert.strictEqual(b.lines.length, 2);
});

test('T77-15 an unknown PC shows its address and account', () => {
  const b = plain(sandbox.bannerFor(burst(3, 'write-burst', { pc: 'unknown', address: '192.0.2.77', account: 'EXAMPLE\\guest', shares: [], files: 501, bytes: 0, folders: [] })));
  assert.strictEqual(b.title, 'Write burst from unknown');
  assert.ok(b.lines.includes('Address 192.0.2.77, account EXAMPLE\\guest'));
});

test('T77-15 the ended text has the files, bytes and duration, and says when SRRVRR stopped', () => {
  const quiet = plain(sandbox.bannerFor(burst(4, 'write-burst-ended', Object.assign({}, named, { durationSeconds: 1500, reason: 'quiet' }), { banner: false })));
  assert.strictEqual(quiet.title, 'Write burst from Desk PC ended');
  assert.ok(quiet.lines.includes('612 files opened, 7 MB written, over 25 minutes'));
  assert.ok(!quiet.lines.some(l => /Photos\\Trips/.test(l)), 'folders are in the start banner only');
  const stopped = plain(sandbox.bannerFor(burst(5, 'write-burst-ended', Object.assign({}, unelevated, { durationSeconds: 45, reason: 'stopped' }), { banner: false })));
  assert.strictEqual(stopped.title, 'Write burst from a PC (needs administrator) ended (SRRVRR stopped)');
  assert.ok(stopped.lines.includes('700 files opened, 1 KB written, over 45 seconds'));
});

test('T77-15 an event with little data still gets a title, and the Flagged list shows both types', () => {
  assert.strictEqual(plain(sandbox.bannerFor(burst(6, 'write-burst', {}))).title, 'Write burst from a PC');
  const html = sandbox.flaggedHtml([burst(7, 'write-burst', named), burst(8, 'write-burst-ended', Object.assign({}, named, { durationSeconds: 90, reason: 'quiet' }), { banner: false })], 31, 'UTC');
  assert.match(html, /Write burst from Desk PC ended/);
  assert.match(html, /Write burst from Desk PC</);
  assert.match(html, /class="fsev flag"/);
});
