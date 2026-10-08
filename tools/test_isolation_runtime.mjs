// Exercise the actual embedded isolation runtime without ancestorOrigins.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import vm from 'node:vm';
const source = readFileSync(new URL('../src/core/isolation.zig', import.meta.url), 'utf8');
function zigString(name) {
  const section = source.split(`const ${name} =`)[1]?.split('\n;')[0];
  assert.ok(section, name);
  return section.split('\n').filter(line => line.trimStart().startsWith('\\\\')).map(line => line.trimStart().slice(2)).join('\n');
}
const parents = ['app://app', 'http://localhost:5173'];
const messages = [];
const parent = { postMessage: (data, origin) => messages.push({ data, origin }) };
let onMessage;
const window = { parent, top: parent };
const ctx = vm.createContext({
  window, location: {}, crypto: webcrypto, TextEncoder, Uint8Array,
  atob: value => Buffer.from(value, 'base64').toString('binary'),
  document: { querySelector: () => ({ content: 'key-id.' + Buffer.alloc(32, 7).toString('base64'), remove() {} }) },
  addEventListener: (name, fn) => { assert.equal(name, 'message'); onMessage = fn; },
});
vm.runInContext(zigString('runtime_head') + JSON.stringify(parents) + zigString('runtime_js'), ctx);
ctx.__ORIEL_ISOLATION_HOOK__ = call => call;
assert.equal(messages.length, 2);
assert.ok(messages.every(m => parents.includes(m.origin) && m.data.ready));
messages.length = 0;
const data = { id: 'request', cmd: 'ping', a: '{}' };
onMessage({ source: parent, origin: 'https://evil.example', data });
onMessage({ source: {}, origin: parents[0], data });
await new Promise(resolve => setTimeout(resolve, 30));
assert.equal(messages.length, 0, 'untrusted parent/source must not obtain a seal');
onMessage({ source: parent, origin: parents[0], data });
for (let i = 0; i < 100 && messages.length === 0; i++) await new Promise(resolve => setTimeout(resolve, 10));
assert.equal(messages.length, 1);
assert.equal(messages[0].origin, parents[0]);
assert.equal(messages[0].data.id, 'request');
assert.match(messages[0].data.mac, /^[0-9a-f]{64}$/);
console.log('Isolation runtime rejects untrusted senders and targets replies without ancestorOrigins.');
