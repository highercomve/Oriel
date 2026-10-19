// <dialog>: hidden until open; showModal() puts it in the top layer (over
// the fixed elements, with its ::backdrop), focuses inside it and keeps Tab
// there; Escape and the platform's back cancel it; close() restores the
// focus and fires "close"; a method=dialog form closes it with a value.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><head><style>
  #d::backdrop { background-color: rgb(0 0 0 / 32%); }
  .bar { position: fixed; top: 0; }
</style></head><body>
  <button id="opener">Open</button><div class="bar">Bar</div>
  <dialog id="d"><form method="dialog"><input id="name"><button id="ok" value="saved">OK</button><button id="no" type="button">No</button></form></dialog>
  <dialog id="plain"><p>Plain</p></dialog>
</body></html>`;
const scheduled = [];
let ops = [];
const host = {
  asset: (name) => name === "index.html" ? html : undefined,
  log() {}, now: () => 0, timer: (id) => scheduled.push(id), invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (json) => { ops = ops.concat(JSON.parse(json)); },
  platform: '{"os":"android"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const flush = () => { while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); };
const props = new Map(), kids = new Map();
// Every op the backend got, also from renders the runtime ran itself (a focus).
const render = () => {
  ctx.__oriel.render();
  const batch = ops; ops = [];
  for (const op of batch) {
    if (op[0] === "p") props.set(op[1], op[2]);
    else if (op[0] === "k") kids.set(op[1], op[2]);
    else if (op[0] === "d") { props.delete(op[1]); kids.delete(op[1]); }
  }
};
const text = (id) => { const out = []; const walk = (n) => { const p = props.get(n); if (p?.runs) out.push(p.runs.map((r) => r.t).join("")); for (const k of kids.get(n) || []) walk(k); }; walk(id); return out.join("|"); };

render();
assert.ok(!text(0).includes("OK") && !text(0).includes("Plain"), "closed dialogs aren't shown");

// The page's own showModal wrapper (Penny Goblin's nav.js does this) still runs ours.
run(`globalThis.log = [];
  const ours = HTMLDialogElement.prototype.showModal;
  HTMLDialogElement.prototype.showModal = function () { ours.call(this); log.push("wrapped"); };
  const d = document.getElementById("d");
  d.addEventListener("close", () => log.push("close:" + d.returnValue));
  d.addEventListener("cancel", (e) => { log.push("cancel"); if (globalThis.keepOpen) e.preventDefault(); });
  document.getElementById("opener").focus();
  d.showModal();`);
assert.equal(run("d.open"), true);
assert.equal(run("document.activeElement.id"), "name", "the first focusable inside gets the focus");
assert.deepEqual(Array.from(run("log")), ["wrapped"]);
assert.equal(run("document.querySelector('[data-nui-modal]').id"), "d");

render();
const rootKids = kids.get(0);
const layer = rootKids[rootKids.length - 1];
const backdrop = rootKids[rootKids.length - 2];
assert.ok(text(rootKids[rootKids.length - 3]).includes("Bar"), "the fixed bar stays below the top layer");
const [dialogNode] = kids.get(layer);
assert.deepEqual(props.get(layer).ins, [0, 0, 0, 0], "the centering box covers the window");
assert.equal(props.get(layer).jc, "center");
assert.deepEqual(props.get(backdrop).ins, [0, 0, 0, 0], "the backdrop covers the window");
assert.ok(props.get(backdrop).bg, "the ::backdrop is drawn: " + JSON.stringify(props.get(backdrop)));
assert.ok(text(dialogNode).includes("OK"), "the dialog is in the top layer");
assert.equal(props.get(dialogNode).pos, undefined, "the dialog is in the layer's flow, centered");

// Tab stays inside the modal dialog.
const tabs = [];
for (let i = 0; i < 4; i++) { ctx.__oriel.event(0, "key", ["Tab", 0, 0]); tabs.push(run("document.activeElement.id")); }
assert.ok(tabs.every((id) => ["name", "ok", "no"].includes(id)), "Tab cycles inside the dialog: " + tabs);

// showModal again does nothing; show() on a modal one throws.
run("d.showModal()");
assert.throws(() => run("d.show()"), /modal/);

// Escape: "cancel", then the close (async "close").
run("document.getElementById('name').focus()");
ctx.__oriel.event(0, "key", ["Escape", 0, 0]);
assert.equal(run("d.open"), false);
assert.equal(run("document.activeElement.id"), "opener", "the focus goes back where it was");
flush();
assert.deepEqual(Array.from(run("log")), ["wrapped", "wrapped", "cancel", "close:"]);
render();
assert.equal(kids.get(0).length, rootKids.length - 2, "the backdrop and box are gone");
assert.ok(!props.has(layer) && !props.has(backdrop), "its nodes are destroyed");

// The platform's back cancels the dialog before walking the history; a
// prevented cancel keeps it open.
run("log.length = 0; d.showModal(); globalThis.keepOpen = true");
assert.equal(ctx.__oriel.event(0, "back", null), true);
assert.equal(run("d.open"), true, "a prevented cancel keeps it open");
run("globalThis.keepOpen = false");
assert.equal(ctx.__oriel.event(0, "back", null), true);
assert.equal(run("d.open"), false);
flush();

// A method=dialog form: its submitter's value is the returnValue.
run("log.length = 0; d.showModal()");
run("document.getElementById('d').querySelector('form').requestSubmit(document.getElementById('ok'))");
assert.equal(run("d.open"), false);
flush();
assert.deepEqual(Array.from(run("log")), ["wrapped", "close:saved"]);

// show(): open in place, not modal, no top layer.
run("document.getElementById('plain').show()");
render();
assert.equal(run("document.getElementById('plain').open"), true);
assert.ok(text(0).includes("Plain"));
assert.equal(kids.get(0).length, rootKids.length - 2, "a non-modal dialog isn't in the top layer");
console.log("dialog: closed hidden, modal top layer with backdrop, focus, Tab trap, Escape, back, method=dialog and show() pass");
