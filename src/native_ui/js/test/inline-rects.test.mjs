// node test/inline-rects.test.mjs: an inline element (no box of its own)
// is its text's line fragments: getClientRects asks host.runRects(text
// node, first run, last run) for them, getBoundingClientRect is their
// union; a backend without runRects gives the text node's frame.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><p id="p">Start <span id="s">two <b>bold</b> words</span> end.</p><p id="q">x <i id="i">y</i></p></body></html>`;
function run(withRects) {
  const asked = [];
  const nodes = new Map();
  const host = {
    log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
    asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    frame: (id) => (nodes.get(id)?.kind === "text" ? [10, 20, 300, 34] : undefined),
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") nodes.set(id, { kind: x, props: {} }); else if (k === "p") nodes.get(id).props = x; } },
    platform: JSON.stringify({ os: "macos" }), label: "main", url: "index.html",
  };
  if (withRects) host.runRects = (id, first, last) => { asked.push([nodes.get(id).props.runs.slice(first, last + 1).map((r) => r.t).join("")]); return [[50, 20, 100, 17], [10, 37, 40, 17]]; };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, false, false);
  ctx.__oriel.render();
  const q = (js) => vm.runInContext(js, ctx);
  return { asked, q };
}
{
  const { asked, q } = run(true);
  assert.equal(q(`document.getElementById("s").getClientRects().length`), 2);
  assert.deepEqual(asked[0], ["two bold words"], "the span's own runs, its <b> in them");
  assert.deepEqual(JSON.parse(q(`JSON.stringify(document.getElementById("s").getBoundingClientRect())`)), { x: 10, y: 20, left: 10, top: 20, width: 140, height: 34, right: 150, bottom: 54 });
  assert.equal(q(`document.getElementById("s").offsetWidth`), 140);
  asked.length = 0;
  q(`document.getElementById("i").getClientRects()`);
  assert.deepEqual(asked[0], ["y"]);
  // A box keeps its own frame: one rect.
  assert.equal(q(`document.getElementById("p").getClientRects().length`), 1);
}
{
  const { q } = run(false);
  assert.deepEqual(JSON.parse(q(`JSON.stringify(document.getElementById("s").getBoundingClientRect())`)), { x: 10, y: 20, left: 10, top: 20, width: 300, height: 34, right: 310, bottom: 54 }, "without runRects: its text node's frame");
}
console.log("inline rects: ok");
