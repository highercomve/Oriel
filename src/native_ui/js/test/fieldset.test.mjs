// node test/fieldset.test.mjs: a fieldset whose first child is its legend
// says so (Props.lgd: the backend breaks the top border around it, the
// border through the legend's middle, as browsers draw it); the legend is
// a block as wide as its text, pulled up into the top border.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><fieldset id="a"><legend>Options</legend>x</fieldset><fieldset id="b"><div>no legend</div></fieldset></body></html>`;
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
  platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const sets = [...nodes.values()].filter((n) => n.props.bw?.[0] === 2 && n.props.pad);
assert.equal(sets.length, 2, "both fieldsets have the UA box");
const [a, b] = sets;
assert.equal(a.props.lgd, true, "its first child is its legend");
assert.equal(b.props.lgd, undefined);
const legend = nodes.get(a.kids[0]);
assert.ok(legend.props.m[0] < 0, "the legend is pulled up into the top border");
console.log("fieldset: ok");
