// node test/frame-start.test.mjs: what a page changed since the last render
// is rendered when the next frame starts, before its callbacks, as a
// browser renders at the end of every frame: changes made outside the
// frames (a timer) and a frame's own alike, so the next frame's first
// layout read is cheap (render-bench clears the stage, awaits a frame, then
// times a build).
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<!doctype html><html><body><div id="list"></div><script>
window.go = () => setTimeout(() => {
  const list = document.getElementById("list");
  for (let i = 0; i < 50; i++) { const d = document.createElement("div"); d.textContent = "row " + i; list.append(d); }
  window.atBuild = __opsCalls;
  requestAnimationFrame(() => {
    const before = __opsCalls;
    void list.offsetHeight;
    window.r1 = { renderedAtStart: before > window.atBuild, readRendered: __opsCalls !== before };
    list.firstChild.textContent = "changed in a frame";
    window.atFrame = __opsCalls;
    requestAnimationFrame(() => { window.r2 = { renderedAtStart: __opsCalls !== window.atFrame }; });
  });
}, 0);
</script></body></html>`;

const timers = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: (id) => timers.push(id), frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: () => { ctx.__opsCalls++; },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host, __opsCalls: 0 });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
const tick = () => new Promise((r) => setTimeout(r, 0));
// The engine's own (paced) frames never come here: only the page's timers
// and animation frames run, each as its own task.
async function run(steps, render) {
  for (let i = 0; i < steps; i++) {
    await tick();
    for (const id of timers.splice(0)) { ctx.__oriel.timer(id); await tick(); }
    if (render) ctx.__oriel.render();
  }
}
await run(3, true);
vm.runInContext("go()", ctx);
await run(6, false);
assert.ok(ctx.r1, "the first frame ran");
assert.equal(ctx.r1.renderedAtStart, true, "rows built in a timer are rendered when the next frame starts");
assert.equal(ctx.r1.readRendered, false, "so the frame's first layout read has nothing left to render");
assert.ok(ctx.r2, "the second frame ran");
assert.equal(ctx.r2.renderedAtStart, true, "a frame's own change is rendered when the next frame starts");
console.log("frame start: ok");
