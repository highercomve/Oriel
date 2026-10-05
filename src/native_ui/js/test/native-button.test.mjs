// node test/native-button.test.mjs: rule 1.4 (docs/native-controls-a11y-design.md):
// a backend listing "button" gets kind button for buttons whose box the page
// left to the UA (color, padding and size don't count); a styled box, a
// :hover rule touching it, rich content or appearance: none stay drawn.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const css = `.pad { padding: 10px 20px; color: red; font-size: 18px }
.bg { background: #08f } .bd { border: 2px solid red } .flat { appearance: none }
.hov:hover { background: #eee } .colorhover:hover { color: blue }`;
const page = `<html><head><style>${css}</style></head><body>
<button>Plain</button><button class="pad">Padded</button><input type="submit" value="Send">
<button class="bg">Bg</button><button class="bd">Bd</button><button class="flat">Flat</button><button style="background: red">Inline</button>
<button class="hov">Hov</button><button class="colorhover">Colorhover</button>
<button><img src="x.png"> Icon</button><button><b>Bold</b> text</button><button disabled>Off</button>
</body></html>`;
function render(controls) {
  const kinds = new Map(), props = new Map();
  const host = {
    log: () => {}, asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [op, id, x] of JSON.parse(json)) { if (op === "c") kinds.set(id, x); else if (op === "p") props.set(id, x); } },
    platform: JSON.stringify({ os: "linux", controls }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(800, 600, false, false);
  ctx.__oriel.render();
  const out = new Map();
  for (const [id, p] of props) if (kinds.get(id) === "button") out.set(p.runs.map((r) => r.t).join(""), p);
  return out;
}
const native = render(["button"]);
assert.deepEqual([...native.keys()].sort(), ["Bold text", "Colorhover", "Off", "Padded", "Plain", "Send"].sort());
const padded = native.get("Padded");
assert.equal(padded.fz, 18, "the page's font size kept");
assert.deepEqual(padded.pad, [10, 20, 10, 20], "padding is room");
assert.equal(padded.bg, undefined, "the native button draws its own bezel");
assert.ok(native.get("Off").dis, "disabled");
assert.equal(render([]).size, 0, "without the capability every button is drawn");
console.log("native button: ok");
