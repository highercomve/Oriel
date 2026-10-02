// Exercise the observer optimization in the actual bundle, including the
// distinction between the renderer's document observer and page observers.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { performance } from "node:perf_hooks";
import { parseHTML } from "../vendor/linkedom/esm/index.js";

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
  globalThis.foreign = document.createElementNS('http://www.w3.org/2000/svg', 'SVG');
  foreign.innerHTML = '<g><path d="M0 0L1 1" /></g>';
  foreign.firstElementChild.innerHTML = '<path d="M2 2L3 3" />';
  globalThis.template = document.createElement('template');
  template.innerHTML = '<span>template content</span>';
`, ctx);
const { document: referenceDocument } = parseHTML('<html><body></body></html>');
const referenceForeign = referenceDocument.createElementNS('http://www.w3.org/2000/svg', 'SVG');
referenceForeign.innerHTML = '<g><path d="M0 0L1 1" /></g>';
referenceForeign.firstElementChild.innerHTML = '<path d="M2 2L3 3" />';
assert.equal(ctx.foreign.innerHTML, referenceForeign.innerHTML, "foreign ancestry keeps the general parser");
assert.equal(ctx.foreign.firstElementChild.firstElementChild.namespaceURI, referenceForeign.firstElementChild.firstElementChild.namespaceURI);
assert.equal(ctx.template.content.firstChild.textContent, "template content", "templates keep their content fragment");
await Promise.resolve();
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
// The renderer's private hook marks immediately, so a synchronous layout
// flush cannot miss writes whose page-observer callback is still queued.
vm.runInContext("records.length = 0; globalThis.oldText = row.firstElementChild.firstChild; row.firstElementChild.textContent = 'immediate'", ctx);
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "immediate")), "text updates render before observer delivery");
assert.notEqual(ctx.oldText, ctx.row.firstElementChild.firstChild, "textContent still replaces the text node");
assert.equal(ctx.oldText.parentNode, null, "replaced text is detached");
await Promise.resolve();
assert.ok(ctx.records.some(r => r.removedNodes.includes(ctx.oldText)), "page observer sees removal of the old text node");
assert.ok(ctx.records.some(r => r.addedNodes.includes(ctx.row.firstElementChild.firstChild)), "page observer sees insertion of the new text node");
vm.runInContext("row.style.color = 'blue'", ctx);
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "immediate" && r.c[2] === 255)), "attribute/style updates render synchronously");
vm.runInContext("row.firstElementChild.textContent = 'changed'", ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "changed")), "connected text mutations are observed");
vm.runInContext("row.remove()", ctx);
await Promise.resolve();
ctx.__oriel.render();
assert.ok(![...props.values()].some(p => p.runs?.some(r => r.t === "changed")), "removals are observed after disconnection");
logs.length = 0;
vm.runInContext("row.firstElementChild.textContent = 'detached again'; row.style.color = 'red'", ctx);
ctx.__oriel.render();
assert.equal(logs.filter(s => s.startsWith("PROF render")).length, 0, "private mutation hooks ignore detached updates");
vm.runInContext("document.body.appendChild(row)", ctx);
ctx.__oriel.render();
assert.ok([...props.values()].some(p => p.runs?.some(r => r.t === "detached again" && r.c[0] === 255)), "reattachment renders final detached changes");
console.log("observer: detached construction, page observers, insertion, updates and removal pass");
