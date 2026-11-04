// T49-26 to T49-28: the page's history functions in web/app.js (the 60 s / 15 min graphs), run under Node.
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

function memoryStorage(initial) {
  const m = new Map(Object.entries(initial || {}));
  return { getItem: k => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), map: m };
}

test('T49-26 fillFromHistory fills every line and keeps missing seconds as gaps', () => {
  const json = { version: 1, newestMs: 5000, stepMs: 1000,
    lines: { cpu: [1, null, 3], mem: [40, 41, 42], gpu: [0, 0, null], rx: [10, 20, 30], tx: [5, 6, 7], other: [9] } };
  const h = app.fillFromHistory(json);
  assert.deepStrictEqual(Array.from(h.cpu), [1, null, 3]);
  assert.deepStrictEqual(Array.from(h.mem), [40, 41, 42]);
  assert.deepStrictEqual(Array.from(h.gpu), [0, 0, null]);
  assert.deepStrictEqual(Array.from(h.tx), [5, 6, 7]);
  assert.strictEqual(h.newestMs, 5000);
  assert.strictEqual(h.other, undefined);
});

test('T49-26 a reconnect (a failed poll, then a good one) asks for /history again', () => {
  assert.strictEqual(app.shouldRefetchHistory(true, true), true);
  assert.strictEqual(app.shouldRefetchHistory(false, true), false);
  assert.strictEqual(app.shouldRefetchHistory(true, false), false);
});

test('T49-27 rangeFromStorage: 60 unless 900 is stored; storage that throws gives 60; choosing writes it', () => {
  assert.strictEqual(app.rangeFromStorage(memoryStorage()), 60);
  assert.strictEqual(app.rangeFromStorage(memoryStorage({ 'srrvrr.range': '60' })), 60);
  assert.strictEqual(app.rangeFromStorage(memoryStorage({ 'srrvrr.range': '900' })), 900);
  assert.strictEqual(app.rangeFromStorage(memoryStorage({ 'srrvrr.range': 'abc' })), 60);
  assert.strictEqual(app.rangeFromStorage({ getItem: () => { throw new Error('blocked'); } }), 60);
  const s = memoryStorage();
  app.saveRange(s, 900);
  assert.strictEqual(s.map.get('srrvrr.range'), '900');
  assert.doesNotThrow(() => app.saveRange({ setItem: () => { throw new Error('blocked'); } }, 60));
});

test('T49-28 visibleSlice shows the last 60 or 900 values', () => {
  const buf = Array.from({ length: 900 }, (_, i) => i);
  assert.strictEqual(app.visibleSlice(buf, 60).length, 60);
  assert.strictEqual(app.visibleSlice(buf, 60)[59], 899);
  assert.strictEqual(app.visibleSlice(buf, 900).length, 900);
  assert.strictEqual(app.visibleSlice([1, 2], 60).length, 2);
});

test('T49-28 toSegments splits the line at missing values (a gap, not a drop to zero)', () => {
  const segs = app.toSegments([1, 2, null, null, 5, NaN, 7, 8]);
  assert.deepStrictEqual(segs.map(s => s.map(p => p.i)), [[0, 1], [4], [6, 7]]);
  assert.deepStrictEqual(segs.map(s => s.map(p => p.v)), [[1, 2], [5], [7, 8]]);
  assert.deepStrictEqual(app.toSegments([null, null]), []);
});
