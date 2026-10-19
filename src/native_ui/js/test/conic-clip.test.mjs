// A conic gradient draws only its first turn: stops far past it (or before
// it) are cut there, so a huge position makes no more wedges than a plain
// one, and an ordinary gradient is drawn as before.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><head><style>
  div { width: 100px; height: 100px; }
  #plain { background: conic-gradient(red 0turn, blue 1turn); }
  #huge { background: conic-gradient(red 0turn, blue 1000000000turn); }
  #inf { background: conic-gradient(red 0turn, blue ${"9".repeat(400)}turn); }
  #neg { background: conic-gradient(red -1000000000turn, blue 1turn); }
  #same { background: conic-gradient(from 1000000000turn, red 0turn, red 1000000000turn); }
  #many { background: conic-gradient(${Array.from({ length: 3000 }, (_, i) => `${i % 2 ? "red" : "blue"} ${i / 1000}turn`).join(",")}); }
</style></head><body><div id="plain">a</div><div id="huge">b</div><div id="inf">c</div><div id="neg">d</div><div id="same">e</div><div id="many">f</div></body></html>`;
let ops = [];
const host = { asset: (n) => (n === "index.html" ? html : undefined), log() {}, now: () => 0, timer() {}, invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (j) => { ops = ops.concat(JSON.parse(j)); }, platform: '{"os":"linux"}', label: "main", url: "index.html" };
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(800, 600, false, false);
ctx.__oriel.render();
const props = new Map(), kids = new Map();
for (const o of ops) { if (o[0] === "p") props.set(o[1], o[2]); else if (o[0] === "k") kids.set(o[1], o[2]); }
const withText = (t) => [...props].find(([, p]) => p.runs?.some((r) => r.t === t))?.[0];
const parentOf = (id) => [...kids].find(([, k]) => k.includes(id))?.[0];
const shapesOf = (t) => props.get(kids.get(parentOf(withText(t)))[0]).icon.shapes;

const plain = shapesOf("a");
assert.equal(plain.length, 180, "an ordinary gradient: a wedge every 2 degrees");
assert.ok(plain[0].fill[0] > 250 && plain[179].fill[2] > 250, "red to blue around the turn");

// Cut at the turn: about as many wedges as a plain one, the color at the cut
// blended from its (far) neighbour, so still nearly red.
const huge = shapesOf("b");
assert.ok(huge.length <= 185, `huge stop: ${huge.length} wedges`);
assert.ok(huge[huge.length - 1].fill[0] > 250, "the color at the cut is interpolated, not the stop's");
assert.ok(shapesOf("c").length <= 185, "an Infinity position");
assert.ok(shapesOf("d").length <= 185, "a huge negative position");
const same = shapesOf("e");
assert.ok(same.length <= 8, `a flat color is a few wedges: ${same.length}`);
assert.ok(same.every((s) => !s.d.includes("NaN")), "a huge `from` keeps its points");
assert.ok(shapesOf("f").length <= 512 + 2, "many stops are budgeted");
console.log("conic-clip: stops past the first turn are cut, and the shapes are budgeted");
