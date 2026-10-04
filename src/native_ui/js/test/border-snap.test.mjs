// node test/border-snap.test.mjs: border widths snap to device pixels as
// the platform's browser snaps them (render.js snapBorder): under one
// device pixel one, else floored; WebKit's from its 1/64px layout unit
// (measured in WKWebView: macOS 1x, the iOS simulator 3x), Chromium's from
// the width itself (1px at 2.625: 0.762; 3px: 2.667). The box's props,
// clientWidth and getComputedStyle all say the snapped width.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const W = [0.1, 0.34, 0.5, 0.7, 1, 1.4, 1.7, 2.67, 2.9, 3];
const page = `<html><body>${W.map((w, i) => `<div id="d${i}" style="width: 20px; height: 4px; border: ${w}px solid">x</div>`).join("")}</body></html>`;
function run(os, dpr) {
  const nodes = new Map();
  const host = {
    log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
    asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    frame: () => [0, 0, 20 + 2, 6, 6, 0, 0, 0],
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") nodes.set(id, { props: {} }); else if (k === "p") nodes.get(id).props = x; } },
    platform: JSON.stringify({ os, dpr }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, false, false);
  ctx.__oriel.render();
  const bws = [...nodes.values()].map((n) => n.props.bw).filter(Boolean).map((b) => +b[0].toFixed(6));
  const cs = W.map((_, i) => vm.runInContext(`getComputedStyle(document.getElementById("d${i}")).borderTopWidth`, ctx));
  return { bws, cs };
}
const r3 = (x) => +(x).toFixed(6);
// iOS at 3x (WKWebView, measured): 0.34px is 0 (its 1/64px unit holds 0.328).
let { bws, cs } = run("ios", 3);
assert.deepEqual(bws, [1 / 3, 1 / 3, 2 / 3, 1, 4 / 3, 5 / 3, 7 / 3, 8 / 3, 3].map(r3));
assert.deepEqual(cs, ["0.333333px", "0px", "0.333333px", "0.666667px", "1px", "1.333333px", "1.666667px", "2.333333px", "2.666667px", "3px"]);
// macOS at 1x (WKWebView, measured).
({ bws, cs } = run("macos", 1));
assert.deepEqual(bws, [1, 1, 1, 1, 1, 1, 1, 2, 2, 3]);
assert.deepEqual(cs.slice(0, 3), ["1px", "1px", "1px"]);
// Chromium at 2.625 (Android's): whole device pixels of the width itself.
({ bws } = run("android", 2.625));
assert.equal(bws[4], r3(2 / 2.625), "1px: 2 device px");
assert.equal(bws.at(-1), r3(7 / 2.625), "3px: 7 device px");
console.log("border snap: ok");
