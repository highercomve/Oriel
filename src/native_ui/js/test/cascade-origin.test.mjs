// node test/cascade-origin.test.mjs: any page rule overrides the user
// agent's, whatever their specificity (the cascade's origins): the UA's
// `ul ul { margin-top: 0 }` loses to a page's `ul { margin: 4px 0 }`.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><head><style>ul { margin: 4px 0 } legend { padding: 0 }</style></head><body>
<ul><li>a<ul id="n"><li>b</li></ul></li></ul><ul id="top"><li>c</li></ul>
<fieldset><legend id="lg">L</legend></fieldset></body></html>`;
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {}, ops: () => {},
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const cs = (id, p) => vm.runInContext(`getComputedStyle(document.getElementById(${JSON.stringify(id)}))[${JSON.stringify(p)}]`, ctx);
assert.equal(cs("n", "marginTop"), "4px", "the page's ul rule beats the UA's ul ul");
assert.equal(cs("top", "marginTop"), "4px");
assert.equal(cs("top", "paddingLeft"), "40px", "a UA declaration the page doesn't set stays");
console.log("cascade origin: ok");
