// node test/field-a11y.test.mjs: a form control's accessible name (Props
// al: aria-labelledby, aria-label, its <label>'s text without the control's
// own, title) and readonly (Props ro, never with disabled); the system
// accent (platform.accent, the "accent" event) colors macOS's focus ring.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<label for="a">Full <b>name</b></label> <input id="a">
<label>Plan <select id="b"><option>Free</option><option>Pro</option></select></label>
<span id="lb">Volume</span><input id="c" type="range" aria-labelledby="lb">
<input id="d" aria-label="Reference" readonly title="ignored">
<input id="e" title="Search terms" readonly disabled>
<textarea id="f" readonly></textarea>
<input id="g">
</body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") nodes.set(id, { kind: x, props: {} }); else if (k === "p") nodes.get(id).props = x; } },
  platform: JSON.stringify({ os: "macos", accent: [255, 45, 85] }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const fields = [...nodes.values()].filter((n) => ["input", "select", "textarea"].includes(n.kind));
const byLabel = fields.map((n) => n.props.al ?? null);
assert.deepEqual(byLabel, ["Full name", "Plan", "Volume", "Reference", "Search terms", null, null]);
assert.deepEqual(fields.map((n) => !!n.props.ro), [false, false, false, true, false, true, false], "readonly, not when disabled");
// The focus ring in the accent color (half alpha), and a new accent heard.
vm.runInContext(`document.getElementById("g").focus()`, ctx);
ctx.__oriel.render();
const ringed = () => [...nodes.values()].find((n) => n.props.ol)?.props.ol;
assert.deepEqual(ringed().c, [255, 45, 85, 0.5]);
ctx.__oriel.event(0, "accent", [0, 200, 100]);
ctx.__oriel.render();
assert.deepEqual(ringed().c, [0, 200, 100, 0.5]);
console.log("field a11y: ok");
