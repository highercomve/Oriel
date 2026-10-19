// <input type=file>: a click (its own, or its label's) asks the host for a
// pick (nui:pick_file, then nui:picked_file with its token) and the picked
// file becomes input.files, then "input" and "change"; a cancelled pick
// fires "cancel"; accept narrows the dialog's extensions; with capture on a
// phone, the camera takes the photo; the label shows the chosen file.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><body>
  <label id="lab"><span>Choose image</span><input id="pick" type="file" accept="image/png,image/jpeg"></label>
  <input id="pdf" type="file" accept=".pdf,application/pdf">
  <input id="cam" type="file" accept="image/*" capture="environment">
</body></html>`;
const calls = [];
let answer = {};
const scheduled = [];
let ops = [];
const host = {
  asset: (name) => name === "index.html" ? html : undefined,
  log: (lvl, msg) => { if (lvl >= 3) console.log(msg); }, now: () => 0, timer: (id) => scheduled.push(id), frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (json) => { ops = ops.concat(JSON.parse(json)); },
  invoke: (id, cmd, json) => {
    if (!cmd.startsWith("oriel:window:")) calls.push([cmd, JSON.parse(json)]);
    const a = answer[cmd];
    queueMicrotask(() => a instanceof Error ? ctx.__oriel.resolve(id, false, a.message) : ctx.__oriel.resolve(id, true, JSON.stringify(a ?? null)));
  },
  fileRead() {}, fileRelease() {},
  platform: '{"os":"android"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const settle = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setImmediate(r)); while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); } };
run(`globalThis.log = [];
  for (const id of ["pick", "pdf", "cam"]) for (const t of ["input", "change", "cancel"])
    document.getElementById(id).addEventListener(t, (e) => log.push(id + ":" + t + ":" + e.target.files.length));
  globalThis.trustedChange = null; document.getElementById("pick").addEventListener("change", (e) => { trustedChange = e.isTrusted; });
  globalThis.clickTrusted = null; document.getElementById("lab").addEventListener("click", (e) => { clickTrusted = e.isTrusted; });`);

// A click on the label picks; accept's types become extensions.
answer = { "nui:pick_file": { token: 7 }, "nui:picked_file": ["image/png", "receipt.png", 2048, 1700000000000, 3] };
run(`document.getElementById("lab").click()`);
await settle();
assert.deepEqual(calls.map((c) => c[0]), ["nui:pick_file", "nui:picked_file"]);
assert.deepEqual(calls[0][1].extensions, ["png", "jpg", "jpeg"]);
assert.deepEqual(calls[1][1], { token: 7 });
assert.deepEqual(Array.from(run("log")), ["pick:input:1", "pick:change:1"]);
assert.equal(run("trustedChange"), true, "the pick's change is the browser's own: trusted");
assert.equal(run("clickTrusted"), false, "a page's el.click() isn't");
const f = run(`document.getElementById("pick").files[0]`);
assert.equal(f.name, "receipt.png");
assert.equal(f.type, "image/png");
assert.equal(f.size, 2048);
assert.equal(run(`document.getElementById("pick").value`), "C:\\fakepath\\receipt.png");
assert.equal(run(`document.getElementById("pdf").files.length`), 0);

// The label shows the chosen file.
ops = []; ctx.__oriel.render();
const texts = ops.filter((o) => o[0] === "p" && o[2].runs).map((o) => o[2].runs.map((r) => r.t).join(""));
assert.ok(texts.some((t) => t.includes("receipt.png")), "the file's name shows: " + texts);

// value = "" clears it.
run(`document.getElementById("pick").value = ""`);
assert.equal(run(`document.getElementById("pick").files.length`), 0);

// Cancelled: "cancel", files unchanged; mixed accept keeps the extensions.
calls.length = 0; run("log.length = 0");
answer = { "nui:pick_file": null };
run(`document.getElementById("pdf").click()`);
await settle();
assert.deepEqual(calls.map((c) => c[0]), ["nui:pick_file"]);
assert.deepEqual(calls[0][1].extensions, ["pdf"]);
assert.deepEqual(Array.from(run("log")), ["pdf:cancel:0"]);

// capture on a phone: the camera, its photo a File.
calls.length = 0; run("log.length = 0");
answer = { "camera:capture": { dataUrl: "data:image/jpeg;base64,/9j/AAEC", width: 1, height: 1, mime: "image/jpeg" } };
run(`document.getElementById("cam").click()`);
await settle();
assert.deepEqual(calls.map((c) => c[0]), ["camera:capture"]);
assert.equal(calls[0][1].source, "camera");
assert.deepEqual(Array.from(run("log")), ["cam:input:1", "cam:change:1"]);
const photo = run(`document.getElementById("cam").files[0]`);
assert.equal(photo.type, "image/jpeg");
assert.equal(photo.size, 6, "the photo's bytes");
await new Promise((resolve) => { run(`const r = new FileReader(); r.onload = () => { globalThis.bytes = Array.from(new Uint8Array(r.result)); }; r.readAsArrayBuffer(document.getElementById("cam").files[0]);`); settle().then(resolve); });
assert.deepEqual(Array.from(run("bytes")), [0xff, 0xd8, 0xff, 0x00, 0x01, 0x02], "decoded from the data: URL");

// A cancelled camera: "cancel".
calls.length = 0; run("log.length = 0");
answer = { "camera:capture": new Error("Cancelled") };
run(`document.getElementById("cam").click()`);
await settle();
assert.deepEqual(Array.from(run("log")), ["cam:cancel:1"], "a cancel keeps the last photo");

// Enter on a focused file input opens the picker too.
calls.length = 0;
answer = { "nui:pick_file": null };
run(`document.getElementById("pdf").focus()`);
ctx.__oriel.event(0, "key", ["Enter", 0, 0]);
await settle();
assert.deepEqual(calls.map((c) => c[0]), ["nui:pick_file"]);
console.log("file input: label and Enter picks, accept filter, files and value, cancel, camera capture and the label text pass");
