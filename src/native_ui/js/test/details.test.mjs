// <details>: closed content hidden, the summary's disclosure marker, a click
// or Enter on the summary toggling it, and "toggle" after the change.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><body>
  <style>.shown { display: flex; } .arrow > summary { list-style: none } .arrow > summary::after { content: " \u25be" }</style>
  <details class="arrow"><summary>Arrow</summary><p>x</p></details>
  <details id="d"><summary id="s">More</summary><p id="inner">Hidden text</p><div class="shown">Styled content</div></details>
  <details id="plain" open><summary style="list-style: none">Plain</summary><p>Shown</p></details>
</body></html>`;
const scheduled = [];
let ops = [];
const host = {
  asset: (name) => name === "index.html" ? html : undefined,
  log() {}, now: () => 0, timer: (id) => scheduled.push(id), invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (json) => { ops = ops.concat(JSON.parse(json)); },
  platform: '{"os":"linux"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const flush = () => { while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); };
// The tree as the backend holds it: each node's props and children, kept across frames.
const props = new Map(), kids = new Map();
let root = null;
const texts = () => {
  ops = []; ctx.__oriel.render();
  for (const op of ops) {
    if (op[0] === "p") props.set(op[1], op[2]);
    else if (op[0] === "k") kids.set(op[1], op[2]);
    else if (op[0] === "d") { props.delete(op[1]); kids.delete(op[1]); }
    else if (op[0] === "r") root = op[1];
  }
  const out = [];
  const walk = (id) => { const p = props.get(id); if (p?.runs) out.push(p.runs.map((r) => r.t).join("")); for (const k of kids.get(id) || []) walk(k); };
  walk(root);
  return out.join("|");
};

let shown = texts();
assert.ok(!shown.includes("Hidden text"), "closed: only the summary shows");
assert.ok(!shown.includes("Styled content"), "even content the page styled with a display");
assert.ok(shown.split("|").includes("Arrow \u25be"), "an inline ::after joins its line: " + shown);
assert.ok(shown.includes("▸ More"), "a closed summary's triangle points right: " + shown);
assert.ok(shown.includes("Shown") && !shown.includes("▾ Plain") && shown.includes("Plain"), "list-style: none drops the marker");

run(`globalThis.d = document.getElementById("d"); globalThis.log = []; d.addEventListener("toggle", (e) => log.push(e.oldState + ">" + e.newState + ":" + d.open))`);
// The engine's click on the summary's node opens it.
const summaryNode = () => { for (const [id, p] of props) if (p.runs?.some((r) => r.t === "More")) return id; return null; };
const sid = summaryNode();
assert.ok(sid !== null, "the summary has a node");
ctx.__oriel.event(sid, "click", 0);
assert.equal(run("d.open"), true);
assert.deepEqual(Array.from(run("log")), [], "toggle is asynchronous");
flush();
assert.deepEqual(Array.from(run("log")), ["closed>open:true"]);
shown = texts();
assert.ok(shown.includes("Hidden text") && shown.includes("Styled content") && shown.includes("\u25be More"), "open: content and a down triangle: " + shown);
run("d.open = true"); flush();
assert.equal(run("log.length"), 1, "no toggle without a change");
// Enter on the focused summary closes it again.
run("document.getElementById('s').focus()");
ctx.__oriel.event(0, "key", ["Enter", 0, 0]);
flush();
assert.equal(run("d.open"), false, "Enter on the summary toggles it");
assert.deepEqual(Array.from(run("log")), ["closed>open:true", "open>closed:false"]);
console.log("details: hidden content, disclosure markers and toggle pass");
