// node test/tab-focus.test.mjs: Tab and Shift+Tab move the focus in
// browsers' order (positive tabindex first, then document order), past
// what can't take focus, and not when the page takes the key.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<a id="nohref">no href</a>
<a href="#x" id="a1">link</a>
<input id="i1">
<input type="hidden" id="ih">
<button id="b1" disabled>off</button>
<button id="b2" disabled tabindex="0">off too</button>
<div id="d1" tabindex="0">div</div>
<span id="s1" tabindex="2">two</span>
<span id="s2" tabindex="1">one</span>
<input id="neg" tabindex="-1">
<div style="display: none"><input id="gone"></div>
<button id="vh" style="visibility: hidden">hidden</button>
<span id="bad" tabindex="x">not focusable</span>
<button id="bad2" tabindex="x">focusable</button>
</body></html>`;
const nodes = new Map();
let lastOps = "";
const focused = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {},
  frame: (id) => (nodes.has(id) ? [0, 0, 10, 10, 10] : undefined),
  focus: (id) => focused.push(id), scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { lastOps = json; for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();

const tab = (shift) => ctx.__oriel.event(0, "key", ["Tab", shift ? 1 : 0, false]);
const at = () => vm.runInContext("document.activeElement.id", ctx);
const order = [];
for (let i = 0; i < 7; i++) { assert.equal(tab(false), true, "Tab is used"); order.push(at()); }
assert.deepEqual(order, ["s2", "s1", "a1", "i1", "d1", "bad2", "s2"]);
assert.equal(vm.runInContext("document.activeElement.hasAttribute('data-nui-focus-visible')", ctx), true, ":focus-visible by keyboard");
assert.ok(focused.length >= 7, "the backend is asked to focus each");
// Back to bad2, a button: browsers' focus ring.
tab(true);
assert.equal(at(), "bad2");
ctx.__oriel.render();
assert.match(lastOps, /"ol":\{"w":2/, "a focus ring on :focus-visible");
// Not where the page styles the outline.
vm.runInContext(`document.getElementById("bad2").style.outline = "none"`, ctx);
ctx.__oriel.render();
assert.doesNotMatch(lastOps, /"ol"/, "the page's outline: none wins");
const back = [];
for (let i = 0; i < 3; i++) { tab(true); back.push(at()); }
assert.deepEqual(back, ["d1", "i1", "a1"]);

// A page that takes Tab keeps the focus where it is.
vm.runInContext(`document.addEventListener("keydown", (e) => { if (e.key === "Tab") e.preventDefault(); })`, ctx);
assert.equal(tab(false), true, "prevented: the backend leaves it too");
assert.equal(at(), "a1");
// macOS without Full Keyboard Access: WKWebView's order (measured), text
// fields, selects, textareas and contenteditable, plus explicit tabindex;
// with it, every control too.
function bootPage(html, platform) {
  const els = new Map();
  const h = {
    log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
    asset: (p) => (p === "index.html" ? html : undefined),
    invoke: () => {}, timer: () => {},
    frame: (id) => (els.has(id) ? [0, 0, 10, 10, 10] : undefined),
    focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") els.set(id, x); else if (k === "d") els.delete(id); },
    platform: JSON.stringify(platform), label: "main", url: "index.html",
  };
  const c = vm.createContext({ __host: h });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), c, { filename: "runtime.js" });
  c.__oriel.boot(400, 600, false, false);
  c.__oriel.render();
  const tabs = (n) => {
    const seen = [];
    for (let i = 0; i < n; i++) { c.__oriel.event(0, "key", ["Tab", 0, false]); seen.push(vm.runInContext("document.activeElement.id", c)); }
    return seen;
  };
  tabs.ctx = c;
  return tabs;
}
const macPage = `<html><body>
<input id="t1"><input id="cb" type="checkbox"><button id="b1">Btn</button><a id="l1" href="#x">Link</a>
<div id="d0" tabindex="0">div0</div><span id="s2" tabindex="2">span2</span><div id="ce" contenteditable>edit</div>
<select id="sel"><option>one</option></select><textarea id="ta"></textarea><input id="rg" type="range"><button id="bt0" tabindex="0">btn0</button>
</body></html>`;
assert.deepEqual(bootPage(macPage, { os: "macos", fullKeyboardAccess: false })(8), ["s2", "t1", "d0", "ce", "sel", "ta", "bt0", "s2"], "WKWebView's macOS order");
assert.deepEqual(bootPage(macPage, { os: "macos", fullKeyboardAccess: true })(5), ["s2", "t1", "cb", "b1", "l1"], "with Full Keyboard Access: every control");
assert.deepEqual(bootPage(macPage, { os: "ios" })(7), ["s2", "t1", "d0", "ce", "sel", "ta", "s2"], "iOS: WKWebView's order (no tabindex button)");

// isContentEditable as browsers have it: inherited, and "false" stops it.
{
  const ce = `<html><body><div id="a" contenteditable><p id="b">x</p><span id="c" contenteditable="false"><i id="d">y</i></span></div><div id="e" contenteditable="plaintext-only"></div><div id="f" contenteditable="bogus"></div><div id="g"></div></body></html>`;
  const c = bootPage(ce, { os: "linux" }).ctx;
  const editable = vm.runInContext(`["a","b","c","d","e","f","g"].map((id) => document.getElementById(id).isContentEditable)`, c);
  assert.deepEqual([...editable], [true, true, false, false, true, false, false], "isContentEditable");
}

console.log("tab focus: ok");
