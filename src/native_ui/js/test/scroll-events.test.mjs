// node test/scroll-events.test.mjs: the engine's __oriel.scrolled fires
// "scroll" on the scroller (not bubbling) and, for the window (-1), on the
// document then the window; scrollTop/scrollLeft and scrollY read the
// offsets host.frame gives; setting them asks host.scrollTo.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><div id="box" style="overflow: auto; height: 50px"><div style="height: 500px">x</div></div><script>
globalThis.seen = [];
document.getElementById("box").addEventListener("scroll", (e) => seen.push("box " + e.bubbles));
document.body.addEventListener("scroll", () => seen.push("body (bubbled)"));
document.addEventListener("scroll", () => seen.push("document"));
addEventListener("scroll", () => seen.push("window"));
</script></body></html>`;
const nodes = new Map();
const offsets = new Map(); // id -> [top, left]
const asked = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {},
  frame: (id) => { const o = offsets.get(id) || [0, 0]; return [0, 0, 100, 50, 500, 0, o[0], o[1]]; },
  focus: () => {}, scrollIntoView: () => {},
  scrollTo: (id, y, x) => asked.push([id, y, x]),
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "windows", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
vm.runInContext(`globalThis.__nui_box = document.getElementById("box")`, ctx);
// The box's id: the one host.frame is asked for by its scrollTop.
let readId = null;
host.frame = ((f) => (id) => { readId = id; return f(id); })(host.frame);
vm.runInContext(`__nui_box.scrollTop`, ctx);
const id = readId;
assert.ok(typeof id === "number" && id > 0, "the box is a node");
offsets.set(id, [120, 0]);
offsets.set(-1, [30, 5]);
ctx.__oriel.scrolled([[id, 120, 0], [-1, 30, 5]]);
assert.deepEqual([...ctx.seen], ["box false", "document", "window"], "scroll on the box (no bubbling), then the document and the window");
assert.equal(vm.runInContext(`__nui_box.scrollTop`, ctx), 120);
assert.deepEqual([...vm.runInContext(`[scrollY, pageYOffset, scrollX, document.documentElement.scrollTop, document.scrollingElement.scrollTop]`, ctx)], [30, 30, 5, 30, 30]);
vm.runInContext(`__nui_box.scrollTop = 40; scrollTo(0, 99); __nui_box.scrollBy({ top: 10 });`, ctx);
assert.deepEqual(asked.map(([i, y, x]) => [i === id ? "box" : i, y, x === undefined || Number.isNaN(x) ? "-" : x]), [["box", 40, "-"], [-1, 99, 0], ["box", 130, 0]]);
console.log("scroll events: ok");
