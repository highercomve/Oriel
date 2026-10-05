// node test/dark-controls.test.mjs: form controls in a dark color-scheme
// get dark defaults (as Chromium draws them) and dk for the native widget;
// a light page, or the page's own colors, keep theirs.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

function fields(dark, css) {
  const page = `<html><head><style>:root { color-scheme: light dark } ${css}</style></head><body><input id="i" value="x"><input type="checkbox"></body></html>`;
  const out = [];
  const host = {
    log: () => {}, asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { const k = new Map(); for (const [op, id, x] of JSON.parse(json)) { if (op === "c") k.set(id, x); else if (op === "p" && (x.ctl || x.ph !== undefined)) out.push(x); } },
    platform: JSON.stringify({ os: "android" }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, dark, false);
  ctx.__oriel.render();
  return out;
}
const [dIn, dBox] = fields(true, "");
assert.ok(dIn.dk && dBox.dk, "dark");
assert.deepEqual(dIn.bg.color, [59, 59, 59, 1]);
assert.deepEqual(dIn.col, [255, 255, 255, 1]);
const [lIn] = fields(false, "");
assert.ok(!lIn.dk && lIn.bg.color[0] === 255, "light keeps white");
const [own] = fields(true, "input { background: rgb(10, 20, 30); color: rgb(200, 0, 0) }");
assert.deepEqual(own.bg.color, [10, 20, 30, 1], "the page's own background kept");
assert.deepEqual(own.col, [200, 0, 0, 1], "and its color");
// The page itself: CanvasText white on the dark canvas (unstyled text).
{
  const page = `<html><head><style>:root { color-scheme: light dark }</style></head><body><p>hello</p></body></html>`;
  const props = new Map();
  const host = {
    log: () => {}, asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [op, id, x] of JSON.parse(json)) if (op === "p") props.set(id, x); },
    platform: JSON.stringify({ os: "android" }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, true, false);
  ctx.__oriel.render();
  assert.deepEqual(props.get(0).bg.color, [18, 18, 18, 1], "a dark canvas");
  const text = [...props.values()].find((p) => p.runs?.[0]?.t.trim() === "hello");
  assert.deepEqual(text.runs[0].c, [255, 255, 255, 1], "CanvasText is white");
}
console.log("dark controls: ok");
