// node test/intrinsic-width.test.mjs: width: max-content and fit-content
// as props: not stretched in a block or a flex column (centered by auto
// margins), text inside max-content doesn't wrap (mc), inside fit-content
// it may take the whole width offered (fc), from rules and inline styles.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><head><style>.mc { width: max-content; } .fc { width: fit-content; }</style></head>
<body style="margin: 0">
<div id="a" class="mc">A max</div>
<div id="b" style="width: max-content; margin: 0 auto">B centered</div>
<div style="display: flex; flex-direction: column"><div id="c" class="mc">C column</div></div>
<div style="display: flex"><div id="d" class="mc">D row</div></div>
<div id="e" class="fc">E fit</div>
<div class="mc"><p id="f" style="margin: 0">F inside</p><p id="g" style="margin: 0; width: 50px">G sized</p></div>
<div id="h" class="mc" style="width: auto">H inline auto</div>
</body></html>`;
const props = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "p") props.set(id, x); },
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(640, 480, false, false);
ctx.__oriel.render();
const of = (text) => [...props.values()].find((p) => p.runs?.some((r) => r.t.startsWith(text)) || p.t?.startsWith?.(text));
assert.equal(of("A max").as, "flex-start", "a block isn't stretched");
assert.equal(of("A max").mc, true);
assert.equal(of("A max").nowrap, true);
assert.equal(of("B centered").as, "flex-start", "inline max-content");
assert.notEqual(of("B centered").w, "100%", "auto margins center it, not fill");
assert.equal(of("C column").as, "flex-start", "in a flex column");
assert.equal(of("D row").as, undefined, "a row item already starts from its content");
assert.equal(of("E fit").fc, true);
assert.equal(of("E fit").nowrap, undefined, "fit-content wraps");
assert.equal(of("F inside").mc, true, "inherited by an auto-width child");
assert.equal(of("G sized").mc, undefined, "not past a width of its own");
assert.equal(of("H inline auto").mc, undefined, "an inline width: auto overrides the rule");
console.log("intrinsic width: ok");
