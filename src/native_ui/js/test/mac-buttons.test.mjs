// node test/mac-buttons.test.mjs: macOS buttons as WKWebView draws them
// (measured): while the page leaves its background, border and appearance
// alone, AppKit's push button (no border: WebKit's computed border is 0;
// its 2px a side kept as room; white, 4px corners, a hairline edge);
// otherwise the CSS box on ButtonFace (192), the outset's dark sides as
// WebKit shades them (108). Other platforms keep the CSS box.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><body>
<button id="push">Go</button>
<button id="padded" style="padding: 4px 10px">Go</button>
<button id="none" style="appearance: none">Go</button>
<button id="bg" style="background: #eee">Go</button>
<button id="border" style="border: 1px solid #888">Go</button>
</body></html>`;
function props(os) {
  const nodes = new Map();
  const host = {
    log: (lvl, msg) => { if (lvl >= 3) console.log(msg); },
    asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) { if (k === "c") nodes.set(id, { props: {} }); else if (k === "p") nodes.get(id).props = x; } },
    platform: JSON.stringify({ os }), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(600, 400, false, false);
  ctx.__oriel.render();
  // The buttons, in order: the clickable boxes.
  const boxes = [...nodes.values()].map((n) => n.props).filter((p) => p.click);
  return boxes;
}
const [push, padded, none, bg, border] = props("macos");
assert.equal(push.bw, undefined, "a push button has no border");
assert.deepEqual(push.pad, [2, 8, 3, 8], "WebKit's padding, and the bezel's 2px a side");
assert.deepEqual(push.bg.color, [255, 255, 255, 1]);
assert.deepEqual(push.br, [4, 4, 4, 4]);
assert.deepEqual(padded.pad, [4, 12, 4, 12]);
assert.deepEqual(none.bw, [2, 2, 2, 2], "appearance: none: the CSS box");
assert.deepEqual(none.bg.color, [192, 192, 192, 1], "on ButtonFace");
assert.deepEqual(none.bc[0], [192, 192, 192, 1]);
assert.deepEqual(none.bc[2], [108, 108, 108, 1], "the outset's dark side");
assert.deepEqual(bg.bg.color, [238, 238, 238, 1], "the page's background");
assert.ok(bg.bw, "and its border");
assert.deepEqual(border.bw, [1, 1, 1, 1]);
const [win] = props("windows");
assert.ok(win.bw, "elsewhere: the CSS box");
console.log("mac buttons: ok");
