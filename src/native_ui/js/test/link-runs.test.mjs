// node test/link-runs.test.mjs: a link amid the text marks its runs with its
// id (`k`); a click sent there follows the link's handlers.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><p id="p">Read <a href="#more" id="a">the <b>docs</b></a> or <button disabled>no</button> <span onclick="x()">tap</span> end</p></body></html>`;
const runs = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, , x] of JSON.parse(json)) if (k === "p" && x.runs) runs.push(...x.runs); },
  platform: JSON.stringify({ os: "android", arch: "aarch64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
vm.runInContext(`globalThis.clicked = []; document.getElementById("a").addEventListener("click", (e) => { clicked.push(e.target.id || e.target.localName); e.preventDefault(); });`, ctx);
ctx.__oriel.render();
assert.ok(runs.length, "the paragraph's runs");
const byText = Object.fromEntries(runs.map((r) => [r.t.trim(), r.k]));
assert.equal(byText["Read"], undefined, "plain text has no k");
assert.ok(byText["the"] !== undefined && byText["the"] === byText["docs"], `the link's runs share its id: ${JSON.stringify(runs)}`);
assert.equal(byText["no"], undefined, "a disabled button's text isn't clickable");
assert.ok(byText["tap"] !== undefined && byText["tap"] !== byText["the"], "an onclick span has its own id");
ctx.__oriel.event(byText["docs"], "click", 0);
assert.deepEqual([...ctx.clicked], ["a"], "the click reaches the link");
console.log("link runs: ok");
