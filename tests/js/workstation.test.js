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
// #endregion 91

// #region 92 Memory detail and top programs (#92)
// #endregion 92

// #region 93 The AI server (#93)
// #endregion 93

void test; void assert; void page; void fakeElement;
