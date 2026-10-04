// node test/blank-click.test.mjs: a press and release on blank space (no
// node under the pointer) go to the root element and click it, as browsers do.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><p>short</p></body></html>`;
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {}, ops: () => {},
  platform: JSON.stringify({ os: "macos", arch: "aarch64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
vm.runInContext(`globalThis.seen = [];
  for (const t of ["pointerdown", "pointerup", "click"]) addEventListener(t, (e) => seen.push(t + ":" + e.target.localName));`, ctx);
ctx.__oriel.render();
const ev = (phase, buttons) => ctx.__oriel.event(0, "pointer", [phase, 50, 500, buttons, 1, "mouse", 0]);
ev("down", 1); ev("up", 0);
assert.deepEqual([...ctx.seen], ["pointerdown:html", "pointerup:html", "click:html"]);
// A right press on blank space: no click.
ctx.seen.length = 0;
ev("down", 2); ev("up", 0);
assert.deepEqual([...ctx.seen], ["pointerdown:html", "pointerup:html"]);
console.log("blank click: ok");
