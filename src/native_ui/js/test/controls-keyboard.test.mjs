// node test/controls-keyboard.test.mjs: browsers' default actions for
// controls, on every backend (JS only): Enter and Space activate, form
// reset, input buttons as buttons, disabled controls take no clicks (nor
// from their labels), a radio group is one Tab stop moved by the arrows,
// and indeterminate boxes.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><form id="f">
<input id="name" value="Ada">
<input type="checkbox" id="box" checked>
<input type="checkbox" id="mix">
<input type="checkbox" id="off" disabled><label id="offl" for="off">off</label>
<input type="radio" name="g" id="r1"><input type="radio" name="g" id="r2" checked><input type="radio" name="g" id="r3">
<button id="go">Go</button><input type="submit" id="sub"><input type="reset" id="rst" value="Clear">
<a id="link" href="#there">there</a>
</form></body></html>`;
const props = new Map(), kinds = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => [0, 0, 10, 10, 10], focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") kinds.set(id, x); else if (k === "p") props.set(id, x); } },
  platform: JSON.stringify({ os: "linux" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 900, false, false);
const run = (code) => vm.runInContext(code, ctx);
run(`globalThis.seen = []; const f = document.getElementById("f");
  f.addEventListener("submit", (e) => { e.preventDefault(); seen.push("submit"); });
  f.addEventListener("reset", () => seen.push("reset"));
  for (const id of ["off", "go", "link", "box"]) document.getElementById(id).addEventListener("click", () => seen.push("click " + id));`);
ctx.__oriel.render();
const seen = () => { const out = [...ctx.seen]; ctx.seen.length = 0; return out; };
const key = (id, k, type = "key") => { run(`document.getElementById(${JSON.stringify(id)}).focus()`); return ctx.__oriel.event(0, type, [k, 0, 0]); };

// Enter on a button submits its form; on a link it follows it.
key("go", "Enter");
assert.deepEqual(seen(), ["click go", "submit"]);
key("link", "Enter");
assert.deepEqual(seen(), ["click link"]);
assert.equal(run("location.hash"), "#there");
// Space toggles a checkbox on keyup.
key("box", " "); key("box", " ", "keyup");
assert.equal(run(`document.getElementById("box").checked`), false);
assert.deepEqual(seen(), ["click box"]);
// <input type=submit|reset>: buttons with their labels.
ctx.__oriel.render();
const labels = [...props.values()].filter((p) => p.runs).map((p) => p.runs.map((r) => r.t).join(""));
assert.ok(labels.includes("Submit") && labels.includes("Clear"), `input buttons labelled: ${labels}`);
assert.ok(![...kinds.values()].filter((k) => k === "input").length || [...props.values()].every((p) => p.ph === undefined || p.val !== "Submit"), "not text fields");
key("sub", "Enter");
assert.deepEqual(seen(), ["submit"]);
// Reset: back to the defaults (the box checked again, the field's value).
run(`document.getElementById("name").value = "changed"`);
key("rst", " "); key("rst", " ", "keyup");
assert.deepEqual(seen(), ["reset"]);
assert.equal(run(`document.getElementById("box").checked`), true, "the box's default");
assert.equal(run(`document.getElementById("name").value`), "Ada");
// A disabled box: dis, no click, nor from its label.
ctx.__oriel.render();
assert.ok([...props.values()].some((p) => p.ctl === "checkbox" && p.dis), "a disabled box says so");
run(`document.getElementById("offl").click ? document.getElementById("offl").click() : 0`);
assert.equal(run(`document.getElementById("off").checked`), false);
assert.ok(!seen().includes("click off"), "no click on a disabled control");
// A radio group: one Tab stop (its checked radio), the arrows move the check.
const order = run(`(() => { const out = []; document.getElementById("name").focus(); for (let i = 0; i < 8; i++) { __oriel.event(0, "key", ["Tab", 0, 0]); out.push(document.activeElement.id); } return out.join(","); })()`);
assert.ok(order.includes("r2") && !order.includes("r1") && !order.includes("r3"), `one stop per group: ${order}`);
key("r2", "ArrowDown");
assert.equal(run(`document.activeElement.id + " " + document.getElementById("r3").checked + " " + document.getElementById("r2").checked`), "r3 true false");
// Indeterminate: mixed until clicked.
run(`document.getElementById("mix").indeterminate = true`);
ctx.__oriel.render();
assert.ok([...props.values()].some((p) => p.ctl === "checkbox" && p.mix), "a mixed box");
key("mix", " "); key("mix", " ", "keyup");
assert.equal(run(`document.getElementById("mix").indeterminate + " " + document.getElementById("mix").checked`), "false true");
console.log("controls keyboard: ok");
