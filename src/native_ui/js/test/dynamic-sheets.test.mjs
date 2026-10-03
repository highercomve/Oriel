// node test/dynamic-sheets.test.mjs: style sheets the page changes after
// boot restyle it: <style> and <link> added and removed, a <style>'s text,
// disabled, the CSSOM (insertRule/deleteRule, as styled-components and
// emotion use in production); and what 100 <style> tags cost.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { performance } from "node:perf_hooks";

const page = `<html><head><style id="boot">#b { color: rgb(0, 0, 255); }</style></head><body>
<button id="b">x</button><p id="p">text</p>
${Array.from({ length: 300 }, (_, i) => `<div class="row r${i % 7}"><span>row ${i}</span></div>`).join("")}
</body></html>`;
const assets = { "index.html": page, "late.css": "#p { color: rgb(0, 128, 0); }" };
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => assets[p],
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {}, ops: () => {},
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const run = (code) => vm.runInContext(code, ctx);
const color = (id) => { ctx.__oriel.render(); return run(`getComputedStyle(document.getElementById("${id}")).color`); };
assert.equal(color("b"), "rgb(0, 0, 255)", "the boot's sheet");

// A <style> added, its text changed (textContent, then its text node's
// data), then removed.
run(`globalThis.st = document.createElement("style"); st.textContent = "#b { color: rgb(255, 0, 0); }"; document.head.appendChild(st);`);
assert.equal(color("b"), "rgb(255, 0, 0)", "an added <style>");
run(`st.textContent = "#b { color: rgb(0, 255, 0); }"`);
assert.equal(color("b"), "rgb(0, 255, 0)", "its textContent");
run(`st.firstChild.data = "#b { color: rgb(1, 2, 3); }"`);
assert.equal(color("b"), "rgb(1, 2, 3)", "its text node's data");
run(`st.remove()`);
assert.equal(color("b"), "rgb(0, 0, 255)", "removed: the boot's again");

// The cascade follows document order: a sheet inserted before the boot's
// loses to it.
run(`globalThis.early = document.createElement("style"); early.textContent = "#b { color: rgb(9, 9, 9); }"; document.head.prepend(early);`);
assert.equal(color("b"), "rgb(0, 0, 255)", "an earlier sheet loses");
run(`early.remove()`);

// A <link rel=stylesheet> added (its asset, then load), disabled, removed.
run(`globalThis.loaded = 0; globalThis.ln = document.createElement("link"); ln.rel = "stylesheet"; ln.href = "late.css"; ln.onload = () => loaded++; document.head.appendChild(ln);`);
assert.equal(color("p"), "rgb(0, 128, 0)", "an added <link>");
await new Promise((r) => setTimeout(r, 0));
assert.equal(ctx.loaded, 1, "its load event");
run(`ln.disabled = true`);
assert.notEqual(color("p"), "rgb(0, 128, 0)", "a disabled <link>");
run(`ln.disabled = false`);
assert.equal(color("p"), "rgb(0, 128, 0)", "enabled again");
run(`ln.remove()`);
assert.notEqual(color("p"), "rgb(0, 128, 0)", "a removed <link>");

// <style>.disabled (its sheet's).
run(`document.getElementById("boot").disabled = true`);
assert.notEqual(color("b"), "rgb(0, 0, 255)", "a disabled <style>");
run(`document.getElementById("boot").sheet.disabled = false`);
assert.equal(color("b"), "rgb(0, 0, 255)", "enabled through its sheet");

// The CSSOM: an empty <style> filled with insertRule (styled-components),
// cssRules, deleteRule; document.styleSheets.
run(`globalThis.sc = document.createElement("style"); sc.setAttribute("data-styled", ""); document.head.appendChild(sc);
  globalThis.at = sc.sheet.insertRule("#b { color: rgb(200, 100, 0); }", sc.sheet.cssRules.length);
  sc.sheet.insertRule("@media (min-width: 1px) { #p { color: rgb(5, 6, 7); } }", 1);`);
assert.equal(color("b"), "rgb(200, 100, 0)", "insertRule");
assert.equal(color("p"), "rgb(5, 6, 7)", "insertRule with @media");
assert.equal(run(`sc.sheet.cssRules.length`), 2);
assert.match(run(`sc.sheet.cssRules[0].cssText`), /^#b \{/);
assert.equal(run(`document.styleSheets.length`), 2, "the boot's and the CSSOM one");
run(`sc.sheet.deleteRule(0)`);
assert.equal(color("b"), "rgb(0, 0, 255)", "deleteRule");
assert.throws(() => run(`sc.sheet.deleteRule(5)`), /no rule 5/);
assert.throws(() => run(`sc.sheet.insertRule("a {} b {}", 0)`), /one rule/);
// A <style> that came with text: its rules, one more inserted.
run(`document.getElementById("boot").sheet.insertRule(".row span { color: rgb(7, 7, 7); }", 1)`);
assert.equal(run(`document.getElementById("boot").sheet.cssRules.length`), 2);
ctx.__oriel.render();
assert.equal(run(`getComputedStyle(document.querySelector(".row span")).color`), "rgb(7, 7, 7)", "inserted into a sheet with text");
// A new text replaces what was inserted, as in browsers.
run(`document.getElementById("boot").textContent = "#b { color: rgb(0, 0, 254); }"`);
assert.equal(color("b"), "rgb(0, 0, 254)");
assert.equal(run(`document.getElementById("boot").sheet.cssRules.length`), 1);

// Cost: 100 <style> tags appended, one task (one render), then one at a
// time (a render each).
const t0 = performance.now();
run(`for (let i = 0; i < 100; i++) { const s = document.createElement("style"); s.textContent = ".r" + (i % 7) + " span { padding-left: " + i + "px; }"; document.head.appendChild(s); }`);
ctx.__oriel.render();
const batch = performance.now() - t0;
const t1 = performance.now();
for (let i = 0; i < 100; i++) {
  run(`{ const s = document.createElement("style"); s.textContent = ".r${i % 7} span { margin-left: ${i}px; }"; document.head.appendChild(s); }`);
  ctx.__oriel.render();
}
const each = (performance.now() - t1) / 100;
const t2 = performance.now();
for (let i = 0; i < 20; i++) { run(`document.getElementById("p").textContent = "t${i}"`); ctx.__oriel.render(); }
const plain = (performance.now() - t2) / 20;
assert.equal(run(`getComputedStyle(document.querySelector(".r6 span")).marginLeft`), "97px", "the last sheet wins");

// styled-components: one <style>, a rule inserted per new component class.
run(`globalThis.one = document.createElement("style"); document.head.appendChild(one);
  for (let i = 0; i < 300; i++) one.sheet.insertRule(".c" + i + " { padding-top: " + i + "px; }", one.sheet.cssRules.length);`);
ctx.__oriel.render();
const t3 = performance.now();
for (let i = 0; i < 50; i++) {
  run(`one.sheet.insertRule(".r${i % 7} { padding-bottom: ${i}px; }", one.sheet.cssRules.length)`);
  ctx.__oriel.render();
}
const inserted = (performance.now() - t3) / 50;
assert.equal(run(`getComputedStyle(document.querySelector(".r0")).paddingBottom`), "49px", "the last inserted rule wins");
console.log(`dynamic sheets: ok (100 <style> in one render ${batch.toFixed(1)} ms; one per render ${each.toFixed(2)} ms each; insertRule into a 300-rule sheet ${inserted.toFixed(2)} ms each; a text change ${plain.toFixed(2)} ms; ${run("document.styleSheets.length")} sheets)`);
