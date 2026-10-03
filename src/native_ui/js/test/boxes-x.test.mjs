// node test/boxes-x.test.mjs: with host.paintOps (a backend that takes
// transform/opacity alone), the box path sends ["x", id, tx, ty, sc, rot,
// op] ops, and the props it keeps are what a full render makes.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<!doctype html><html><head><style>
#stage { position: relative; height: 300px; }
.box { position: absolute; width: 14px; height: 14px; background: #6d8bff; left: 0; top: 0; }
</style></head><body><div id="stage"><div class="box"></div><div class="box"></div></div></body></html>`;

// The native tree's props as the ops leave them.
const mirror = new Map();
let batches = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  paintOps: true,
  ops: (json) => {
    const ops = JSON.parse(json);
    batches.push(ops);
    for (const o of ops) {
      if (o[0] === "p") mirror.set(o[1], { ...o[2] });
      if (o[0] === "x") {
        const p = mirror.get(o[1]);
        ["tx", "ty", "sc", "rot", "op"].forEach((k, i) => { if (o[2 + i] === null) delete p[k]; else p[k] = o[2 + i]; });
      }
    }
  },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const run = (code) => { batches = []; vm.runInContext(code, ctx); ctx.__oriel.render(); return batches.flat(); };

run(`const b = document.querySelectorAll(".box"); b[0].style.transform = "translate(1px, 2px)"; b[1].style.opacity = "0.9";`);
let ops = run(`b[0].style.transform = "translate(10px, 20px) scale(2)"; b[1].style.opacity = "0.5"; b[1].style.transform = "rotate(90deg)";`);
assert.deepEqual(ops.map((o) => o[0]), ["x", "x"], JSON.stringify(ops));
assert.deepEqual(ops[0].slice(2), [10, 20, 2, null, null]);
assert.deepEqual(ops[1].slice(2), [null, null, null, 90, 0.5]);
ops = run(`b[0].style.transform = "none"; b[1].style.opacity = "";`);
assert.deepEqual(ops[0].slice(2), [null, null, null, null, null]);
assert.deepEqual(ops[1].slice(2), [null, null, null, 90, null]);

// A full render sends props only where the mirror differs from what it makes.
const before = new Map([...mirror].map(([id, p]) => [id, JSON.stringify(Object.entries(p).sort())]));
run("__oriel.dirty()");
for (const [id, p] of mirror) assert.equal(JSON.stringify(Object.entries(p).sort()), before.get(id), `node ${id} after a full render`);
console.log("boxes (x ops): ok");
