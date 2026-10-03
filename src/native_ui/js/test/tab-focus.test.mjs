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

// The ring above is WebKit's (linux). On Windows and Android it is
// Chromium's: a 2px band in a white halo, placed by the kind of element;
// #101010 on Windows, orange on Android.
for (const [os, band] of [["windows", [16, 16, 16, 1]], ["android", [229, 151, 0, 1]]]) {
  const winPage = `<html><body><button id="b">b</button><a href="#x" id="a" style="display: block">a</a><div id="d" tabindex="0">d</div><input type="checkbox" id="k"><input id="t"></body></html>`;
  let ops = "";
  const winHost = { ...host, asset: (p) => (p === "index.html" ? winPage : undefined), platform: JSON.stringify({ os, arch: "x86_64" }),
    ops: (json) => { ops = json; for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); } };
  const wctx = vm.createContext({ __host: winHost });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), wctx, { filename: "runtime.js" });
  wctx.__oriel.boot(400, 600, false, false);
  wctx.__oriel.render();
  const rings = {};
  for (let i = 0; i < 5; i++) {
    wctx.__oriel.event(0, "key", ["Tab", 0, false]);
    wctx.__oriel.render();
    const id = vm.runInContext("document.activeElement.id", wctx);
    const ol = JSON.parse(ops).map((op) => op[0] === "p" && op[2].ol).find(Boolean);
    rings[id] = ol && [ol.o, ol.r];
    if (id === "b") assert.deepEqual(ol, { w: 2, c: band, o: -2, h: [255, 255, 255, 1], r: 3 }, os);
  }
  assert.deepEqual(rings, { b: [-2, 3], a: [0, 4], d: [-1, 4], k: [1, 3], t: [-2, 3] }, os);
}

// WKWebView's on macOS: the accent blue at half alpha, 4px, by kind.
{
  const macPage = `<html><body><button id="b">b</button><a href="#x" id="a" style="display: block">a</a><div id="d" tabindex="0">d</div><input type="checkbox" id="k"><input id="t"></body></html>`;
  let ops = "";
  const macHost = { ...host, asset: (p) => (p === "index.html" ? macPage : undefined), platform: JSON.stringify({ os: "macos", arch: "aarch64", fullKeyboardAccess: true }),
    ops: (json) => { ops = json; for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); } };
  const mctx = vm.createContext({ __host: macHost });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), mctx, { filename: "runtime.js" });
  mctx.__oriel.boot(400, 600, false, false);
  mctx.__oriel.render();
  const rings = {};
  for (let i = 0; i < 5; i++) {
    mctx.__oriel.event(0, "key", ["Tab", 0, false]);
    mctx.__oriel.render();
    const id = vm.runInContext("document.activeElement.id", mctx);
    const ol = JSON.parse(ops).map((op) => op[0] === "p" && op[2].ol).find(Boolean);
    rings[id] = ol && [ol.w, ol.o, ol.r];
    if (id === "t") assert.deepEqual(ol, { w: 4, c: [0, 103, 244, 0.5], o: -1, r: 2 });
  }
  assert.deepEqual(rings, { b: [4, -1, 5], a: [4, 1, 2], d: [4, 1, 2], k: [4, -1, 5], t: [4, -1, 2] });
}
// An inline link has no box: its text run carries the ring.
vm.runInContext(`document.getElementById("a1").focus()`, ctx);
ctx.__oriel.render();
assert.match(lastOps, /"t":"link"[^}]*"ol":\{"w":2/, "the focused link's run has the ring");

// keypress after a keydown let through: for characters and Enter; WebKit's
// also for Escape, and on macOS with Command; never with Control; a
// prevented keypress uses the key.
{
  const page = `<html><body><input id="f"></body></html>`;
  const press = (os) => {
    const c = bootPage(page, { os }).ctx;
    vm.runInContext(`globalThis.seen = [];
      for (const t of ["keydown", "keypress", "keyup"]) document.addEventListener(t, (e) => seen.push(t + " " + e.key));
      document.addEventListener("keypress", (e) => { if (e.key === "x") e.preventDefault(); });`, c);
    const used = [];
    for (const [k, m] of [["a", 0], ["Enter", 0], ["Escape", 0], ["a", 8], ["a", 2], ["ArrowLeft", 0], ["x", 0]]) used.push(c.__oriel.event(0, "key", [k, m, false]));
    return { seen: vm.runInContext("seen.filter((s) => s.startsWith('keypress')).join(',')", c), used };
  };
  const mac = press("macos"), ios = press("ios"), win = press("windows");
  assert.equal(mac.seen, "keypress a,keypress Enter,keypress Escape,keypress a,keypress x", "WebKit on macOS");
  assert.equal(ios.seen, "keypress a,keypress Enter,keypress Escape,keypress x", "WebKit on iOS: not with Command");
  assert.equal(win.seen, "keypress a,keypress Enter,keypress x", "Chromium");
  assert.equal(mac.used.at(-1), true, "a prevented keypress uses the key");
  assert.equal(mac.used[0], false);
}
// devicePixelRatio from the backend's platform.dpr (1 without one), and the
// root's clientWidth/clientHeight: the viewport (boot's 400 x 600).
{
  const c = bootPage(`<html><body><p>x</p></body></html>`, { os: "macos", dpr: 2 }).ctx;
  assert.equal(vm.runInContext("JSON.stringify([devicePixelRatio, matchMedia('(min-resolution: 2dppx)').matches, document.documentElement.clientWidth, document.documentElement.clientHeight])", c), "[2,true,400,600]");
  const one = bootPage(`<html><body></body></html>`, { os: "linux" }).ctx;
  assert.equal(vm.runInContext("devicePixelRatio", one), 1);
  // A window moved to a screen with another scale: "dpr", and a resolution
  // query's listeners hear the change (once; the same scale again is nothing).
  vm.runInContext("globalThis.heard = []; matchMedia('(min-resolution: 2dppx)').addEventListener('change', (e) => heard.push(e.matches));", one);
  one.__oriel.event(0, "dpr", 2);
  one.__oriel.event(0, "dpr", 2);
  assert.equal(vm.runInContext("JSON.stringify([devicePixelRatio, heard])", one), "[2,[true]]");
}
console.log("tab focus: ok");
