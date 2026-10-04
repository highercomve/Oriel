// node test/margin-collapse.test.mjs: vertical margins collapse as
// WKWebView collapses them (measured): body's with its first child's (the
// root's flex item here, a block in a browser), and an empty block's own
// top and bottom with those around it (12px and 18px between two blocks:
// one 18px gap).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body style="margin: 10px"><p id="first" style="margin: 16px 0">first</p>
<div id="box"><div id="a" style="height: 10px"></div><div id="e" style="margin: 12px 0 18px"></div><div id="b" style="height: 10px"></div></div>
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
  platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const all = [...nodes.values()];
const body = all.find((n) => n.props.m && n.props.m[3] === 10);
assert.equal(body.props.m[0], 16, "body's 10px top margin collapses with its first child's 16px");
const first = nodes.get(body.kids[0]);
assert.equal(first.props.m?.[0] ?? 0, 0, "the child's went into body's");
const views = all.filter((n) => n.kind === "view" && n.props.h === 10);
assert.equal(views.length, 2);
const [a, b] = views;
const empty = all.find((n) => n.kind === "view" && !n.kids.length && n.props.h === undefined && n.props.m);
const gap = (a.props.m?.[2] ?? 0) + (empty.props.m[0] ?? 0) + (empty.props.m[2] ?? 0) + (b.props.m?.[0] ?? 0);
assert.equal(gap, 18, "12px and 18px through an empty block: one 18px gap");
assert.equal((a.props.m?.[2] ?? 0) + (empty.props.m[0] ?? 0), 12, "the empty block sits at its top margin, as WebKit places it");
console.log("margin collapse: ok");
