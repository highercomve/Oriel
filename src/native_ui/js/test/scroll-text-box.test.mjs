// node test/scroll-text-box.test.mjs: an element holding only text that
// scrolls or clips keeps its box (a text view can't scroll or clip): the
// text goes in a child, as a <p> inside it would.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<div id="s" style="height:70px; overflow:auto; padding:4px 6px">long text that scrolls</div>
<div id="h" style="height:20px; overflow:hidden">clipped text</div>
<div id="v">plain text</div>
</body></html>`;
const kinds = new Map(), props = new Map(), kids = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") kinds.set(id, x);
      else if (k === "p") props.set(id, { ...(props.get(id) || {}), ...x });
      else if (k === "k") kids.set(id, x);
    }
  },
  platform: JSON.stringify({ os: "windows", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const textOf = (id) => (props.get(id)?.runs || []).map((r) => r.t).join("").trim();
const find = (t) => [...props.keys()].find((id) => textOf(id) === t);
const parentOf = (id) => [...kids].find(([, k]) => k.includes(id))?.[0];

const s = find("long text that scrolls");
assert.equal(kinds.get(s), "text");
const sBox = parentOf(s);
assert.equal(kinds.get(sBox), "view", "the scroller is a box");
assert.ok(props.get(sBox).scroll, "it scrolls");
const h = find("clipped text");
assert.ok(props.get(parentOf(h)).clip, "the clipping box keeps its box");
const v = find("plain text");
assert.ok(!props.get(v).scroll && !props.get(v).clip, "plain text is still one text view");
console.log("scroll text box: ok");
