// node test/transitions.test.mjs
import assert from "node:assert/strict";
import { Transitions, transitionsOf } from "../src/transitions.js";

const spec = transitionsOf({ transition: "width .6s cubic-bezier(.2, .8, .2, 1), background .3s, opacity 200ms linear 100ms" });
assert.equal(spec.length, 3);
assert.deepEqual(spec[0].keys, ["w"]);
assert.equal(spec[0].dur, 600);
assert.equal(spec[2].delay, 100);
assert.equal(transitionsOf({ transition: "none" }), null);
assert.equal(transitionsOf({ transition: "transform 0s" }), null);

const tx = new Transitions();
// First appearance: no transition.
let out = tx.apply(1, { w: 0, op: 1 }, spec, 0);
assert.equal(out.w, 0);
assert.equal(tx.active, false);
// The page sets width 50% and opacity .2: on the way there.
out = tx.apply(1, { w: "50%", op: 0.2 }, spec, 1000);
assert.equal(out.w, "0%");
assert.equal(out.op, 1); // delayed 100 ms
assert.equal(tx.active, true);
out = tx.apply(1, tx.targets.get(1), null, 1200);
assert.ok(parseFloat(out.w) > 0 && parseFloat(out.w) < 50, out.w);
assert.ok(Math.abs(out.op - 0.6) < 1e-9, String(out.op)); // linear: halfway through its 200 ms after the 100 ms delay
out = tx.apply(1, tx.targets.get(1), null, 1700);
assert.equal(out.w, "50%");
assert.equal(out.op, 0.2);
assert.equal(tx.active, false);

// Colors and backgrounds.
const t2 = new Transitions();
const bs = transitionsOf({ transition: "background .3s linear" });
t2.apply(2, { bg: { color: [0, 0, 0, 1] } }, bs, 0);
out = t2.apply(2, { bg: { color: [200, 100, 0, 1] } }, bs, 10);
out = t2.apply(2, t2.targets.get(2), null, 160);
assert.deepEqual(out.bg.color.map(Math.round), [100, 50, 0, 1]);
// A new target mid-way starts from where it is.
out = t2.apply(2, { bg: { color: [0, 0, 0, 1] } }, bs, 160);
assert.deepEqual(out.bg.color.map(Math.round), [100, 50, 0, 1]);
out = t2.apply(2, t2.targets.get(2), null, 310);
assert.deepEqual(out.bg.color.map(Math.round), [50, 25, 0, 1]);
console.log("transitions: ok");
