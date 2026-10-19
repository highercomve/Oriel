// node test/grid-span.test.mjs: grid items placed by grid-column, as
// browsers auto-place them row by row: 1 / -1 and span N take their
// columns (their basis covering the gaps they span), an item that doesn't
// fit or whose start line is behind starts the next row, and columns a
// placement skips are left empty. Absolute children take no cell. A
// padded cell's row gives every fr cell the basis its padding needs (Yoga
// floors a basis at the padding; tracks don't), so the columns stay equal.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { withEngine } from "./engine-host.mjs";
import { gridColumn } from "../src/render.js";

assert.deepEqual(gridColumn({ "grid-column": "1 / -1" }, 3), { start: 0, span: 3 });
assert.deepEqual(gridColumn({ "grid-column": "span 2" }, 3), { start: null, span: 2 });
assert.deepEqual(gridColumn({ "grid-column": "2 / span 2" }, 3), { start: 1, span: 2 });
assert.deepEqual(gridColumn({ "grid-column-start": "3" }, 3), { start: 2, span: 1 });
assert.deepEqual(gridColumn({}, 3), { start: null, span: 1 });

const page = `<html><body>
<div style="display: grid; grid-template-columns: 1fr 1fr 1fr; column-gap: 10px; width: 300px">
<h2 style="position: absolute">hidden</h2><p id="wide" style="grid-column: 1 / -1">a</p><p>b</p><p style="grid-column: span 2">c</p><p>d</p><p style="grid-column: 3">e</p>
</div>
<div style="display: grid; grid-template-columns: 1fr 1fr 1fr; column-gap: 8px; width: 300px"><p style="padding: 0 12px">f</p><p>g</p><p>h</p><p style="padding: 0 6px">i</p></div></body></html>`;
const nodes = new Map(), kids = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => [0, 0, 10, 10, 10],
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, { kind: x, p: {} });
      else if (k === "p" && nodes.has(id)) Object.assign(nodes.get(id).p, x);
      else if (k === "k") kids.set(id, x);
    }
  },
  platform: JSON.stringify({ os: "android", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();

// The rows: views whose props say fd=row with cg 10, in order.
const rows = [...kids].filter(([id]) => nodes.get(id)?.p.fd === "row" && nodes.get(id)?.p.cg === 10).map(([, k]) => k.map((c) => [nodes.get(c)?.p.fg, nodes.get(c)?.p.fb]));
assert.deepEqual(rows, [
  [[3, 20]],                    // a: all three columns, two gaps in its basis
  [[1, 0], [2, 10]],            // b, then c spanning two
  [[1, 0], [1, 0], [1, 0]],     // d, an empty column, e at line 3
], "rows of placed cells");
const padded = [...kids].filter(([id]) => nodes.get(id)?.p.fd === "row" && nodes.get(id)?.p.cg === 8).map(([, k]) => k.map((c) => nodes.get(c)?.p.fb));
assert.deepEqual(padded, [[24, 24, 24], [12, 12, 12]], "each row's bases cover its widest padding");
console.log("grid span: ok");
