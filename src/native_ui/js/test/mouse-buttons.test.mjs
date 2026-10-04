// node test/mouse-buttons.test.mjs: backends send only `buttons`; the page
// sees the changed button (right 2, middle 1), auxclick after a non-primary
// release, and a mouse's contextmenu with button 2.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><div id="box" style="width:100px;height:100px">box</div></body></html>`;
const nodes = new Map();
let boxId;
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") nodes.set(id, x);
      else if (k === "d") nodes.delete(id);
      else if (k === "p" && x.runs && x.runs.map((r) => r.t).join("").trim() === "box") boxId = id;
    }
  },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
vm.runInContext(`
  globalThis.seen = [];
  const box = document.getElementById("box");
  for (const t of ["pointerdown", "mousedown", "pointerup", "mouseup", "auxclick", "contextmenu"])
    box.addEventListener(t, (e) => seen.push(t + ":" + e.button + "/" + e.buttons));
`, ctx);
ctx.__oriel.render();
assert.ok(boxId !== undefined, "found the box");
const ev = (phase, buttons) => ctx.__oriel.event(boxId, "pointer", [phase, 10, 10, buttons, 1, "mouse", 0]);

ev("down", 2); ctx.__oriel.event(boxId, "contextmenu", [10, 10]); ev("up", 0);
assert.deepEqual([...ctx.seen], ["pointerdown:2/2", "mousedown:2/2", "contextmenu:2/2", "pointerup:2/0", "mouseup:2/0", "auxclick:2/0"]);
ctx.seen.length = 0;
ev("down", 4); ev("up", 0);
assert.deepEqual([...ctx.seen], ["pointerdown:1/4", "mousedown:1/4", "pointerup:1/0", "mouseup:1/0", "auxclick:1/0"]);
ctx.seen.length = 0;
ev("down", 1); ev("up", 0);
assert.deepEqual([...ctx.seen], ["pointerdown:0/1", "mousedown:0/1", "pointerup:0/0", "mouseup:0/0"]);
// A touch's long press: contextmenu without a button.
ctx.seen.length = 0;
ctx.__oriel.event(boxId, "pointer", ["down", 10, 10, 1, 2, "touch", 0]);
ctx.__oriel.event(boxId, "contextmenu", [10, 10]);
assert.ok(ctx.seen.includes("contextmenu:0/0"), `touch contextmenu: ${ctx.seen}`);
console.log("mouse buttons: ok");
