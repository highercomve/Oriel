// node test/inline-block-line.test.mjs: an inline-block whose baseline is
// its bottom edge (nothing written in it) sits on its line's strut, as
// WKWebView lays it out (measured): a 10px box in a 12px font's line (12
// above the baseline, 3 below) is 2px down, the line 15px; at
// line-height 30px the half-leading above is floored (19 above, 11 below);
// boxes side by side line up their bottoms. host.fontMetrics gets the
// block's font family.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body style="font: 12px system-ui">
<div><span id="a" style="display: inline-block; width: 50px; height: 10px"></span></div>
<div style="line-height: 30px"><span style="display: inline-block; width: 50px; height: 10px"></span></div>
<div><span style="display: inline-block; width: 50px; height: 10px"></span><span style="display: inline-block; width: 50px; height: 20px"></span></div>
<div><span style="display: inline-block">text</span></div>
</body></html>`;
const nodes = new Map();
const asked = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  fontMetrics: (size, mono, family) => { asked.push(family); return [12, 3, 0]; },
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
      else if (k === "p") nodes.get(id).props = x;
      else if (k === "k") nodes.get(id).kids = x;
    }
  },
  platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const body = [...nodes.values()].find((n) => n.kids.length === 4);
const [one, tall, row, text] = body.kids.map((id) => nodes.get(id));
const box = (n) => nodes.get(n.kids[0]);
assert.deepEqual(box(one).props.m, [2, 0, 3, 0], "12 above the baseline, 3 below");
assert.deepEqual(box(tall).props.m, [9, 0, 11, 0], "30px line: 7 + 12 above, 11 below");
assert.equal(row.props.fd, "row");
for (const id of row.kids) assert.equal(nodes.get(id).props.as, "flex-end", "boxes side by side: bottoms on one line");
assert.equal(box(text).props.m, undefined, "a box with text in it keeps its text's baseline");
assert.ok(asked.includes("system-ui"), `the block's family: ${asked}`);
console.log("inline-block line: ok");
