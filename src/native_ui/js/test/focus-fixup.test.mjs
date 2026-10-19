// node test/focus-fixup.test.mjs: the focus fixup rule. A focused control
// that gets disabled (itself or its fieldset) or leaves the page loses the
// focus at the next render, with no blur, and its :focus-visible goes.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { withEngine } from "./engine-host.mjs";

const page = `<html><body>
<fieldset id="fs"><input id="a"></fieldset>
<button id="b">go</button>
<button id="c">gone</button>
<script>
globalThis.seen = [];
for (const id of ["a", "b", "c"]) document.getElementById(id).addEventListener("blur", () => seen.push("blur " + id));
</script></body></html>`;
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => [0, 0, 10, 10, 10], focus: () => {},
  scrollIntoView: () => {}, scrollTo: () => {}, ops: () => {},
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const run = (code) => vm.runInContext(code, ctx);
const active = () => run("document.activeElement?.id ?? ''");

run(`document.getElementById("b").focus()`);
assert.equal(active(), "b");
assert.equal(run(`document.getElementById("b").matches(":focus-visible")`), true, "a script's focus before any press shows the ring");
run(`document.getElementById("b").disabled = true`);
ctx.__oriel.render();
assert.equal(active(), "", "a disabled button loses the focus");
assert.equal(run(`document.getElementById("b").matches(":focus, :focus-visible")`), false);
run(`document.getElementById("b").disabled = false`);
ctx.__oriel.render();
assert.equal(active(), "", "and doesn't get it back");

run(`document.getElementById("a").focus(); document.getElementById("fs").setAttribute("disabled", "")`);
ctx.__oriel.render();
assert.equal(active(), "", "in a disabled fieldset");

run(`document.getElementById("c").focus(); document.getElementById("c").remove()`);
ctx.__oriel.render();
assert.equal(active(), "", "removed");
assert.deepEqual([...ctx.seen], [], "no blur");
console.log("focus-fixup: ok");
