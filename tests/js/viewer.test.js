// T79-09, T79-10: the page's part of "Maintenance limited to named PCs" (maintControl, viewerAfterError and the 403
// message in web/app.js), run under Node (node --test tests/js). app.js is loaded into the same kind of sandbox as
// app.test.js; top-level functions are properties of the sandbox, so nothing is added to module.exports.
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
const maintControl = sandbox.maintControl;
const viewerAfterError = sandbox.viewerAfterError;

test('T79-09 an unnamed viewer gets the box disabled, with the address the server saw, and no header', () => {
  const c = maintControl({ name: null, canChangeMaintenance: false, address: '192.0.2.99' });
  assert.strictEqual(c.disabled, true);
  assert.strictEqual(c.note, 'Maintenance can be changed from a named PC. This PC is seen as 192.0.2.99.');
  assert.strictEqual(c.header, '');
});

test('T79-09 an unnamed viewer with no address still gets a sentence', () => {
  const c = maintControl({ name: null, canChangeMaintenance: false, address: null });
  assert.strictEqual(c.disabled, true);
  assert.match(c.note, /^Maintenance can be changed from a named PC\. This PC is seen as .+\.$/);
});

test('T79-09 a named viewer has the box enabled and the header says Viewing from <name>', () => {
  const c = maintControl({ name: 'Desk PC', canChangeMaintenance: true, address: '192.0.2.10' });
  assert.strictEqual(c.disabled, false);
  assert.strictEqual(c.note, '');
  assert.strictEqual(c.header, 'Viewing from Desk PC');
});

test('T79-09 the server itself (no name, allowed) has the box enabled and no header', () => {
  const c = maintControl({ name: null, canChangeMaintenance: true, address: '127.0.0.1' });
  assert.deepStrictEqual({ ...c }, { disabled: false, note: '', header: '' });
});

test('T79-09 no viewer (an older server) is enabled as before', () => {
  for (const v of [undefined, null, 0, '', 'x']) {
    assert.deepStrictEqual({ ...maintControl(v) }, { disabled: false, note: '', header: '' });
  }
});

test('T79-09 only an explicit false disables the box (a viewer without the field is not locked out by the page)', () => {
  assert.strictEqual(maintControl({ name: null }).disabled, false);
});

test('T79-09 the state and end time still show for every viewer: maintenanceText does not depend on the viewer', () => {
  const m = { on: true, untilMs: Date.UTC(2026, 0, 5, 15, 30) };
  assert.match(app.maintenanceText(m, 'UTC'), /^Maintenance until /);
  assert.strictEqual(app.maintenanceText({ on: false, untilMs: null }, 'UTC'), '');
});

test('T79-09 a name or address from the server is only ever text: the note and header are plain strings', () => {
  const c = maintControl({ name: '<b>x</b>', canChangeMaintenance: true, address: '<i>' });
  assert.strictEqual(c.header, 'Viewing from <b>x</b>');
  assert.strictEqual(typeof c.note, 'string');
});

test('T79-10 maintenanceError(403) with not a named PC names the named-PC rule', () => {
  const t = app.maintenanceError(403, 'not a named PC');
  assert.match(t, /named PC/);
  assert.match(t, /403/);
});

test('T79-10 a plain 403, and the other statuses, keep their messages', () => {
  assert.strictEqual(app.maintenanceError(403), 'The server refused the change from this page (403).');
  assert.strictEqual(app.maintenanceError(403, 'refused'), 'The server refused the change from this page (403).');
  assert.match(app.maintenanceError(429), /^Too many changes/);
  assert.match(app.maintenanceError(400), /\(400\)/);
  assert.match(app.maintenanceError(0), /Could not reach SRRVRR/);
});

test('T79-10 after a not a named PC refusal the viewer cannot change Maintenance, so the box stays disabled', () => {
  const v = viewerAfterError({ name: null, canChangeMaintenance: true, address: '192.0.2.99' }, 403, 'not a named PC');
  assert.strictEqual(v.canChangeMaintenance, false);
  assert.strictEqual(v.address, '192.0.2.99');
  assert.strictEqual(maintControl(v).disabled, true);
  assert.match(maintControl(v).note, /192\.0\.2\.99/);
});

test('T79-10 other failures leave the viewer as it was, and an unnamed viewer stays unnamed', () => {
  const named = { name: 'Desk PC', canChangeMaintenance: true, address: '192.0.2.10' };
  assert.strictEqual(viewerAfterError(named, 429, ''), named);
  assert.strictEqual(viewerAfterError(named, 403, 'refused'), named);
  assert.strictEqual(viewerAfterError(named, 0, ''), named);
  const unnamed = { name: null, canChangeMaintenance: false, address: '192.0.2.99' };
  assert.strictEqual(viewerAfterError(unnamed, 403, 'not a named PC').canChangeMaintenance, false);
  assert.strictEqual(viewerAfterError(null, 403, 'not a named PC').canChangeMaintenance, false);
});
