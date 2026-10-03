// node test/lone-image.test.mjs: an image alone on its line gets the line's
// descent below it (the gap a browser leaves under an inline image), also
// when the spaces a template keeps and an absolutely positioned sibling are
// beside it (Svelte's `<img class="base"/> <img class="abs"/>`), but not
// beside real inline content.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const img = `src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="`;
const page = `<html><body>
<div id="a"><img alt="a" ${img} width="170" height="179"></div>
<div id="b"><img alt="b" ${img} width="170" height="179"/> <img alt="b2" ${img} style="position:absolute;top:0"/> </div>
<div id="c"><img alt="c" ${img} width="170" height="179"/> text beside it</div>
</body></html>`;
const props = new Map();
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, frame: () => undefined,
  focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
  ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "p") props.set(id, x); },
  platform: JSON.stringify({ os: "android", arch: "x86_64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();

// The 170 px images by their order in the page: a, b, then c.
const imgs = [...props.values()].filter((p) => p.w === 170);
assert.equal(imgs.length, 3, "three 170 px images");
const gap = (p) => (Array.isArray(p.m) ? p.m[2] : 0);
assert.ok(gap(imgs[0]) > 0, "alone in its block: the descent below it");
assert.equal(gap(imgs[1]), gap(imgs[0]), "beside spaces and an absolute image: still alone on its line");
assert.ok(!(gap(imgs[2]) > 0), "beside text: part of a text line, no gap of its own");
console.log("lone image: ok");
