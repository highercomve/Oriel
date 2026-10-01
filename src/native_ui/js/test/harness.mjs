// Runs runtime.js against a page's files with a fake host, prints the native
// tree: `node test/harness.mjs <web dir> [width] [height]`.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const dir = process.argv[2] || "../../../examples/showcase/web";
const [w, h] = [+(process.argv[3] || 1120), +(process.argv[4] || 780)];
const nodes = new Map();
let root = null;
const timers = [];
const host = {
  log: (lvl, msg) => console.log(["debug", "info", "WARN", "ERROR"][lvl], msg),
  asset: (p) => { try { return fs.readFileSync(path.join(dir, p), "utf8"); } catch { return undefined; } },
  invoke: (id, cmd, args) => { calls.push([id, cmd, args]); },
  timer: (id, ms) => timers.push([id, ms]),
  ops: (json) => {
    for (const op of JSON.parse(json)) {
      const [k, id, x] = op;
      if (k === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
      else if (k === "p") nodes.get(id).props = x;
      else if (k === "k") nodes.get(id).kids = x;
      else if (k === "d") nodes.delete(id);
      else if (k === "r") root = id;
    }
    opsCount += JSON.parse(json).length;
  },
  frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }),
  label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const calls = [];
process.on("unhandledRejection", (e) => console.log("page: unhandled rejection:", e?.message || e));
let opsCount = 0;
const ctx = vm.createContext({ __host: host });
const t0 = performance.now();
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
const t1 = performance.now();
ctx.__oriel.boot(w, h, true, false);
await new Promise((r) => setTimeout(r, 0));
// Answer the startup commands with plausible values.
const answers = { info: { os: "linux", arch: "x86_64", data_dir: "/tmp", tray: true, menu: true, hotkeys: true, android: false }, launches: 3 };
for (let round = 0; round < 3; round++) {
  const batch = calls.splice(0);
  for (const [id, cmd] of batch) ctx.__oriel.resolve(id, true, JSON.stringify(answers[cmd] ?? null));
  await new Promise((r) => setTimeout(r, 0));
}
for (const [id] of timers.splice(0)) ctx.__oriel.timer(id);
const t2 = performance.now();
ctx.__oriel.render();
const t3 = performance.now();
ctx.__oriel.dirty(); ctx.__oriel.render();
const t4 = performance.now();

function show(id, depth) {
  const n = nodes.get(id);
  if (!n) return;
  const p = n.props;
  const text = p.runs ? " " + JSON.stringify(p.runs.map((r) => r.t).join("")).slice(0, 60) : "";
  const icon = p.icon ? ` icon(${p.icon.shapes.length})` : "";
  const extra = ["fd", "w", "h", "fg", "pos", "click", "scroll"].filter((k) => p[k] !== undefined).map((k) => `${k}=${typeof p[k] === "object" ? JSON.stringify(p[k]) : p[k]}`).join(" ");
  if (depth <= +(process.env.DEPTH || 7)) console.log(`${"  ".repeat(depth)}${n.kind}#${id} ${extra}${icon}${text}`);
  for (const k of n.kids) show(k, depth + 1);
}
show(root, 0);
// CLICK=<node id>: tap it, then show the tree again.
if (process.env.CLICK) {
  ctx.__oriel.event(+process.env.CLICK, "click", 0);
  await new Promise((r) => setTimeout(r, 0)); // the page's microtasks (MutationObserver)
  ctx.__oriel.render();
  console.log(`after a click on #${process.env.CLICK}:`);
  show(root, 0);
}
const kinds = {};
for (const n of nodes.values()) kinds[n.kind] = (kinds[n.kind] || 0) + 1;
console.log("nodes", nodes.size, kinds, "ops", opsCount);
console.log(`load ${(t1 - t0).toFixed(0)} ms, boot+scripts ${(t2 - t1).toFixed(0)} ms, first render ${(t3 - t2).toFixed(0)} ms, full re-render ${(t4 - t3).toFixed(0)} ms`);
console.log("unanswered commands:", [...new Set(calls.map((c) => c[1]))].join(", "));
