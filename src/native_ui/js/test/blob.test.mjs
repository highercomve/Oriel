// node test/blob.test.mjs: Blob from strings (UTF-8, lone surrogates),
// buffers and other Blobs; slice/text/arrayBuffer/bytes; text() decoding
// as TextDecoder (replacement characters, BOM); File's properties and
// extensibility; FileList; FileReader's reads, events and states.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? "<html><body></body></html>" : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined, ops: () => {},
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const later = (code) => run(`(async () => { ${code} })()`);
const bytes = (u8) => [...u8];

// Strings are UTF-8; a lone surrogate is U+FFFD (EF BF BD).
assert.equal(run(`new Blob(["héllo €😀"]).size`), 1 + 2 + 3 + 1 + 3 + 4);
assert.equal(await later(`return new Blob(["héllo ", "€😀"]).text()`), "héllo €😀");
assert.deepEqual(bytes(await later(`return new Blob(["a\\ud800b"]).bytes()`)), [0x61, 0xef, 0xbf, 0xbd, 0x62]);
// Buffers, views (only their range) and Blobs; the type lowercased.
assert.deepEqual(bytes(await later(`
  const ab = new Uint8Array([1, 2, 3, 4, 5]).buffer;
  const b = new Blob([ab, new Uint8Array(ab, 3, 2), new DataView(ab, 1, 1), new Blob(["A"]), 7], { type: "Text/Plain" });
  if (b.type !== "text/plain") throw new Error("type " + b.type);
  return new Uint8Array(await b.arrayBuffer());
`)), [1, 2, 3, 4, 5, 4, 5, 2, 0x41, 0x37]);
assert.equal(run(`new Blob([], { type: "a/ü" }).type`), "", "a non-ASCII type");
assert.equal(run(`new Blob().size`), 0);
assert.throws(() => run(`new Blob("abc")`), /sequence/);
// A blob's parts are copied: changing the buffer later changes nothing.
assert.equal(await later(`const u = new Uint8Array([0x61]); const b = new Blob([u]); u[0] = 0x62; return b.text()`), "a");

// slice: offsets, negatives, across parts, a type; no reading until asked.
assert.equal(await later(`return new Blob(["hello", " ", "world"]).slice(3, 8).text()`), "lo wo");
assert.equal(await later(`return new Blob(["hello world"]).slice(-5).text()`), "world");
assert.equal(await later(`return new Blob(["hello"]).slice(2, -1).text()`), "ll");
assert.equal(await later(`return new Blob(["hello"]).slice(4, 2).size`), 0);
assert.equal(run(`new Blob(["hello"]).slice(0, 2, "X/Y").type`), "x/y");
assert.equal(run(`new Blob(["hello"], { type: "a/b" }).slice(0, 2).type`), "", "a slice has its own type");
assert.equal(await later(`return new Blob(["héllo"]).slice(0, 2).text()`), "h�", "a cut sequence");

// text(): as TextDecoder: one U+FFFD per ill-formed sequence; the BOM goes.
const decode = (arr) => later(`return new Blob([new Uint8Array(${JSON.stringify(arr)})]).text()`);
assert.equal(await decode([0xe2, 0x82, 0x41]), "�A");
assert.equal(await decode([0xf0, 0x9f]), "�");
assert.equal(await decode([0xc0, 0x80, 0x41]), "��A");
assert.equal(await decode([0xed, 0xa0, 0x80]), "���", "an encoded surrogate");
assert.equal(await decode([0xef, 0xbb, 0xbf, 0x41]), "A");
assert.equal(await decode([0xf0, 0x9f, 0x98, 0x80]), "😀");
const long = "ab€".repeat(10000);
assert.equal(await later(`return new Blob([${JSON.stringify(long)}]).text()`), long);

// File: name, lastModified, webkitRelativePath, a Blob; extensible (file-selector adds `path`).
assert.deepEqual(JSON.parse(run(`
  const f = new File(["abc"], "a.txt", { type: "text/plain", lastModified: 42 });
  Object.defineProperty(f, "path", { value: "./a.txt", writable: false, configurable: false, enumerable: true });
  JSON.stringify([f.name, f.size, f.type, f.lastModified, f.webkitRelativePath, f instanceof Blob, f instanceof File,
    Object.prototype.toString.call(f), f.path, Object.isExtensible(f)]);
`)), ["a.txt", 3, "text/plain", 42, "", true, true, "[object File]", "./a.txt", true]);
assert.ok(Math.abs(run(`new File([], "x").lastModified`) - Date.now()) < 5000, "lastModified: now");
assert.throws(() => run(`new File(["a"])`), { name: "TypeError" });
assert.throws(() => run(`new FileList()`), { name: "TypeError" });

// FileReader: readAsText, readAsDataURL, readAsArrayBuffer; the events in
// order; on* handlers and listeners see the reader as the target.
const read = (method, blobCode) => later(`
  const r = new FileReader();
  const log = [r.readyState];
  for (const t of ["loadstart", "progress", "load", "loadend"]) r.addEventListener(t, (e) => log.push(t + ":" + e.loaded + "/" + e.total));
  await new Promise((done) => {
    r.onload = (e) => log.push("onload " + (e.target === r) + " " + r.readyState);
    r.onloadend = () => done();
    r.${method}(${blobCode});
    log.push(r.readyState);
  });
  return [log, r.result];
`);
let [log, result] = await read("readAsText", `new Blob(["héllo"])`);
assert.deepEqual([...log], [0, 1, "loadstart:0/6", "progress:6/6", "load:6/6", "onload true 2", "loadend:6/6"]);
assert.equal(result, "héllo");
[, result] = await read("readAsDataURL", `new Blob(["hello!?"], { type: "text/plain" })`);
assert.equal(result, "data:text/plain;base64," + Buffer.from("hello!?").toString("base64"));
[, result] = await read("readAsDataURL", `new Blob([new Uint8Array([0xff, 0, 1, 2])])`);
assert.equal(result, "data:application/octet-stream;base64,/wABAg==");
[, result] = await read("readAsArrayBuffer", `new Blob([new Uint8Array([9, 8, 7])])`);
assert.equal(Object.prototype.toString.call(result), "[object ArrayBuffer]");
assert.deepEqual(bytes(new Uint8Array(result)), [9, 8, 7]);
[, result] = await read("readAsBinaryString", `new Blob([new Uint8Array([0x41, 0xff])])`);
assert.equal(result, "A\xff");
// A read in progress: a second throws InvalidStateError; abort() ends it
// (abort, loadend, no load).
assert.deepEqual(await later(`
  const r = new FileReader();
  const log = [];
  for (const t of ["load", "abort", "loadend"]) r.addEventListener(t, () => log.push(t));
  r.readAsText(new Blob(["x"]));
  try { r.readAsText(new Blob(["y"])); } catch (e) { log.push(e.name); }
  r.abort();
  for (let i = 0; i < 20; i++) await null; // its read would have answered
  return [...log, r.readyState, r.result, FileReader.DONE, r.EMPTY];
`).then((a) => [...a]), ["InvalidStateError", "abort", "loadend", 2, null, 2, 0]);
assert.equal(run(`new FileReader() instanceof EventTarget`), true);
console.log("blob: ok");
