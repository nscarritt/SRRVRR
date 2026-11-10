// T78-18 and T78-19: the Transfers card's PC list and the unknown-PC banners (web/app.js), run under Node.
// The page functions are top-level declarations, so they are properties of the sandbox (not in module.exports).
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
const pcRowsHtml = sandbox.pcRowsHtml;
const plain = x => JSON.parse(JSON.stringify(x));

function pc(over) {
  return Object.assign({ name: null, address: '192.0.2.99', known: false, account: 'TESTLAB\\guest-user', smb: '3.1.1', signed: true,
    encrypted: false, readBps: 2048, writeBps: 0, openFiles: 3, writing: false, burst: false, folders: [] }, over);
}

test('T78-18 a named PC shows its name, an unknown PC its address in amber, with account, speeds and open files', () => {
  const html = pcRowsHtml({ reason: null, pcs: [pc({ name: 'Desk PC', address: '192.0.2.10', known: true }), pc({})] });
  assert.match(html, /Desk PC/);
  assert.match(html, /<span class="pcn unk"[^>]*>192\.0\.2\.99<\/span>/);
  assert.doesNotMatch(html, /<span class="pcn unk"[^>]*>Desk PC/);
  assert.match(html, /TESTLAB\\guest-user/);
  assert.match(html, /2\.0 KB\/s/);
  assert.match(html, /3 open files/);
});

test('T78-18 a writing PC has the writing mark, a PC in a burst is red', () => {
  const quiet = pcRowsHtml({ pcs: [pc({})] });
  assert.doesNotMatch(quiet, /pcw/);
  assert.doesNotMatch(quiet, /class="pc burst"/);
  const busy = pcRowsHtml({ pcs: [pc({ writing: true, burst: true })] });
  assert.match(busy, /<span class="pcw">writing<\/span>/);
  assert.match(busy, /class="pc burst"/);
});

test('T78-18 a row has its folders: share, path, count, writing', () => {
  const html = pcRowsHtml({ pcs: [pc({ folders: [{ share: 'Docs', path: 'Reports\\2026', files: 4, writing: true }, { share: 'Media', path: '', files: 1, writing: false }] })] });
  assert.match(html, /<b>Docs<\/b><span class="pcp">Reports\\2026<\/span><span>4 files<\/span><span class="pcw">writing<\/span>/);
  assert.match(html, /<b>Media<\/b><span class="pcp">\(top level\)<\/span><span>1 file<\/span>/);
});

test('T78-18 with an open set, only the open rows draw their folders', () => {
  const t = { pcs: [pc({ folders: [{ share: 'Docs', path: 'a', files: 1, writing: false }] })] };
  assert.doesNotMatch(pcRowsHtml(t, new Set()), /class="pcf"/);
  assert.match(pcRowsHtml(t, new Set(['192.0.2.99'])), /class="pcf"/);
});

test('T78-18 names and folders with markup are escaped', () => {
  const html = pcRowsHtml({ pcs: [pc({ name: '<b>x</b>', known: true, folders: [{ share: '<i>', path: '<script>', files: 1, writing: false }] })] });
  assert.doesNotMatch(html, /<b>x<\/b>/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;b&gt;x&lt;\/b&gt;/);
});

test('T78-18 no PCs says so; a reason is left to the card note; nothing without a transfers object', () => {
  assert.match(pcRowsHtml({ pcs: [], reason: null }), /No PCs connected to the shares\./);
  assert.strictEqual(pcRowsHtml({ pcs: [], reason: 'PCs and folders need administrator' }), '');   // the card's note says it, once
  assert.doesNotMatch(pcRowsHtml({ pcs: [], reason: 'PCs and folders need administrator' }), /No PCs connected/);
  const capped = pcRowsHtml({ pcs: [pc({})], reason: 'more than 5,000 open files' });
  assert.doesNotMatch(capped, /more than 5,000 open files/);   // the card's note says it, once
  assert.match(capped, /192\.0\.2\.99/);
  assert.strictEqual(pcRowsHtml(undefined), '');
});

test('T78-19 bannerFor names the unknown PC and its account', () => {
  const connected = plain(app.bannerFor({ type: 'unknown-pc', data: { pc: 'unknown', address: '192.0.2.99', account: 'TESTLAB\\guest-user' } }));
  assert.strictEqual(connected.title, 'Unknown PC 192.0.2.99 connected');
  assert.deepStrictEqual(connected.lines, ['Account: TESTLAB\\guest-user']);
  const writing = plain(app.bannerFor({ type: 'unknown-pc-write', data: { pc: 'unknown', address: '192.0.2.99', account: 'TESTLAB\\guest-user' } }));
  assert.strictEqual(writing.title, 'Unknown PC 192.0.2.99 is writing to the shares');
  assert.deepStrictEqual(writing.lines, ['Account: TESTLAB\\guest-user']);
});

test('T78-19 the Flagged list shows both with their titles and the account on hover', () => {
  const events = [
    { id: 2, time: 1793805000000, type: 'unknown-pc-write', severity: 'flag', data: { address: '192.0.2.99', account: 'TESTLAB\\guest-user' } },
    { id: 1, time: 1793804000000, type: 'unknown-pc', severity: 'warn', data: { address: '192.0.2.99', account: 'TESTLAB\\guest-user' } },
  ];
  const html = sandbox.flaggedHtml(events, 31, 'UTC');
  assert.match(html, /Unknown PC 192\.0\.2\.99 connected/);
  assert.match(html, /Unknown PC 192\.0\.2\.99 is writing to the shares/);
  assert.match(html, /Account: TESTLAB\\guest-user/);
});