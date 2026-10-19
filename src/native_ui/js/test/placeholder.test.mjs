// node test/placeholder.test.mjs: a field's ::placeholder color (phc): the
// page's (::placeholder, ::-webkit-input-placeholder), else the browser's
// (Chrome's #757575 on Android, WebKit's darkgray on Linux); none without
// a placeholder.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";
import { withEngine } from "./engine-host.mjs";

function phc(os) {
  const page = `<html><head><style>
#b::placeholder { color: rgb(255, 0, 0); }
.c::-webkit-input-placeholder { color: rgb(0, 0, 255); }
</style></head><body>
<input id="a" placeholder="a"><input id="b" placeholder="b"><textarea class="c" placeholder="c"></textarea><input id="d">
</body></html>`;
  const props = new Map();
  const host = {
    log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
    asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => [0, 0, 10, 10, 10], focus: () => {},
    scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "p") props.set(id, { ...props.get(id), ...x }); },
    platform: JSON.stringify({ os, arch: "x86_64" }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: withEngine(host) });
  host.evalScript = (name, code) => vm.runInContext(code, ctx, { filename: name });
  vm.runInContext(fs.readFileSync(new URL("./runtime-linkedom.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 600, false, false);
  ctx.__oriel.render();
  const out = {};
  for (const p of props.values()) if ("ph" in p) out[p.ph || "none"] = p.phc;
  return out;
}

const android = phc("android");
assert.deepEqual(android.a, [117, 117, 117, 1], "Chrome's placeholder gray");
assert.deepEqual(android.b, [255, 0, 0, 1], "the page's ::placeholder");
assert.deepEqual(android.c, [0, 0, 255, 1], "::-webkit-input-placeholder");
assert.equal(android.none, undefined, "no placeholder, no color");
assert.deepEqual(phc("linux").a, [169, 169, 169, 1], "WebKit's darkgray");
console.log("placeholder: ok");
