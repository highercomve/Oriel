// node test/theme-color.test.mjs: <meta name="theme-color"> reaches the
// backend as oriel:window:setThemeColor, again only when it changes.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><head><meta name="theme-color" content="#336699"></head><body><p>hi</p></body></html>`;
const calls = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: (id, cmd, args) => { if (cmd === "oriel:window:setThemeColor") calls.push(JSON.parse(args)); },
  timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {}, ops: () => {},
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const flush = () => new Promise((r) => setTimeout(r, 0));
await flush();
assert.deepEqual(calls, [{ label: "main", color: [51, 102, 153, 255] }]);
vm.runInContext(`document.querySelector("meta").setAttribute("content", "rgba(255, 0, 0, 0.5)")`, ctx);
ctx.__oriel.render();
await flush();
assert.deepEqual(calls.at(-1), { label: "main", color: [255, 0, 0, 128] });
const n = calls.length;
vm.runInContext(`document.querySelector("p").textContent = "changed"`, ctx);
ctx.__oriel.render();
await flush();
assert.equal(calls.length, n, "no resend without a change");
vm.runInContext(`document.querySelector("meta").remove()`, ctx);
ctx.__oriel.render();
await flush();
assert.deepEqual(calls.at(-1), { label: "main", color: null });
console.log("theme color: ok");
