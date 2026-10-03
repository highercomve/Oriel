// node test/input-events.test.mjs: a native field's beforeinput and input
// events carry inputType and data; a prevented beforeinput says so; the
// selection API reads and moves the native field's selection (host.selection,
// host.setSelection), else remembers what the page set.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><input id="a"><textarea id="t"></textarea><input id="c" type="checkbox"><script>
globalThis.seen = [];
for (const id of ["a", "t"]) {
  const el = document.getElementById(id);
  el.addEventListener("beforeinput", (e) => { seen.push(\`before \${id} \${e.inputType} \${e.data}\`); if (e.data === "x") e.preventDefault(); });
  el.addEventListener("input", (e) => seen.push(\`input \${id} \${e.inputType} \${e.data} \${el.value}\`));
}
</script></body></html>`;
const nodes = new Map();
let native = null; // the backend's selection for the next host.selection
const set = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "c") nodes.set(id, x); else if (k === "d") nodes.delete(id); },
  platform: JSON.stringify({ os: "windows", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const [a, t] = [...nodes].filter(([, k]) => k === "input" || k === "textarea").map(([id]) => id);

assert.equal(ctx.__oriel.event(a, "beforeinput", ["insertText", "h"]), false, "let through");
ctx.__oriel.event(a, "input", ["h", "insertText", "h"]);
assert.equal(ctx.__oriel.event(a, "beforeinput", ["insertText", "x"]), true, "prevented: the field doesn't make the edit");
ctx.__oriel.event(t, "beforeinput", ["insertLineBreak", null]);
ctx.__oriel.event(t, "input", ["\n", "insertLineBreak", null]);
ctx.__oriel.event(a, "input", "hi"); // a backend that sends the value alone
assert.deepEqual([...ctx.seen], [
  "before a insertText h", "input a insertText h h", "before a insertText x",
  "before t insertLineBreak null", "input t insertLineBreak null \n", "input a  null hi",
]);

// Without host.selection: what the page set, else the end.
const sel = () => vm.runInContext(`[document.getElementById("a").selectionStart, document.getElementById("a").selectionEnd]`, ctx);
assert.deepEqual([...sel()], [2, 2], "the end");
vm.runInContext(`document.getElementById("a").setSelectionRange(1, 9)`, ctx);
assert.deepEqual([...sel()], [1, 2], "clamped to the value");
assert.equal(vm.runInContext(`document.getElementById("c").selectionStart`, ctx), null, "a checkbox has none");
// With it: the native field's, and setting it reaches the backend.
host.selection = () => native;
host.setSelection = (id, s, e) => set.push([id, s, e]);
native = [0, 1];
assert.deepEqual([...sel()], [0, 1], "the native field's");
vm.runInContext(`document.getElementById("a").select()`, ctx);
assert.deepEqual(set.at(-1), [a, 0, 2], "select() selects the whole value");
console.log("input events: ok");
