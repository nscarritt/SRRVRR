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
// #endregion 90

// #region 91 Video memory and GPU detail (#91)
// #endregion 91

// #region 92 Memory detail and top programs (#92)
// #endregion 92

// #region 93 The AI server (#93)
// #endregion 93

void test; void assert; void page; void fakeElement;
