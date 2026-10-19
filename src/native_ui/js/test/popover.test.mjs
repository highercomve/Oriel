// The Popover API: hidden until showPopover(), then in the top layer over a
// modal dialog shown before it; :popover-open in CSS and matches();
// beforetoggle (cancelable when opening) and toggle; an auto popover closes
// with Escape, a press outside, or another auto one; popovertarget buttons.
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { withEngine } from "./engine-host.mjs";

const html = `<html><head><style>
  #bar { position: fixed; inset: 60px 0 auto 0; margin: 0; }
  #bar:popover-open { background-color: rgb(1, 2, 3); }
</style></head><body>
  <button id="toggle" popovertarget="menu">Menu</button>
  <div id="menu" popover><p>Menu item</p></div>
  <div id="other" popover>Other</div>
  <div id="bar" popover="manual">Progress</div>
  <dialog id="d"><p>Dialog</p></dialog>
</body></html>`;
const scheduled = [];
let ops = [];
const host = {
  asset: (name) => name === "index.html" ? html : undefined,
  log() {}, now: () => 0, timer: (id) => scheduled.push(id), invoke() {}, frame() {}, focus() {}, scrollIntoView() {}, scrollTo() {},
  ops: (json) => { ops = ops.concat(JSON.parse(json)); },
  platform: '{"os":"linux"}', label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: withEngine(host) });
vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx);
ctx.__oriel.boot(400, 600, false, false);
const run = (code) => vm.runInContext(code, ctx);
const flush = () => { while (scheduled.length) ctx.__oriel.timer(scheduled.shift()); };
const props = new Map(), kids = new Map();
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
assert.ok(!text(0).includes("Menu item") && !text(0).includes("Progress"), "closed popovers aren't shown");
run(`globalThis.log = [];
  const bar = document.getElementById("bar"), menu = document.getElementById("menu");
  for (const el of [bar, menu, document.getElementById("other")]) {
    el.addEventListener("beforetoggle", (e) => { log.push(el.id + ":before:" + e.newState); if (globalThis.refuse && e.newState === "open") e.preventDefault(); });
    el.addEventListener("toggle", (e) => log.push(el.id + ":" + e.newState));
  }`);
assert.equal(run(`bar.popover`), "manual");
assert.equal(run(`menu.popover`), "auto");

// Shown after a modal dialog, the manual popover is above it (Penny Goblin's progress bar).
run(`document.getElementById("d").showModal(); bar.showPopover()`);
assert.equal(run(`bar.matches(":popover-open")`), true);
assert.equal(run(`document.querySelector(":popover-open").id`), "bar");
render();
const root = kids.get(0);
const top = root[root.length - 1];
assert.ok(text(top).includes("Progress"), "the popover is the topmost");
assert.ok(text(root[root.length - 2]).includes("Dialog"), "the dialog's below it");
assert.deepEqual(props.get(top).bg?.color, [1, 2, 3, 1], ":popover-open styles apply");
assert.equal(props.get(top).ins?.[0], 60, "it keeps its own position (inset: 60px 0 auto 0)");
flush();
assert.deepEqual(Array.from(run("log")), ["bar:before:open", "bar:open"]);

// A cancelled beforetoggle keeps it closed.
run(`log.length = 0; globalThis.refuse = true; menu.showPopover(); globalThis.refuse = false`);
assert.equal(run(`menu.matches(":popover-open")`), false);

// An auto popover: Escape closes it (not the dialog under it).
run(`log.length = 0; menu.showPopover()`);
ctx.__oriel.event(0, "key", ["Escape", 0, 0]);
assert.equal(run(`menu.matches(":popover-open")`), false);
assert.equal(run(`document.getElementById("d").open`), true, "Escape went to the popover");
flush();
assert.deepEqual(Array.from(run("log")), ["menu:before:open", "menu:before:closed", "menu:open", "menu:closed"]);

// Another auto popover closes the first; a press outside closes it; manual ones stay.
run(`log.length = 0; menu.showPopover(); document.getElementById("other").showPopover()`);
assert.equal(run(`menu.matches(":popover-open")`), false);
ctx.__oriel.event(null, "pointer", ["down", 5, 5, 1, 1, "mouse", 0]);
assert.equal(run(`document.getElementById("other").matches(":popover-open")`), false, "light dismiss");
assert.equal(run(`bar.matches(":popover-open")`), true, "a manual popover stays");

// togglePopover and hidePopover; a popovertarget button toggles its popover.
assert.equal(run(`bar.togglePopover()`), false);
run(`document.getElementById("d").close()`);
run(`document.getElementById("toggle").click()`);
assert.equal(run(`menu.matches(":popover-open")`), true);
run(`document.getElementById("toggle").click()`);
assert.equal(run(`menu.matches(":popover-open")`), false);
assert.throws(() => run(`document.body.showPopover()`), /popover/i);
console.log("popover: top layer order, :popover-open, toggle events, light dismiss, Escape and popovertarget pass");
