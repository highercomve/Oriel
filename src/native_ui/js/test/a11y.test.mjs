// node test/a11y.test.mjs: the accessibility tree's ops (a11y.js, design
// section 2): none before the backend's "a11y" event; then the whole tree
// at once (inside that event) and afterwards only what changed; the name
// order (aria-labelledby, aria-label, <label>, content, title, which is
// the description once a name came first); aria-hidden prunes; an entry
// gone is null; "a11y" 0 clears everything (["a", -2]).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<h2 id="h">Settings</h2>
<label for="n">Name</label><input id="n" title="Your full name">
<button id="b" title="Saves it">Save</button>
<a id="l" href="#x">Help</a>
<span id="lb">Volume</span><input id="v" type="range" aria-labelledby="lb" aria-label="ignored">
<div id="hid" aria-hidden="true"><button id="hb">Hidden</button></div>
<img id="dec" alt="" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="4" height="4"><img id="pic" alt="A cat" src="data:image/gif;base64,R0lGODlhAQABAAAAACw=" width="4" height="4">
<div id="plain">Just text</div>
<input id="c" type="checkbox" checked><label for="c">Agree</label>
</body></html>`;
let ops = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const op of JSON.parse(json)) if (op[0] === "a") ops.push(op); },
  platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
assert.equal(ops.length, 0, "nothing before an assistive technology asks");
ctx.__oriel.event(0, "a11y", 1);
const find = (pred) => ops.map((o) => o[2]).find((ax) => ax && pred(ax));
assert.deepEqual(find((a) => a.r === "heading"), { r: "heading", n: "Settings", l: 2 });
assert.deepEqual(find((a) => a.r === "textbox"), { r: "textbox", n: "Name", d: "Your full name", s: 1024, v: "" });
assert.deepEqual(find((a) => a.r === "button" && a.n === "Save"), { r: "button", n: "Save", d: "Saves it", s: 1024 });
assert.deepEqual(find((a) => a.r === "link"), { r: "link", n: "Help", s: 1024 });
assert.equal(find((a) => a.r === "slider").n, "Volume", "aria-labelledby before aria-label");
assert.deepEqual(find((a) => a.r === "slider").rv, [0, 100, 50]);
assert.ok(find((a) => a.h === 1 && a.r === "generic"), "aria-hidden: an entry that prunes");
assert.ok(!find((a) => a.n === "Hidden"), "nothing under aria-hidden");
assert.ok(find((a) => a.r === "img" && a.h === 1), "alt='': hidden image");
assert.equal(find((a) => a.r === "img" && !a.h).n, "A cat");
assert.ok(!find((a) => a.n === "Just text"), "a plain block has no entry (its text node is read)");
assert.deepEqual(find((a) => a.r === "checkbox"), { r: "checkbox", n: "Agree", s: 2 | 1024 });
// Then only changes.
ops = [];
vm.runInContext(`document.getElementById("b").textContent = "Store"; document.getElementById("c").checked = false;`, ctx);
ctx.__oriel.render();
assert.deepEqual(ops.map((o) => o[2]?.n).sort(), ["Agree", "Store"], `changes only: ${JSON.stringify(ops)}`);
ops = [];
vm.runInContext(`document.getElementById("l").remove()`, ctx);
ctx.__oriel.render();
assert.equal(ops.length, 1);
assert.equal(ops[0][2], null, "a link gone: null");
ops = [];
ctx.__oriel.event(0, "a11y", 0);
assert.deepEqual(ops, [["a", -2]]);
console.log("a11y: ok");
