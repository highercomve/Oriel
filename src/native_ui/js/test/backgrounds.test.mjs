// Drawing the page asks for that the backends had no props for: a conic
// gradient (wedges under the content), gradient layers of a set size and
// position (background-size/-position, no-repeat), an appearance: none
// checkbox's ::after (a switch's knob), a select's arrow left to the page,
// and a block-level button (no flex centering across, no gaps).
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><head><style>
  #donut { width: 100px; height: 100px; border-radius: 50%; background: conic-gradient(#2d6a4f 0% 70%, #8bbf5f 70% 100%); }
  #arrow { width: 200px; height: 52px; background-image: linear-gradient(45deg, transparent 50%, red 50%); background-position: calc(100% - 22px) 50%; background-size: 6px 6px; background-repeat: no-repeat; }
  #sw { appearance: none; width: 52px; height: 32px; position: relative; }
  #sw::after { content: ""; position: absolute; left: 6px; top: 6px; width: 16px; height: 16px; background: gray; }
  #sw:checked::after { left: 22px; }
  .chip select { appearance: none; } #own { appearance: none; background-image: linear-gradient(red, blue); }
  button { display: inline-flex; align-items: center; justify-content: center; gap: 8px; }
  #block { display: block; text-align: left; }
</style></head><body>
  <div id="donut"><span>$4</span></div><div id="arrow">x</div><input id="sw" type="checkbox" checked>
  <label class="chip"><select id="chip"><option>A</option></select></label><select id="own"><option>B</option></select>
  <button id="block"><p>Fixed</p><p>$3</p></button>
</body></html>`;
let ops = [];
const host = { asset: (n) => (n === "index.html" ? html : undefined), log() {}, now: () => 0, timer() {}, invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (j) => { ops = ops.concat(JSON.parse(j)); }, platform: '{"os":"linux"}', label: "main", url: "index.html" };
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const props = new Map(), kids = new Map();
for (const o of ops) { if (o[0] === "p") props.set(o[1], o[2]); else if (o[0] === "k") kids.set(o[1], o[2]); }
const withText = (t) => [...props].find(([, p]) => p.runs?.some((r) => r.t === t))?.[0];
const parentOf = (id) => [...kids].find(([, k]) => k.includes(id))?.[0];

// The donut: an icon of wedges under its text, clipped to the circle.
const donut = parentOf(withText("$4"));
const wedges = props.get(kids.get(donut)[0]);
assert.ok(wedges.icon?.shapes.length >= 2 && wedges.z === -1 && wedges.pos === "absolute", "conic wedges under the content");
assert.deepEqual(wedges.icon.shapes[0].fill, [45, 106, 79, 1]);
assert.equal(props.get(donut).clip, true);

// The arrow: a 6x6 box with its gradient, at calc(100% - 22px) 50%.
const layer = props.get(kids.get(parentOf(withText("x")))[0]);
assert.deepEqual([layer.w, layer.h, layer.ins[0], layer.ins[3], layer.tx, layer.ty], [6, 6, "50%", "100%", -28, -3]);
assert.equal(layer.bg.gradient.angle, 45);

// The switch: its ::after (checked: at left 22px) inside the box.
const knob = [...props.values()].find((p) => p.w === 16 && p.h === 16);
assert.deepEqual(knob?.ins, [6, null, null, 22], "the knob is drawn, where :checked puts it");

// Selects: no platform arrow when the page draws one beside it; kept when
// its arrow is its own background-image.
const selects = [...props.values()].filter((p) => p.options);
assert.equal(selects.find((p) => p.options[0][1] === "A").na, true);
assert.equal(selects.find((p) => p.options[0][1] === "B").na, undefined);

// A block button: its content centered in its height only; no gaps.
const button = props.get(parentOf(withText("Fixed")));
assert.equal(button.ai ?? "stretch", "stretch");
assert.equal(button.rg, undefined);
assert.equal(button.cg, undefined);
console.log("backgrounds: conic wedges, sized gradient layers, a switch's knob, select arrows and block buttons pass");
