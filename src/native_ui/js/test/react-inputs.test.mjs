// node test/react-inputs.test.mjs: typing and clicks reach a React-style
// page (one that wraps value/checked on the element) as changes.
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import assert from "node:assert/strict";

const dir = new URL("./react-inputs/", import.meta.url).pathname;
const nodes = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => { try { return fs.readFileSync(path.join(dir, p), "utf8"); } catch { return undefined; } },
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main",
  evalScript: (name, code) => vm.runInContext(code, ctx, { filename: name }),
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, true, true);
ctx.__oriel.render();
const idOf = (kind) => [...nodes].find(([, k]) => k === kind)?.[0];

const field = idOf("input");
assert.ok(field !== undefined, "the text field is a node");
ctx.__oriel.event(field, "input", "new");
assert.deepEqual([...ctx.__seen], ["name=new"], "typing is a change");

const box = [...nodes].filter(([, k]) => k === "view").map(([id]) => id).find((id) => {
  const before = ctx.__seen.length;
  ctx.__oriel.event(id, "click", 0);
  return ctx.__seen.length > before;
});
assert.ok(box !== undefined, "clicking the checkbox is a change");
assert.equal(ctx.__seen.at(-1), "box=true");
console.log("react inputs: ok");
