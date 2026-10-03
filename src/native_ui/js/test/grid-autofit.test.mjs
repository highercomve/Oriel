// node test/grid-autofit.test.mjs: repeat(auto-fit, minmax(…, 1fr)) takes
// as many columns as fit the grid's content box, with a minimum that is a
// min()/max()/calc() of lengths and percentages of that width (the
// showcase's minmax(min(8em, 30%), 1fr): three in a 330 px box, not two).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<div id="g" style="display: grid; grid-template-columns: repeat(auto-fit, minmax(min(8em, 30%), 1fr)); gap: 4px; padding: 4px; width: 338px">
<button>a</button><button>b</button><button>c</button></div>
<div id="h" style="display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 4px; width: 330px">
<span>a</span><span>b</span><span>c</span></div>
</body></html>`;
const nodes = new Map();
const kids = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {},
  // Every box as wide as its CSS says (the grids 338 and 330 px).
  frame: (id) => (nodes.has(id) ? [0, 0, nodes.get(id).w ?? 0, 10, 10] : undefined),
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, { kind: x });
      else if (k === "p" && nodes.has(id)) nodes.get(id).w = x.w;
      else if (k === "k") kids.set(id, x);
      else if (k === "d") nodes.delete(id);
    }
  },
  platform: JSON.stringify({ os: "android", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
// The grid's width is known after a layout: render again, as each frame does.
vm.runInContext(`document.getElementById("g").setAttribute("data-x", "1"); document.getElementById("h").setAttribute("data-x", "1")`, ctx);
ctx.__oriel.render();

// Each grid's rows: its children, each a row of its cells.
const rowsOf = (w) => {
  const grid = [...nodes].find(([, n]) => n.w === w)?.[0];
  assert.ok(grid, `a grid ${w} px wide`);
  return (kids.get(grid) || []).map((r) => (kids.get(r) || []).length);
};
assert.deepEqual(rowsOf(338), [3], "min(8em, 30%) of a 330 px content box is 99 px: three columns");
assert.equal(rowsOf(330)[0], 2, "minmax(120px, 1fr) in 330 px: two columns");
assert.equal(rowsOf(330).length, 2, "and a second row");
console.log("grid auto-fit: ok");
