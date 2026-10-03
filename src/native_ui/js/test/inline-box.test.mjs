// node test/inline-box.test.mjs: a padded, bordered or rounded inline
// element amid the text (a <code> chip) gives its runs an `ib` decoration
// (padding, margins, border widths and color, radii, its background, a key
// per element that stays across renders); its own background goes with it,
// off the runs; two like chips side by side are two boxes.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<p id="p">Kept in (<code style="padding: 2px 6px; border-radius: 5px; background: #eef1f8; margin-right: 3px">oriel.sql</code>) and
<span style="border: 1px solid #6d8bff; padding: 0 4px">one</span><span style="border: 1px solid #6d8bff; padding: 0 4px">two</span> and <b>plain</b>.</p>
</body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
      else if (k === "p") nodes.get(id).props = x;
      else if (k === "k") nodes.get(id).kids = x;
    }
  },
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(600, 400, false, false);
ctx.__oriel.render();

const runsOf = () => [...nodes.values()].map((n) => n.props.runs).find((r) => r && r.some((x) => x.t === "oriel.sql"));
const runs = runsOf();
const chip = runs.find((r) => r.t === "oriel.sql");
assert.deepEqual(chip.ib.p, [2, 6, 2, 6]);
assert.deepEqual(chip.ib.m, [0, 3, 0, 0]);
assert.deepEqual(chip.ib.br, [5, 5, 5, 5]);
assert.deepEqual(chip.ib.bg, [238, 241, 248, 1]);
assert.equal(chip.bg, undefined, "the chip's own background is the box's, not the run's");
assert.equal(chip.ib.bw, undefined);
const one = runs.find((r) => r.t === "one"), two = runs.find((r) => r.t === "two");
assert.deepEqual(one.ib.bw, [1, 1, 1, 1]);
assert.deepEqual(one.ib.bc, [109, 139, 255, 1]);
assert.notEqual(one.ib.k, two.ib.k, "two like boxes side by side stay two");
assert.equal(runs.find((r) => r.t === "plain").ib, undefined);
// The keys stay across a re-render (a changed one would remeasure the text).
const k = chip.ib.k;
vm.runInContext(`document.getElementById("p").append(" more")`, ctx);
ctx.__oriel.render();
assert.equal(runsOf().find((r) => r.t === "oriel.sql").ib.k, k);
console.log("inline boxes: ok");
