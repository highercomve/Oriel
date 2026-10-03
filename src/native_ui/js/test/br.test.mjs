// node test/br.test.mjs: <br> breaks the line wherever it is (in a span,
// in bold), a space before it goes; in a line of text and inline boxes,
// what follows a <br> starts a new line (a full-width break in a row that
// wraps); a space between two boxes in such a line stays.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<p>one <span>two<br>three</span> four</p>
<p><strong>bold<br>next</strong></p>
<div>label<br><button>p</button> <button>q</button></div>
<div>end<br></div>
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
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(640, 480, false, false);
ctx.__oriel.render();
const texts = [...nodes.values()].filter((n) => n.props.runs).map((n) => n.props.runs.map((r) => r.t));
assert.ok(texts.some((t) => t.join("") === "one two\nthree four"), `a <br> in a span: ${JSON.stringify(texts)}`);
assert.ok(texts.some((t) => t.join("") === "bold\nnext"), "in bold");
assert.ok(texts.some((t) => t.join("") === "end"), "a last <br> adds no line");
const row = [...nodes.values()].find((n) => n.props.fd === "row" && n.kids.some((k) => nodes.get(k)?.props.runs?.[0]?.t === "label"));
assert.ok(row, "label and buttons: a row");
assert.equal(row.props.fw, "wrap");
const [label, brk, p, q] = row.kids.map((k) => nodes.get(k));
assert.equal(label.props.runs.map((r) => r.t).join(""), "label", "the <br> isn't in the text");
assert.deepEqual([brk.props.w, brk.props.h], ["100%", 0], "a full-width break");
assert.ok(!(p.props.m?.[3] > 0), "no space before the first button");
assert.ok(q.props.m?.[3] > 3, "the space between the buttons stays");
console.log("br: ok");
