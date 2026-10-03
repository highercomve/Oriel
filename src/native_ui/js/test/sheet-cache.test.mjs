// node test/sheet-cache.test.mjs: a sheet read back from the parsed-sheet
// cache (host.sheetCache/sheetKeep, a second window) gives the engine the
// same rules, order, index and keyframes as parsing it.
import assert from "node:assert/strict";
import { StyleEngine } from "../src/css.js";
import { UA_CSS } from "../src/render.js";

const css = `
:root { --a: 3px; } .row:hover > .n, #main .x::before { color: red !important; padding: var(--a) 2px; }
@media (max-width: 600px) { .wide { display: none; } }
@keyframes spin { from { transform: rotate(0) } to { transform: rotate(360deg) } }
button:focus { outline: 1px solid; } span { font: italic 700 12px/1.2 monospace; } * { box-sizing: border-box; }`;
const kept = new Map();
const cache = { get: (c) => kept.get(c), keep: (c, json) => kept.set(c, json) };
const fresh = new StyleEngine(), first = new StyleEngine(), second = new StyleEngine();
for (const e of [fresh, first]) { e.addSheet(UA_CSS, e === first ? cache : null); e.addSheet(css, e === first ? cache : null); }
assert.equal(kept.size, 2, "both sheets kept");
second.addSheet(UA_CSS, cache);
second.addSheet(css, cache);
const view = (e) => JSON.stringify({
  rules: e.rules.map((r) => [r.sel, r.pseudo, r.spec, r.decls, r.media, r.order]),
  keyframes: e.keyframes,
  index: Object.fromEntries(Object.entries(e.index).map(([k, v]) => [k, v instanceof Map ? [...v].map(([n, rs]) => [n, rs.map((r) => r.order)]) : v.map((r) => r.order)])),
});
assert.equal(view(first), view(fresh), "keeping doesn't change what's parsed");
assert.equal(view(second), view(fresh), "read back from the cache: the same engine");
console.log("sheet cache: ok");
