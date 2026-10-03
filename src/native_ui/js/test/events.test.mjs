// Exercise lazy listener allocation in the actual QuickJS runtime bundle.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

let maps = 0;
class CountedMap extends Map { constructor(...args) { super(...args); maps++; } }
const host = {
  asset: name => name === "index.html" ? '<html><body></body></html>' : undefined,
  log() {}, now: () => 0, timer() {}, invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {}, ops() {},
  platform: '{"os":"linux"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host, Map: CountedMap });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(800, 600, false, false);
ctx.__oriel.render();
const before = maps;
vm.runInContext(`
  for (let i = 0; i < 1000; i++) {
    document.createTextNode('text');
    document.createElement('span');
    document.createAttribute('data-empty');
  }
`, ctx);
assert.equal(maps, before, "listener-free DOM creation allocates no Maps");
vm.runInContext(`
  globalThis.calls = [];
  const parent = document.createElement('div'), child = document.createElement('span');
  parent.appendChild(child);
  child.removeEventListener('click', () => {}); // no map exists yet
  child.dispatchEvent(new Event('click', { bubbles: true }));
  const removed = () => calls.push('removed');
  child.addEventListener('click', removed);
  child.removeEventListener('click', removed);
  child.addEventListener('click', function(e) { calls.push('child:' + (this === child)); });
  child.addEventListener('click', () => calls.push('once'), { once: true });
  parent.addEventListener('click', { handleEvent() { calls.push('parent'); } });
  child.dispatchEvent(new Event('click', { bubbles: true }));
  child.dispatchEvent(new Event('click', { bubbles: true }));
  globalThis.target = new EventTarget();
  target.removeEventListener('custom', removed);
  target.addEventListener('custom', () => calls.push('custom'));
  target.dispatchEvent(new Event('custom'));
`, ctx);
assert.deepEqual(Array.from(ctx.calls), ["child:true", "once", "parent", "child:true", "parent", "custom"]);
console.log("events: lazy allocation, dispatch, bubbling, removal and once pass");
vm.runInContext(`
  globalThis.focusLog = [];
  const a = document.createElement('input'), b = document.createElement('input');
  a.id = 'a'; b.id = 'b';
  document.body.append(a, b);
  for (const el of [a, b]) for (const t of ['focus', 'blur', 'focusin', 'focusout'])
    el.addEventListener(t, e => focusLog.push(t + ':' + el.id + ':' + (e.relatedTarget?.id || '-')));
  document.body.addEventListener('focusin', () => focusLog.push('body:focusin'));
  document.body.addEventListener('focus', () => focusLog.push('body:focus'));
  // During blur the old one has lost the focus and the new one doesn't have
  // it yet: activeElement is the body, as in browsers.
  a.addEventListener('blur', () => focusLog.push('during-blur:' + document.activeElement.localName));
  a.focus(); b.focus();
  focusLog.push('active:' + document.activeElement.id);
  b.blur();
  focusLog.push('active:' + document.activeElement.localName);
`, ctx);
assert.deepEqual(Array.from(ctx.focusLog), [
  "focus:a:-", "focusin:a:-", "body:focusin",
  "blur:a:b", "during-blur:body", "focusout:a:b", "focus:b:a", "focusin:b:a", "body:focusin",
  "active:b", "blur:b:-", "focusout:b:-", "active:body",
]);
console.log("events: focus, blur, focusin and focusout follow the active element");
vm.runInContext(`
  const r = (attrs) => { const el = document.createElement('input'); el.setAttribute('type', 'range');
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v); return el.value; };
  globalThis.ranges = [r({}), r({ min: 0, max: 10, step: 3 }), r({ value: 70 }), r({ value: 170 }), r({ min: 10, max: 5 }), r({ value: 'x', step: 'any', max: 1 })];
`, ctx);
assert.deepEqual(Array.from(ctx.ranges), ["50", "6", "70", "100", "10", "0.5"]);
console.log("events: a range's value is halfway when missing, else clamped and on a step");
