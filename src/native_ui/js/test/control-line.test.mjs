// node test/control-line.test.mjs: a control alone on its line (a button
// in a <div>) has the block's strut beside it, as in a browser: a row on
// one baseline with a zero-width text in the block's font (WKWebView: the
// button's line 19px in a 14px font, the button 1px down); text-align
// places the control.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body style="font: 14px system-ui">
<div><button>Go</button></div>
<div style="text-align: center"> <select><option>A</option></select> </div>
<div>Name <input></div>
</body></html>`;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
      else if (k === "p") nodes.get(id).props = x;
      else if (k === "k") nodes.get(id).kids = x;
    }
  },
  platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const body = [...nodes.values()].find((n) => n.kids.length === 3);
const [btn, sel, field] = body.kids.map((id) => nodes.get(id));
for (const line of [btn, sel]) {
  assert.equal(line.props.fd, "row");
  assert.equal(line.props.ai, "baseline");
  const strut = nodes.get(line.kids[0]);
  assert.equal(strut.kind, "text");
  assert.equal(strut.props.runs[0].t, "​", "a zero-width text: the strut");
  assert.equal(strut.props.w, 0);
  assert.equal(strut.props.minw, 0);
  assert.equal(line.kids.length, 2, "the spaces around the control go");
}
assert.equal(sel.props.jc, "center", "text-align: center places it");
assert.equal(nodes.get(field.kids[0]).props.runs[0].t, "Name ", "a line with text keeps its own text (no strut)");
console.log("control line: ok");
