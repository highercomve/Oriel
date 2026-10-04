// node test/drag-events.test.mjs: the engine's "drag" events (enter, over,
// leave, drop) become dragenter/dragleave/dragover/drop as the HTML spec
// orders them; the effect the page chose comes back as a mask (copy 1,
// move 2, link 4); the DataTransfer is protected until the drop; window
// and document listeners, ondrop= and inline handlers hear them; text
// dropped on a textarea is inserted as a native edit.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<div id="a" style="width:100px;height:50px">boxa</div>
<div id="b" style="width:100px;height:50px">boxb</div>
<div id="z" style="width:100px;height:50px" ondragover="event.preventDefault()">boxz</div>
<textarea id="t">ab</textarea>
<script>
globalThis.seen = [];
globalThis.opts = {};
const name = (n) => n === document.body ? "body" : n?.id || "?";
for (const id of ["a", "b"]) {
  const el = document.getElementById(id);
  for (const type of ["dragenter", "dragleave", "dragover", "drop"]) {
    el.addEventListener(type, (e) => {
      seen.push(type + " " + id + (e.relatedTarget ? "<" + name(e.relatedTarget) : ""));
      const o = opts[type];
      if (!o) return;
      if (o.look) o.look(e);
      if (o.effect) e.dataTransfer.dropEffect = o.effect;
      if (o.prevent) e.preventDefault();
    });
  }
}
window.addEventListener("dragover", (e) => seen.push("window dragover " + name(e.target)));
document.addEventListener("drop", (e) => seen.push("document drop " + name(e.target)));
const z = document.getElementById("z");
z.ondrop = (e) => { seen.push("ondrop z " + e.dataTransfer.getData("text")); e.preventDefault(); };
const t = document.getElementById("t");
t.addEventListener("beforeinput", (e) => seen.push("beforeinput t " + e.inputType));
t.addEventListener("input", (e) => seen.push("input t " + e.inputType + " " + e.data + " " + t.value));
</script></body></html>`;

const nodes = new Map();
const ids = {};
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => {
    for (const [k, id, x] of JSON.parse(json)) {
      if (k === "c") { nodes.set(id, x); if (x === "textarea") ids.t = id; }
      else if (k === "d") nodes.delete(id);
      else if (k === "p" && x.runs) {
        const text = x.runs.map((r) => r.t).join("").trim();
        if (/^box[abz]$/.test(text)) ids[text[3]] = id;
      }
    }
  },
  platform: JSON.stringify({ os: "linux", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
for (const k of ["a", "b", "z", "t"]) assert.ok(ids[k] !== undefined, `found ${k}`);

let session = 0;
const COPY = 1, MOVE = 2, LINK = 4;
const textItems = [["string", "text/plain"]];
const fileItems = [["file", "image/png"], ["string", "text/plain"]];
const enter = (id, items = textItems, allowed = COPY | MOVE, suggested = COPY) => ctx.__oriel.event(id, "drag", ["enter", 10, 10, allowed, suggested, 0, session, items]);
const over = (id, allowed = COPY | MOVE, suggested = COPY) => ctx.__oriel.event(id, "drag", ["over", 12, 12, allowed, suggested, 0, session]);
const leave = (s = session) => ctx.__oriel.event(0, "drag", ["leave", s]);
const drop = (id, items, allowed = COPY | MOVE, suggested = COPY) => ctx.__oriel.event(id, "drag", ["drop", 12, 12, allowed, suggested, 0, session, items]);
const take = () => { const out = [...ctx.seen]; ctx.seen.length = 0; return out; };
const setOpts = (code) => vm.runInContext(`opts = ${code}`, ctx);

// The order across two boxes: dragenter on the new box, then dragleave on
// the old one, then dragover; the window hears dragover with its target.
session++;
assert.equal(enter(ids.a), 0, "nothing took it");
assert.deepEqual(take(), ["dragenter a", "dragover a", "window dragover a"]);
assert.equal(over(ids.a), 0);
assert.deepEqual(take(), ["dragover a", "window dragover a"], "the same target: dragover only");
assert.equal(over(ids.b), 0);
assert.deepEqual(take(), ["dragenter b<a", "dragleave a<b", "dragover b", "window dragover b"]);
assert.equal(leave(), 0);
assert.deepEqual(take(), ["dragleave b"]);
assert.equal(leave(), 0, "a second leave: nothing to leave");
assert.deepEqual(take(), []);

// Return codes: a number; copy when the page prevents with dropEffect
// "copy"; none when the dropEffect is outside effectAllowed; the initial
// dropEffect follows `suggested` within what the source allows.
session++;
setOpts(`{ dragover: { prevent: true, effect: "copy" } }`);
const r = enter(ids.a);
assert.equal(typeof r, "number");
assert.equal(r, COPY, "copy");
assert.equal(over(ids.a, MOVE, MOVE), 0, "copy isn't allowed");
setOpts(`{ dragover: { prevent: true, look: (e) => seen.push("effect " + e.dataTransfer.dropEffect + " " + e.dataTransfer.effectAllowed) } }`);
take();
assert.equal(over(ids.a, COPY | MOVE, MOVE), MOVE, "suggested move");
assert.equal(over(ids.a, COPY | LINK | MOVE, 0), COPY, "copy first");
assert.equal(over(ids.a, LINK | MOVE, 0), LINK, "then link");
assert.deepEqual(take().filter((s) => s.startsWith("effect")), ["effect move copyMove", "effect copy all", "effect link linkMove"]);
leave();

// Protected while the drag passes over: types (with "Files"), kinds and
// types, but no data and no files.
session++;
setOpts(`{ dragover: { prevent: true, look: (e) => {
  const dt = e.dataTransfer;
  globalThis.kept = dt;
  seen.push(JSON.stringify([dt.getData("text/plain"), dt.files.length, [...dt.types], dt.items.length,
    dt.items[0].kind, dt.items[0].type, dt.items[0].getAsFile(), Object.isFrozen(dt.types), dt.types === dt.types]));
} } }`);
take();
assert.equal(enter(ids.a, fileItems), COPY);
assert.deepEqual(JSON.parse(take().find((s) => s.startsWith("["))), ["", 0, ["text/plain", "Files"], 2, "file", "image/png", null, true, true]);
// Once its event is over, a kept DataTransfer has nothing.
assert.equal(vm.runInContext(`JSON.stringify([kept.items.length, kept.types.length, kept.getData("text")])`, ctx), "[0,0,\"\"]");

// The drop: the data and the files, readable; the page's dropEffect comes back.
setOpts(`{ dragover: { prevent: true }, drop: { prevent: true, look: (e) => {
  const dt = e.dataTransfer, f = dt.files[0];
  seen.push(JSON.stringify([dt.getData("text"), dt.getData("TEXT/PLAIN"), dt.getData("url"), dt.files.length, f.name, f.type, f.size, f.lastModified,
    f instanceof File, f instanceof Blob, dt.items[0].getAsFile() === f, dt.dropEffect, e.clientX, [...dt.types]]));
  dt.items[1].getAsString((s) => seen.push("string " + s));
} } }`);
take();
const r2 = drop(ids.a, [["file", "image/png", "cat.png", 1234, 1700000000000, 7], ["string", "text/plain", "hello"], ["string", "text/uri-list", "# c\nhttps://x.test/\nhttps://y.test/"]]);
assert.equal(r2, COPY);
await new Promise((res) => setTimeout(res, 0));
const got = take();
assert.deepEqual(JSON.parse(got[1]), ["hello", "hello", "https://x.test/", 1, "cat.png", "image/png", 1234, 1700000000000, true, true, true, "copy", 12,
  ["text/plain", "text/uri-list", "Files"]]);
assert.ok(got.includes("document drop a"), `document listener: ${got}`);
assert.ok(got.includes("string hello"), "getAsString");
assert.equal(over(ids.a), 0 + COPY, "a drop ends the session: an over starts a new one");
leave();

// A drop the page doesn't take after an over whose effect was none: no
// drop event, a dragleave, and 0.
session++;
setOpts(`{}`);
assert.equal(enter(ids.b), 0);
take();
assert.equal(drop(ids.b, [["string", "text/plain", "x"]]), 0);
assert.deepEqual(take(), ["dragleave b"]);
// A late leave (the last drag's) changes nothing in the next one.
session++;
setOpts(`{ dragover: { prevent: true } }`);
assert.equal(enter(ids.b), COPY);
take();
assert.equal(leave(session - 1), 0);
assert.deepEqual(take(), []);
// A drop after its leave (async data): enter and over again at its point.
leave();
take();
setOpts(`{ dragover: { prevent: true }, drop: { prevent: true } }`);
assert.equal(drop(ids.b, [["string", "text/plain", "x"]]), COPY);
assert.deepEqual(take(), ["dragenter b", "dragover b", "window dragover b", "drop b", "document drop b"]);

// ondrop= and an inline ondragover="event.preventDefault()".
session++;
assert.equal(enter(ids.z), COPY, "the inline handler took it");
assert.equal(drop(ids.z, [["string", "text/plain", "zed"]]), COPY);
assert.ok(take().includes("ondrop z zed"));
assert.equal(vm.runInContext(`typeof document.body.ondrop + " " + ("ondragover" in document)`, ctx), "object true");

// Text over a textarea: copy by default; the drop inserts it as an edit.
session++;
assert.equal(enter(ids.t), COPY, "a field takes text");
assert.equal(enter(ids.t, [["file", "image/png"]]), 0, "not a file");
assert.equal(enter(ids.t), COPY);
take();
assert.equal(drop(ids.t, [["string", "text/plain", "XY"]]), COPY);
assert.deepEqual(take(), ["document drop t", "beforeinput t insertFromDrop", "input t insertFromDrop XY abXY"]);
assert.equal(vm.runInContext(`document.getElementById("t").value + " " + (document.activeElement === document.getElementById("t"))`, ctx), "abXY true");

// A page's own DataTransfer is writable (some code builds a FileList with
// one); a string type can't be added twice.
assert.equal(vm.runInContext(`
  const own = new DataTransfer();
  own.items.add(new File(["x"], "one.txt"));
  own.items.add("hi", "text/plain");
  own.setData("text/html", "<b>");
  own.effectAllowed = "copyLink";
  own.dropEffect = "bogus";
  let twice = "";
  try { own.items.add("again", "text/plain"); } catch (e) { twice = e.name; }
  const list = own.files;
  const before = own.types;
  own.clearData("text/html");
  [list.length, list[0].name, list.item(0).name, list.item(5), [...list].length, list instanceof FileList, before.join("+"), own.types.join("+"),
    own.getData("text"), own.items.length, twice, own.effectAllowed, own.dropEffect, before === own.types].join();
`, ctx), "1,one.txt,one.txt,,1,true,text/plain+text/html+Files,text/plain+Files,hi,2,NotSupportedError,copyLink,none,false");

// The other event types still answer with a bool.
assert.equal(ctx.__oriel.event(ids.a, "pointer", ["move", 1, 1, 0, 1, "mouse", 0]), false);
assert.equal(ctx.__oriel.event(ids.a, "drag", null), 0, "a malformed drag");
assert.equal(vm.runInContext(`[typeof DragEvent, typeof DataTransfer, new DragEvent("drop") instanceof MouseEvent, new DragEvent("drop").dataTransfer].join(" ")`, ctx), "function function true ");
console.log("drag events: ok");
