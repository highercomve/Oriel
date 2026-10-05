// node test/anon-line.test.mjs: inline content beside blocks shares one
// line box (CSS's anonymous block): two buttons after a <div> sit in one
// row that wraps, a space apart, not one per row of the column.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><div><div>block</div> <button>Save</button> <button>Cancel</button></div>
<form><label style="display:block">Name</label><input size="10"><button>Go</button></form></body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
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
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const text = (id) => nodes.get(id)?.props.runs?.map((r) => r.t).join("").trim();
const labelOf = (id) => text(id) ?? nodes.get(id).kids.map(text).find(Boolean);
const rows = [...nodes.values()].filter((n) => n.props.fd === "row" && n.props.fw === "wrap");
const save = rows.find((n) => n.kids.map(labelOf).join(",") === "Save,Cancel");
assert.ok(save, "Save and Cancel share one line");
assert.equal(save.props.ai, "baseline");
assert.deepEqual(nodes.get(save.kids[1]).props.m, [0, 0, 0, 4.5], "a space apart");
const field = rows.find((n) => n.kids.some((k) => nodes.get(k).kind === "input"));
assert.ok(field && field.kids.length === 2, "the input and its button on one line, the block label above");
assert.equal(nodes.get(field.kids[1]).props.m?.[3] ?? 0, 0, "touching boxes: no space");
console.log("anon line: ok");
