// node test/boxes.test.mjs: an animation loop writing transform or opacity
// on childless boxes takes the renderer's box path (updateBoxes): only those
// nodes are sent, and a full render afterwards finds nothing left to change.
// Anything else (a box with children, another property) renders as before.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<!doctype html><html><head><style>
#stage { position: relative; height: 300px; }
.box { position: absolute; width: 14px; height: 14px; background: #6d8bff; left: 0; top: 0; font-size: 10px; }
</style></head><body><div id="stage"><div class="box"></div><div class="box"></div><div class="box"><span>x</span></div></div></body></html>`;

let batches = [], boxFrames = 0;
const host = {
  log: (lvl, msg) => { if (msg.startsWith("PROF boxes")) boxFrames++; else if (lvl >= 3) console.log(msg); },
  prof: true, now: () => performance.now(),
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { batches.push(JSON.parse(json)); },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const run = (code) => { batches = []; vm.runInContext(code, ctx); ctx.__oriel.render(); return batches.flat(); };
const props = (ops) => ops.filter((o) => o[0] === "p");
// A full render after `ops` sends the same props for those nodes (in any
// key order), or none.
const same = (ops, full) => {
  for (const [, id, p] of props(full)) {
    const sent = props(ops).find((o) => o[1] === id);
    if (sent) assert.deepEqual(p, sent[2], "the general renderer makes what the box path sent");
  }
};

// Two childless boxes move and fade. The first change gives them their own
// styles (the general path); later frames take the box path: two props
// ops, nothing else.
let ops = run(`const b = document.querySelectorAll(".box");
  b[0].style.transform = "translate(1px, 2px)"; b[1].style.opacity = "0.9";`);
same(ops, run("__oriel.dirty()"));
boxFrames = 0;
ops = run(`b[0].style.transform = "translate(10px, 20px) scale(2)";
  b[1].style.opacity = "0.5"; b[1].style.transform = "translateX(1em) rotate(90deg)";`);
assert.equal(boxFrames, 1, "the box path");
assert.equal(ops.length, 2, JSON.stringify(ops));
assert.deepEqual(props(ops).map((o) => [o[2].tx, o[2].ty, o[2].sc, o[2].rot, o[2].op]),
  [[10, 20, 2, undefined, undefined], [10, undefined, undefined, 90, 0.5]]);
// What the general renderer makes is the same.
same(ops, run("__oriel.dirty()"));

// Back to no transform: the props go.
boxFrames = 0;
ops = run(`document.querySelectorAll(".box")[0].style.transform = "none";`);
assert.equal(boxFrames, 1, "the box path");
assert.equal(ops.length, 1);
assert.equal(ops[0][2].tx, undefined);
assert.equal(ops[0][2].sc, undefined);
same(ops, run("__oriel.dirty()"));

// Something other than transform/opacity (its width) takes the general path,
// and so does a box with children: both still render right.
boxFrames = 0;
ops = run(`const c = document.querySelectorAll(".box"); c[0].style.width = "30px"; c[2].style.transform = "translateY(5px)";`);
assert.ok(props(ops).some((o) => o[2].w === 30), JSON.stringify(ops));
assert.ok(props(ops).some((o) => o[2].ty === 5), JSON.stringify(ops));
assert.equal(boxFrames, 0, "the general path");
same(ops, run("__oriel.dirty()"));
// A box path change survives later frames that rebuild around it (the
// stage changed): its style was kept up to date.
run(`b[1].style.transform = "translate(3px, 4px)";`);
ops = run(`b[1].style.transform = "translate(7px, 8px)";`);
ops = run(`document.getElementById("stage").style.height = "301px";`);
const full = props(run("__oriel.dirty()"));
assert.ok(!full.some((o) => o[2].tx === 3), "no stale transform: " + JSON.stringify(full));
console.log("boxes: ok");
