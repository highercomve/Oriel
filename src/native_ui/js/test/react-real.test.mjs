// node test/react-real.test.mjs: React's onChange runs for a field the
// native side types into, a slider it moves and a checkbox it clicks.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import * as esbuild from "esbuild";

const app = esbuild.buildSync({
  entryPoints: [new URL("./react-real/app.jsx", import.meta.url).pathname],
  bundle: true, write: false, format: "iife", jsx: "automatic", logLevel: "error",
  define: { "process.env.NODE_ENV": '"production"' },
}).outputFiles[0].text;
const assets = { "index.html": '<!doctype html><html><body><div id="root"></div><script src="app.js"></script></body></html>', "app.js": app };

const nodes = new Map();
const timers = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => assets[p],
  invoke: () => {}, timer: (id) => timers.push(id), frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, true, true);
async function settle() {
  for (let i = 0; i < 6; i++) {
    await new Promise((r) => setTimeout(r, 0));
    for (const id of timers.splice(0)) ctx.__oriel.timer(id);
    ctx.__oriel.render();
  }
}
await settle();
const fields = [...nodes].filter(([, k]) => k === "input").map(([id]) => id);
assert.equal(fields.length, 2, "the text field and the slider are native fields");

ctx.__oriel.event(fields[0], "input", "new");
await settle();
assert.equal(ctx.__state.text, "new", "typing reaches onChange");

ctx.__oriel.event(fields[1], "input", "0.6");
await settle();
assert.equal(ctx.__state.range, 0.6, "moving the slider reaches onChange");

const box = [...nodes].filter(([, k]) => k === "view").map(([id]) => id).find((id) => {
  ctx.__oriel.event(id, "click", 0);
  return ctx.__state.checked;
});
await settle();
assert.ok(box !== undefined && ctx.__state.checked, "clicking the checkbox reaches onChange");
console.log("react (real): ok");
