// Exercise the observer optimization in the actual bundle, including the
// distinction between the renderer's document observer and page observers.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { performance } from "node:perf_hooks";

const logs = [], props = new Map();
const host = {
  asset: (name) => name === "index.html" ? '<html><head><style>.row { display: flex; color: red; }</style></head><body></body></html>' : undefined,
  log: (level, message) => logs.push(message), now: () => performance.now(), prof: true,
  timer() {}, invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
  ops(json) {
    for (const [op, id, value] of JSON.parse(json)) {
      if (op === "p") props.set(id, value);
      if (op === "d") props.delete(id);
    }
  },
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(800, 600, false, false);
ctx.__oriel.render();
logs.length = 0;

vm.runInContext(`
  globalThis.row = document.createElement('div');
  row.className = 'row';
  row.innerHTML = '<span>first</span><span>second</span>';
  row.style.padding = '4px';
  globalThis.records = [];
  globalThis.pageObserver = new MutationObserver(r => records.push(...r));
  pageObserver.observe(row, { subtree: true, childList: true, attributes: true });
  row.setAttribute('data-page', 'yes');
`, ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.equal(logs.filter(s => s.startsWith("PROF render")).length, 0, "detached construction does not dirty the renderer");
assert.ok(ctx.records.length > 0, "page observers still receive detached mutations");

vm.runInContext("document.body.appendChild(row)", ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "first")), "insertion renders the constructed subtree");
assert.ok([...props.values()].some(p => p.fd === "row"), "insertion computes the subtree's styles");
vm.runInContext("row.firstElementChild.textContent = 'changed'", ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "changed")), "connected text mutations are observed");
vm.runInContext("row.remove()", ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.ok(![...props.values()].some(p => p.runs?.some(r => r.t === "changed")), "removals are observed after disconnection");
console.log("observer: detached construction, page observers, insertion, updates and removal pass");
