// node test/window-click.test.mjs: a click reaches the window's listeners
// last (a page delegating its clicks from window), unless stopped.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<ul id="menu"><li data-action="echo">Echo again</li><li data-action="open">New window</li></ul>
<p id="stop">stopped here</p>
</body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
vm.runInContext(`
  globalThis.seen = [];
  globalThis.stopped = 0;
  addEventListener("click", (e) => {
    const item = e.target.closest("#menu li");
    seen.push(item ? item.dataset.action : e.target.closest("[id]")?.id ?? e.target.localName);
  });
  document.getElementById("stop").addEventListener("click", (e) => { stopped++; e.stopPropagation(); });
`, ctx);
ctx.__oriel.render();

// Click every node: the menu's items reach the window's listener as
// themselves; the paragraph that stops its clicks never does.
for (const id of nodes.keys()) ctx.__oriel.event(id, "click", 0);
const seen = [...ctx.seen];
assert.ok(seen.includes("echo") && seen.includes("open"), `menu items reach window listeners: ${seen}`);
assert.ok(ctx.stopped > 0, "the paragraph was clicked");
assert.ok(!seen.includes("stop"), "a stopped click doesn't reach the window");
console.log("window click: ok");
