// Dumps the canvas nodes' cv programs: static drawing and a game loop.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const dir = new URL("./canvas", import.meta.url).pathname;
const nodes = new Map();
const timers = new Map();
let cvOps = null;
const host = {
  log: (lvl, msg) => console.log(["debug", "info", "WARN", "ERROR"][lvl], msg),
  asset: (p) => fs.readFileSync(path.join(dir, p), "utf8"),
  invoke: () => {}, timer: (id, ms) => timers.set(id, ms), ops: (json) => {
    for (const op of JSON.parse(json)) {
      const [k, id, x] = op;
      if (k === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
      else if (k === "p") { nodes.get(id).props = x; if (x.cv) cvOps = x.cv; }
      else if (k === "k") nodes.get(id).kids = x;
      else if (k === "d") nodes.delete(id);
      else if (k === "r") nodes.set("root", id);
    }
  },
  frame: () => [0, 0, 120, 60], focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  platform: JSON.stringify({ os: "linux" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(480, 300, true, false);
await new Promise((r) => setTimeout(r, 0));
ctx.__oriel.render();

const n1 = nodes.get(3).props, n2 = nodes.get(4).props;
const count = (p) => (p.cv?.length ?? 0);
console.log(`canvas#3: cw=${n1.cw} ch=${n1.ch} ops=${count(n1)}`);
console.log(`  ops: ${JSON.stringify(n1.cv)}`);
console.log(`canvas#4: cw=${n2.cw} ch=${n2.ch} ops=${count(n2)}`);

// Let the game loop run a few frames, then look again.
for (let i = 0; i < 4; i++) {
  cvOps = null;
  for (const id of [...timers.keys()]) { timers.delete(id); ctx.__oriel.timer(id); }
  await new Promise((r) => setTimeout(r, 0));
  ctx.__oriel.render();
}
const p4 = nodes.get(4).props;
console.log(`canvas#4 after 4 frames: ops=${count(p4)} (a loop resets to one frame)`);
console.log(`  ops: ${JSON.stringify(p4.cv)}`);
