// T47-31: the page's pure functions in web/app.js, run under Node (node --test tests/js).
// app.js runs its page code on load, so it's loaded into a sandbox where every browser object is a harmless stand-in.
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

test('T47-31 bits turns bytes per second into bits with a unit', () => {
  assert.strictEqual(typeof app.bits(125000), 'string');
  assert.match(app.bits(125000), /1(\.0)?\s*M/);
  assert.match(app.bits(0), /^0/);
});

test('T47-31 niceMax rounds the scale up to 1, 2 or 5 times a power of ten in bits, at least 100 kbit', () => {
  // It takes and returns bytes per second; the round number is in bits (bytes x 8).
  assert.strictEqual(app.niceMax(1000), 12500);      // 8 kbit -> the 100 kbit floor
  assert.strictEqual(app.niceMax(20000), 25000);     // 160 kbit -> 200 kbit
  assert.strictEqual(app.niceMax(70000), 125000);    // 560 kbit -> 1 Mbit
  for (const v of [3, 70, 1234, 99999, 3e6]) {
    const bits = app.niceMax(v) * 8;
    assert.ok(bits >= v * 8, `${bits} >= ${v * 8}`);
    const lead = bits / Math.pow(10, Math.floor(Math.log10(bits)));
    assert.ok([1, 2, 5].some(x => Math.abs(lead - x) < 1e-9), `${bits} bits starts with 1, 2 or 5`);
  }
});

test('T47-31 since reads seconds as days and hours', () => {
  assert.strictEqual(app.since(273600), '3 days, 4 hours');
});

test('T47-31 size counts in 1024s like Windows', () => {
  assert.match(app.size(1024 ** 3 * 931), /^931 GB$/);
  assert.match(app.size(1024 ** 4 * 7.3), /^7\.3 TB$/);
});

test('T47-31 speed shows bytes per second', () => {
  assert.strictEqual(app.speed(0), '0 B/s');
  assert.match(app.speed(812 * 1024), /^812 KB\/s$/);
});
