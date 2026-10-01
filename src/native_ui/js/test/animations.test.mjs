// node test/animations.test.mjs
import assert from "node:assert/strict";
import { StyleEngine } from "../src/css.js";
import { Animations, animationsOf } from "../src/animations.js";

const engine = new StyleEngine();
engine.addSheet(`
  @keyframes blink { 50% { opacity: 0; } }
  @keyframes from-right { from { opacity: 0; transform: translateX(28px); } }
  @keyframes spin { to { rotate: 360deg; } }
  .x:hover { color: red; } .y:active { opacity: .5; }`);
assert.deepEqual(Object.keys(engine.keyframes).sort(), ["blink", "from-right", "spin"]);
assert.equal(engine.keyframes.blink[0].offset, 0.5);
assert.ok(engine.rules.some((r) => r.sel === ".x[data-nui-hover]"));
assert.ok(engine.rules.some((r) => r.sel === ".y[data-nui-active]"));

const a = animationsOf({ animation: "blink 1s steps(1) infinite" }, engine.keyframes);
assert.equal(a.length, 1);
assert.equal(a[0].iter, Infinity);
assert.equal(animationsOf({ animation: "nope 1s" }, engine.keyframes), null);

// Blink: opaque the first half, transparent the second, forever.
const blink = { key: "blink", list: a, frames: [[{ offset: 0.5, props: { op: 0 } }]] };
const an = new Animations();
let out = an.apply(1, { op: 1 }, blink, 0);
assert.equal(out.op, 1);
out = an.apply(1, { op: 1 }, undefined, 600);
assert.equal(out.op, 0);
out = an.apply(1, { op: 1 }, undefined, 2200);
assert.equal(out.op, 1);
assert.equal(an.active, true);
// The same spec again (a re-render) doesn't restart it.
out = an.apply(1, { op: 1 }, blink, 2600);
assert.equal(out.op, 0);

// from-right: 0.22 s from (op 0, tx 28) to the element's own values.
const fr = animationsOf({ animation: "from-right .22s linear" }, engine.keyframes);
const spec = { key: "fr", list: fr, frames: [[{ offset: 0, props: { op: 0, tx: 28, ty: 0, sc: 1, rot: 0 } }]] };
const an2 = new Animations();
out = an2.apply(2, { fd: "column" }, spec, 1000);
assert.equal(out.op, 0);
assert.equal(out.tx, 28);
out = an2.apply(2, { fd: "column" }, undefined, 1110);
assert.ok(Math.abs(out.op - 0.5) < 1e-9 && Math.abs(out.tx - 14) < 1e-9, JSON.stringify(out));
out = an2.apply(2, { fd: "column" }, undefined, 1300);
assert.equal(out.op, undefined); // ended, no fill: the node's own props (none here)
assert.equal(an2.active, false);
// Removing the animation and adding it again restarts it.
an2.apply(2, { fd: "column" }, null, 1400);
out = an2.apply(2, { fd: "column" }, spec, 1500);
assert.equal(out.op, 0);

// alternate + fill forwards.
const alt = animationsOf({ animation: "spin 1s linear 2 alternate forwards" }, engine.keyframes);
const an3 = new Animations();
const sp = { key: "s", list: alt, frames: [[{ offset: 1, props: { rot: 360 } }]] };
an3.apply(3, {}, sp, 0);
assert.equal(an3.apply(3, {}, undefined, 500).rot, 180);
assert.equal(an3.apply(3, {}, undefined, 1250).rot, 270);
assert.equal(an3.apply(3, {}, undefined, 5000).rot, 0); // ended on an odd (reversed) iteration, held
console.log("animations: ok");
