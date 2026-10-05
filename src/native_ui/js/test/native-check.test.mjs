// node test/native-check.test.mjs: a backend that lists "check" in its
// platform JSON's controls gets checkboxes and radios as kind "check"
// (native widgets, no drawn focus ring); others keep the drawn view.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><input type="checkbox" checked><input type="radio" disabled><input type="checkbox" style="appearance:none"></body></html>`;
function kinds(platform) {
  const out = [];
  const host = {
    log: () => {}, asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { const k = new Map(); for (const [op, id, x] of JSON.parse(json)) { if (op === "c") k.set(id, x); else if (op === "p" && x.ctl) out.push([k.get(id), x]); } },
    platform: JSON.stringify(platform), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, false, false);
  ctx.__oriel.render();
  return out;
}
const native = kinds({ os: "linux", controls: ["check"] });
assert.deepEqual(native.map(([k]) => k), ["check", "check"], "the two default-appearance boxes are native");
assert.ok(native[0][1].on && native[1][1].dis, "with their state");
const drawn = kinds({ os: "linux" });
assert.deepEqual(drawn.map(([k]) => k), ["view", "view"], "without the capability they stay drawn");
console.log("native check: ok");
