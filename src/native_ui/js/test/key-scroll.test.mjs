// node test/key-scroll.test.mjs: a key scroll glides as WKWebView's
// (measured): PageDown's 87.5% of the view over 200 ms on `ease`, a
// host.scrollTo a frame; a second key while it glides goes on from where
// it was going; an arrow's 40px over 256 ms; a wheel (an offset the glide
// didn't set), a touch or the page's scrollTo stops it.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body><div style="height: 3000px">x</div></body></html>`;
let clock = 1000, top = 0;
const asked = [];
const host = {
  log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
  asset: (p) => (p === "index.html" ? page : undefined),
  invoke: () => {}, timer: () => {}, focus: () => {}, scrollIntoView: () => {},
  now: () => clock, vsync: () => true,
  frame: (id) => (id === -1 ? [0, 0, 400, 600, 3000, 0, top, 0] : [0, 0, 0, 0]),
  scrollTo: (id, y) => { asked.push(y); top = Math.round(y); },
  ops: () => {},
  platform: JSON.stringify({ os: "macos", arch: "aarch64" }), label: "main", url: "index.html",
};
const ctx = vm.createContext({ __host: host });
vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
ctx.__oriel.boot(400, 600, false, false);
ctx.__oriel.render();
const frames = (n) => { for (let i = 0; i < n; i++) { clock += 1000 / 60; ctx.__oriel.vsync(1000 / 60); ctx.__oriel.scrolled([[-1, top, 0]]); } };
const key = (k) => ctx.__oriel.event(0, "key", [k, 0, false]);

key("PageDown");
assert.equal(asked.length, 0, "it starts on the next frame");
frames(1);
assert.ok(asked[0] > 0 && asked[0] < 525 * 0.1, `a slow start (${asked[0]})`);
frames(10);
assert.ok(asked[10] < 525, "still going at 11 frames");
frames(1);
assert.equal(asked.at(-1), 525, "87.5% of the view at 200 ms");
for (let i = 1; i < asked.length; i++) assert.ok(asked[i] >= asked[i - 1]);
const n = asked.length;
frames(3);
assert.equal(asked.length, n, "then it stops");

// A second PageDown while it glides: on to two pages.
asked.length = 0;
key("PageDown"); frames(4);
key("PageDown"); frames(20);
assert.equal(asked.at(-1), 525 * 3);

// An arrow: 40px over 256 ms.
asked.length = 0;
key("ArrowDown"); frames(15);
assert.ok(asked.at(-1) < 525 * 3 + 40, "still gliding at 250 ms");
frames(3);
assert.equal(asked.at(-1), 525 * 3 + 40);

// A wheel takes over: the scroller reports an offset the glide didn't set.
asked.length = 0;
key("PageUp"); frames(3);
const k = asked.length;
top = 900; ctx.__oriel.scrolled([[-1, 900, 0]]);
frames(5);
assert.equal(asked.length, k, "the wheel stopped it");

// The page's own scroll stops it too.
asked.length = 0;
key("PageDown"); frames(2);
vm.runInContext("scrollTo(0, 100)", ctx);
assert.equal(asked.at(-1), 100);
frames(5);
assert.equal(asked.at(-1), 100, "the page's scroll stopped it");

// A touch stops it.
asked.length = 0;
key("PageDown"); frames(2);
ctx.__oriel.event(0, "pointer", ["down", 10, 10, 1, 1, "touch", 0]);
const t = asked.length;
frames(5);
assert.equal(asked.length, t, "a touch stopped it");
console.log("key scroll: ok");
