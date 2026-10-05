// node test/share-file.test.mjs: oriel.share.file reads a received file
// through share:read in chunks and builds a File with its name and type;
// oriel.share.send encodes Blobs and resolves with share:sent.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const data = Buffer.alloc((4 << 20) + 10, 0x61);
data[data.length - 1] = 0x7a;
const reads = [];
const sends = [];
let ctx;
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? "<html><body></body></html>" : undefined),
  invoke: (id, cmd, args) => {
    if (cmd === "share:send") {
      sends.push(JSON.parse(args));
      setTimeout(() => { ctx.__oriel.resolve(id, true, "null"); ctx.__oriel.emit?.("share:sent", { completed: false, target: null }) ?? vm.runInContext(`oriel.__emit("share:sent", { completed: false, target: null })`, ctx); }, 0);
      return;
    }
    if (cmd !== "share:read") return;
    const a = JSON.parse(args);
    reads.push(a);
    const out = a.handle === 7 ? data.subarray(a.offset, a.offset + a.length).toString("base64") : null;
    setTimeout(() => out === null ? ctx.__oriel.resolve(id, false, JSON.stringify("InvalidHandle")) : ctx.__oriel.resolve(id, true, JSON.stringify(out)), 0);
  },
  timer: () => {}, frame: () => undefined, ops: () => {},
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
const later = (code) => vm.runInContext(`(async () => { ${code} })()`, ctx);

const r = await later(`
  const f = await oriel.share.file({ handle: 7, name: "a.txt", mime: "text/plain", size: ${data.length} });
  const b = new Uint8Array(await f.arrayBuffer());
  return [f instanceof File, f.name, f.type, f.size, b[0], b[b.length - 1]];
`);
assert.deepEqual([...r], [true, "a.txt", "text/plain", data.length, 0x61, 0x7a]);
assert.deepEqual(reads.map((a) => a.offset), [0, 4 << 20], "two chunks");
reads.length = 0;
assert.equal(await later(`return (await oriel.share.file(7)).name`), "file", "a bare handle");
await assert.rejects(later(`return oriel.share.file(9)`));

// send: Blobs go as base64 with their names, handles as handles; the
// promise resolves with share:sent's result.
const sent = await later(`return oriel.share.send({ text: "hi", files: [new File(["héllo"], "a.txt"), 7, { handle: 8, name: "x" }] })`);
assert.deepEqual({ ...sent }, { completed: false, target: null });
assert.equal(sends[0].text, "hi");
assert.deepEqual(sends[0].files, [{ name: "a.txt", data: Buffer.from("héllo").toString("base64") }, { handle: 7 }, { handle: 8 }]);
console.log("share-file ok");
