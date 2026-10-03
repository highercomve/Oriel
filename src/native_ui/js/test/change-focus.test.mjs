// node test/change-focus.test.mjs: a text field's change as browsers fire
// it (on blur and on Enter in a one-line field, after the user edited it
// and its value differs; none for a script's value), and a press focusing
// what it's on (a field's padding included): a mouse on its press, a touch
// at its tap, nothing when the page prevents the press, the focus leaving
// on a press on nothing focusable.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<form id="f"><input id="a" placeholder="a"></form>
<textarea id="t" placeholder="t"></textarea>
<div id="box"><input id="b" placeholder="b"></div>
<button id="btn">go</button>
<div id="plain">text</div>
<div id="stop"><input id="s" placeholder="s"></div>
<label id="lab">name <input id="l" placeholder="l"></label>
<script>
globalThis.seen = [];
for (const id of ["a", "t", "b", "btn", "s", "l"]) {
  const el = document.getElementById(id);
  for (const type of ["change", "blur", "focus", "beforeinput"]) el.addEventListener(type, (e) => seen.push(\`\${type} \${id}\${e.inputType ? " " + e.inputType : ""}\`));
}
document.getElementById("f").addEventListener("submit", (e) => { e.preventDefault(); seen.push("submit f"); });
document.getElementById("stop").addEventListener("pointerdown", (e) => e.preventDefault());
</script></body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {},
  frame: (id) => (nodes.has(id) ? [0, 0, 10, 10, 10] : undefined),
  // The backend's field gets the keyboard and says so (as Android's).
  focus: (id) => { focusAsked.push(id); },
  scrollIntoView: () => {}, scrollTo: () => {},
  // Which node is which: a field by its placeholder, the rest by their text.
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, x);
      else if (k === "d") nodes.delete(id);
      else if (k === "p" && x.ph) named.set(x.ph, id);
      else if (k === "p" && x.runs) named.set(x.runs.map((r) => r.t).join("").trim(), id);
    }
  },
  platform: JSON.stringify({ os: "android", arch: "x86_64" }), label: "main", url: "index.html",
};
const focusAsked = [];
const named = new Map();
const NAMES = { btn: "go", plain: "text", lab: "name" };
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();

const run = (code) => vm.runInContext(code, ctx);
const idOf = (el) => { const id = named.get(NAMES[el] ?? el); assert.ok(id, `node for ${el}`); return id; };
const seen = () => { const out = [...ctx.seen]; ctx.seen.length = 0; return out; };
const active = () => run("document.activeElement?.id ?? ''");
const ev = (el, type, data) => ctx.__oriel.event(el ? idOf(el) : 0, type, data);
const press = (el, type = "mouse") => ev(el, "pointer", ["down", 1, 1, 1, 1, type, 0]);
const release = (el, type = "mouse") => ev(el, "pointer", ["up", 1, 1, 0, 1, type, 0]);

// --- change ---
ev("a", "focus", null);
assert.equal(active(), "a");
ev("a", "input", ["hi", "insertText", "i"]);
ev("a", "key", ["Enter", 0, false]);
assert.deepEqual(seen(), ["focus a", "beforeinput a insertLineBreak", "change a", "submit f"], "Enter: beforeinput, change, then the form");
ev("a", "key", ["Enter", 0, false]);
assert.deepEqual(seen(), ["beforeinput a insertLineBreak", "submit f"], "no change when nothing changed since");
ev("a", "input", ["hi!", "insertText", "!"]);
ev("t", "focus", null);
assert.deepEqual(seen(), ["change a", "blur a", "focus t"], "blur after an edit: change, then blur");
// A textarea's Enter is a line, not a change; its change comes on blur.
ev("t", "input", ["\n", "insertLineBreak", null]);
ev("t", "key", ["Enter", 0, false]);
assert.deepEqual(seen(), [], "Enter in a textarea: no change");
// Edited back to what it was at focus: no change.
ev("t", "input", ["", "deleteContentBackward", null]);
ev("a", "focus", null);
assert.deepEqual(seen(), ["blur t", "focus a"], "the same value as at focus: no change");
// A script's value is no edit.
run(`document.getElementById("a").value = "set by the page"`);
ev("t", "focus", null);
assert.deepEqual(seen(), ["blur a", "focus t"], "a script's value: no change");

// --- focus on press ---
// A mouse press on the field's padding (its node, not the native control).
press("b"); release("b");
assert.equal(active(), "b", "a press on a field focuses it");
assert.ok(focusAsked.includes(idOf("b")), "the backend is asked to focus it");
assert.deepEqual(seen(), ["blur t", "focus b"]);
// On a button: focused (Chromium focuses buttons on a click).
press("btn"); release("btn");
assert.equal(active(), "btn");
seen();
// On nothing focusable: the focus leaves.
press("plain"); release("plain");
assert.equal(active(), "", "a press on plain text blurs");
assert.deepEqual(seen(), ["blur btn"]);
// A prevented press focuses nothing.
press("s");
assert.equal(active(), "", "a prevented pointerdown: no focus");
// A label leaves it to its click (which focuses its control).
press("lab");
assert.equal(active(), "", "a press on a label: not yet");
ev("lab", "click", 0);
assert.equal(active(), "l", "the label's click focuses its control");
seen();
// A touch: not on its press (it may become a scroll), at its tap.
press("b", "touch");
assert.equal(active(), "l", "a touch press doesn't move the focus");
release("b", "touch");
ev("b", "click", 0);
assert.equal(active(), "b", "the tap focuses the field");
// A touch that became a scroll (cancelled), then a click: no focus from it.
press("btn", "touch");
ev("btn", "pointer", ["cancel", 1, 1, 0, 1, "touch", 0]);
ev("btn", "click", 0);
assert.equal(active(), "b", "a cancelled touch doesn't focus");
console.log("change and press focus: ok");
