// node --expose-gc test/drop-files.test.mjs: a dropped file's bytes come
// from the host (host.fileRead(reqId, handle, offset, length), answered by
// __oriel.fileData), always asynchronously; a slice reads only its range;
// a failed or short read rejects with NotReadableError, as does a host
// without fileRead; the handle goes back (host.fileRelease) once no File
// or slice holds it.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><div id="zone" style="width:100px;height:100px">zone</div><script>
globalThis.dropped = [];
const zone = document.getElementById("zone");
zone.addEventListener("dragover", (e) => e.preventDefault());
zone.addEventListener("drop", (e) => { e.preventDefault(); dropped.push(...e.dataTransfer.files); });
</script></body></html>`;
const contents = new Map([[1, Buffer.from("hello, dropped world")], [2, Buffer.from("héllo")], [3, Buffer.from("gone")], [4, Buffer.from("short")]]);
const reads = [];
const released = [];
let zoneId;
let sync = false; // answer inside fileRead (the page must still see it later)
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) if (k === "p" && x.runs && x.runs.map((r) => r.t).join("").trim() === "zone") zoneId = id;
  },
  fileRead: (reqId, handle, offset, length) => {
    reads.push([handle, offset, length]);
    const answer = () => {
      const data = contents.get(handle);
      if (!data || handle === 3) ctx.__oriel.fileData(reqId, null, "NotReadableError");
      else if (handle === 4) ctx.__oriel.fileData(reqId, new Uint8Array(data).buffer.slice(0, 2), ""); // the file shrank
      else ctx.__oriel.fileData(reqId, new Uint8Array(data.subarray(offset, offset + length)).buffer, "");
    };
    if (sync) answer(); else setTimeout(answer, 0);
  },
  fileRelease: (handle) => released.push(handle),
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
assert.ok(zoneId !== undefined, "found the zone");
const run = (code) => vm.runInContext(code, ctx);
const later = (code) => run(`(async () => { ${code} })()`);

let session = 0;
function dropFiles(files) {
  session++;
  const items = files.map(([name, type, size, handle]) => ["file", type, name, size, 1700000000000, handle]);
  assert.equal(ctx.__oriel.event(zoneId, "drag", ["enter", 5, 5, 1, 1, 0, session, items.map((i) => [i[0], i[1]])]), 1);
  assert.equal(ctx.__oriel.event(zoneId, "drag", ["drop", 5, 5, 1, 1, 0, session, items]), 1);
}

dropFiles([["a.txt", "text/plain", contents.get(1).length, 1], ["b.txt", "text/plain", contents.get(2).length, 2]]);
assert.equal(run(`dropped.map((f) => f.name + ":" + f.size).join()`), "a.txt:20,b.txt:6");
assert.deepEqual(reads, [], "nothing read at the drop");

// A whole file, then a slice (only its range: offsets into the file), a
// slice of a slice, and a Blob made of a slice and a string.
assert.equal(await later(`return dropped[0].text()`), "hello, dropped world");
assert.deepEqual(reads.splice(0), [[1, 0, 20]]);
assert.equal(await later(`return dropped[0].slice(7, 14).text()`), "dropped");
assert.deepEqual(reads.splice(0), [[1, 7, 7]]);
assert.equal(await later(`return dropped[0].slice(7).slice(-5, -1).text()`), "worl");
assert.deepEqual(reads.splice(0), [[1, 15, 4]]);
assert.equal(await later(`return new Blob([dropped[0].slice(0, 5), "!", dropped[1]]).text()`), "hello!héllo");
assert.deepEqual(reads.splice(0), [[1, 0, 5], [2, 0, 6]]);
assert.equal(await later(`return dropped[0].slice(3, 3).text()`), "", "an empty slice reads nothing");
assert.deepEqual(reads.splice(0), []);

// An answer inside fileRead still reaches the page later, not during the call.
sync = true;
assert.equal(await later(`
  let done = false;
  const p = dropped[1].text().then((t) => { done = true; return t; });
  if (done) throw new Error("synchronous");
  return p;
`), "héllo");
sync = false;
reads.length = 0;

// FileReader over a dropped file.
assert.equal(await later(`
  const r = new FileReader();
  await new Promise((done) => { r.onload = done; r.readAsDataURL(dropped[0].slice(0, 5, "text/plain")); });
  return r.result;
`), "data:text/plain;base64," + Buffer.from("hello").toString("base64"));
reads.length = 0;

// Failures: the host's error, a short answer (the file changed), and a
// host without fileRead all reject with NotReadableError; FileReader's
// error event carries it.
dropFiles([["gone.txt", "text/plain", 4, 3], ["short.txt", "text/plain", 5, 4]]);
const failure = (code) => later(`try { await ${code}; return "read"; } catch (e) { return e.name + " " + (e instanceof Error); }`);
assert.equal(await failure(`dropped[2].text()`), "NotReadableError true");
assert.equal(await failure(`dropped[3].arrayBuffer()`), "NotReadableError true");
assert.equal(await later(`
  const r = new FileReader();
  await new Promise((done) => { r.onloadend = done; r.readAsText(dropped[2]); });
  return r.error.name + " " + r.result;
`), "NotReadableError null");
const fileRead = host.fileRead;
delete host.fileRead;
assert.equal(await failure(`dropped[0].text()`), "NotReadableError true");
host.fileRead = fileRead;
assert.equal(await later(`return dropped[0].slice(0, 5).text()`), "hello", "reads again once it's back");
// A late answer (no read waiting for it) is ignored.
ctx.__oriel.fileData(9999, new ArrayBuffer(1), "");

// Release: a handle goes back once nothing holds its File or a slice; a
// slice keeps it.
if (typeof globalThis.gc === "function") {
  const settle = async () => { for (let i = 0; i < 6; i++) { globalThis.gc(); await new Promise((r) => setTimeout(r, 0)); } };
  run(`globalThis.kept = dropped[0].slice(1, 2); dropped.length = 0;`);
  await settle();
  assert.deepEqual(released.sort(), [2, 3, 4], "the files nothing holds");
  assert.equal(await later(`return kept.text()`), "e", "the slice still reads");
  run(`globalThis.kept = null;`);
  await settle();
  assert.deepEqual(released.sort(), [1, 2, 3, 4], "the slice's file once it goes");
  // A file dropped and never kept.
  dropFiles([["c.txt", "text/plain", 0, 5]]);
  run(`dropped.length = 0;`);
  await settle();
  assert.ok(released.includes(5), "an empty file's handle too");
} else console.log("drop files: no gc (run with --expose-gc), release not checked");
console.log("drop files: ok");
