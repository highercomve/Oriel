// :empty: an element with no children (no text either) matches; it stops
// matching when text or an element goes in, and again when they go
// (.supporting:empty { display: none }: a status line that hides itself).
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><head><style>.status:empty { display: none; } .grid { display: grid; gap: 12px; }</style></head>
<body><div class="grid"><b>A</b><p id="s" class="status"></p><b>B</b></div></body></html>`;
let ops = [];
const host = {
  asset: (n) => (n === "index.html" ? html : undefined), log() {}, now: () => 0, timer() {}, invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (j) => { ops = ops.concat(JSON.parse(j)); }, platform: '{"os":"linux"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const props = new Map(), kids = new Map();
const render = () => { ctx.__oriel.render(); for (const o of ops) { if (o[0] === "p") props.set(o[1], o[2]); else if (o[0] === "k") kids.set(o[1], o[2]); else if (o[0] === "d") { props.delete(o[1]); kids.delete(o[1]); } } ops = []; };
const texts = () => { const out = []; for (const p of props.values()) if (p.runs) out.push(p.runs.map((r) => r.t).join("")); return out; };
const gridKids = () => { for (const [id, k] of kids) if (k.length >= 2 && k.every((c) => props.get(c)?.runs?.[0]?.t === "A" || props.get(c)?.runs?.[0]?.t === "B" || props.get(c)?.runs?.[0]?.t === "Saved")) return k.length; return -1; };
render();
assert.equal(gridKids(), 2, "the empty status takes no row (no extra gap)");
vm.runInContext(`document.getElementById("s").textContent = "Saved"`, ctx);
render();
assert.ok(texts().includes("Saved"), "with text it shows");
assert.equal(gridKids(), 3);
vm.runInContext(`document.getElementById("s").textContent = ""`, ctx);
render();
assert.equal(gridKids(), 2, "emptied, it hides again");
console.log("empty: :empty hides an empty element and follows its text");
