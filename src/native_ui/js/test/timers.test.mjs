// Native timeout scheduling: cancellation, exceptions, and interval cadence.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

let clock = 0;
const scheduled = [], errors = [];
const host = {
  log: (level, message) => { if (level >= 3) errors.push(message); },
  asset: (path) => path === "index.html" ? "<!doctype html><html><body></body></html>" : undefined,
  invoke() {}, ops() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  now: () => clock, timer: (id, ms) => scheduled.push({ id, ms }),
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main",
};
const ctx = vm.createContext({ __host: host, advance: (ms) => { clock += ms; } });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
scheduled.length = 0;

vm.runInContext("globalThis.calls = 0; globalThis.self = setInterval(() => { calls++; clearInterval(self); }, 100);", ctx);
const self = scheduled.shift();
ctx.__oriel.timer(self.id);
assert.equal(ctx.calls, 1);
assert.equal(scheduled.length, 0, "self cancellation posts no extra native timeout");
ctx.__oriel.timer(self.id);
assert.equal(ctx.calls, 1, "an already delivered canceled timeout does nothing");

vm.runInContext("globalThis.cadence = setInterval((a, b) => { calls += a + b; advance(25); }, 100, 2, 3);", ctx);
const cadence = scheduled.shift();
ctx.__oriel.timer(cadence.id);
assert.equal(ctx.calls, 6);
assert.deepEqual(scheduled.shift(), { id: cadence.id, ms: 75 }, "callback time does not lengthen the interval");
vm.runInContext("clearInterval(cadence)", ctx);

vm.runInContext("globalThis.throwing = setInterval(() => { throw Error('repeat exception'); }, 20);", ctx);
const throwing = scheduled.shift();
ctx.__oriel.timer(throwing.id);
assert.equal(scheduled.shift().id, throwing.id, "an exception does not stop an active interval");
assert.ok(errors.some((error) => error.includes("repeat exception")));
vm.runInContext("clearInterval(throwing)", ctx);

vm.runInContext("globalThis.stopThrow = setInterval(() => { clearInterval(stopThrow); throw Error('stop exception'); }, 20);", ctx);
ctx.__oriel.timer(scheduled.shift().id);
assert.equal(scheduled.length, 0, "cancellation followed by an exception still avoids a timeout");

vm.runInContext("setTimeout(() => { calls++; }, 10)", ctx);
const once = scheduled.shift();
ctx.__oriel.timer(once.id);
ctx.__oriel.timer(once.id);
assert.equal(ctx.calls, 7, "one-shot callbacks execute once");
assert.equal(scheduled.length, 0);
console.log("native timer scheduling: ok");
