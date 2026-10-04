// node test/list-markers.test.mjs: list items get their outside markers, as
// browsers draw them: bullets by nesting level, numbers counted with start,
// value and reversed; list-style: none has none.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<ul><li>one</li><li>two<ul><li>inner<ul><li>deep</li></ul></li></ul></li></ul>
<ol start="3"><li>c</li><li value="10">j</li><li>k</li></ol>
<ol reversed><li>x</li><li>y</li></ol>
<ol style="list-style-type: upper-roman"><li>r1</li><li>r2</li><li>r3</li><li>r4</li></ol>
<ul style="list-style: none"><li>plain</li></ul>
<ul style="list-style: square inside"><li>inside</li></ul>
</body></html>`;
const props = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "p") props.set(id, x); },
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 900, false, false);
ctx.__oriel.render();
const markers = [...props.values()].filter((p) => p.pos === "absolute" && p.runs).map((p) => p.runs[0].t);
assert.deepEqual([...markers].sort(), ["• ", "• ", "◦ ", "▪ ", "3. ", "10. ", "11. ", "2. ", "1. ", "I. ", "II. ", "III. ", "IV. "].sort(), "one per item; none for list-style none or inside");
const m = [...props.values()].find((p) => p.pos === "absolute" && p.runs);
assert.deepEqual(m.ins, [0, "100%", null, null], "beside the item's first line, ending at its start edge");
console.log("list markers: ok");
