// node test/forced-colors.test.mjs: forced colors mode (the system's high
// contrast theme, platform.forcedColors): elements take the system's
// colors for what they are, forced-color-adjust: none keeps the page's,
// the media queries see it, system color keywords resolve to it; and the
// "forcedColors" event turns it off again.
import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const page = `<html><head><style>
body { color: #336699; background: #fafafa; }
.card { background: linear-gradient(red, blue); color: #ff00ff; box-shadow: 0 0 4px black; }
.keep { forced-color-adjust: none; color: #123456; background: #abcdef; }
.flag { color: #111111; }
@media (forced-colors: active) { .flag { color: #222222; border: 1px solid ButtonText; } }
@media (prefers-contrast: more) { .more { color: #333333; } }
.sys { color: Highlight; }
</style></head><body>
<p id="plain">Plain text</p>
<p><a href="#x">A link <b>bold</b></a></p>
<div class="card">Card</div>
<div class="keep">Kept</div>
<p class="flag">Flag</p>
<p class="more">More</p>
<p class="sys">Sys</p>
<button>Go</button>
<input value="v"><input value="off" disabled>
</body></html>`;

const forced = { dark: true, colors: { Canvas: [0, 0, 0], CanvasText: [255, 255, 255], LinkText: [255, 255, 0], GrayText: [63, 242, 63],
  ButtonFace: [0, 0, 0], ButtonText: [255, 255, 255], Field: [0, 0, 0], FieldText: [255, 255, 255], Highlight: [26, 235, 255], HighlightText: [0, 0, 0] } };

function boot(platform) {
  const props = new Map();
  const host = {
    log: (lvl, msg) => { if (lvl >= 2) console.log(msg); },
    asset: (p) => (p === "index.html" ? page : undefined),
    invoke: () => {}, timer: () => {}, frame: () => undefined, focus: () => {}, scrollIntoView: () => {}, scrollTo: () => {},
    ops: (json) => { for (const [k, id, x] of JSON.parse(json)) if (k === "p" || k === "c") if (x && typeof x === "object" && !Array.isArray(x)) props.set(id, { ...(props.get(id) || {}), ...x }); },
    platform: JSON.stringify(platform), label: "main", url: "index.html",
  };
  const ctx = vm.createContext({ __host: host });
  vm.runInContext(fs.readFileSync(new URL("../../runtime.js", import.meta.url), "utf8"), ctx, { filename: "runtime.js" });
  ctx.__oriel.boot(400, 900, false, false);
  ctx.__oriel.render();
  return { ctx, props };
}

const rgb = (c) => (c ? c.slice(0, 3).map(Math.round) : null);
// The runs of the text that reads `t`, and its node's props.
function textOf(props, t) {
  for (const p of props.values()) if (p.runs && p.runs.some((r) => r.t.includes(t))) return p;
  return null;
}
function runColor(props, t) {
  for (const p of props.values()) if (p.runs) for (const r of p.runs) if (r.t.includes(t)) return rgb(r.c);
  return null;
}

{
  const { ctx, props } = boot({ os: "windows", forcedColors: forced });
  assert.deepEqual(runColor(props, "Plain"), [255, 255, 255], "text: CanvasText");
  assert.deepEqual(runColor(props, "A link"), [255, 255, 0], "a link: LinkText");
  assert.deepEqual(runColor(props, "bold"), [255, 255, 0], "inside a link: the link's");
  const card = textOf(props, "Card");
  assert.deepEqual(runColor(props, "Card"), [255, 255, 255], "a page color: CanvasText");
  assert.ok(!card.bg?.gradient, "no gradient");
  assert.ok(!card.sh, "no shadow");
  assert.deepEqual(runColor(props, "Kept"), [0x12, 0x34, 0x56], "forced-color-adjust: none keeps the page's color");
  assert.deepEqual(rgb(textOf(props, "Kept").bg?.color), [0xab, 0xcd, 0xef], "and its background");
  assert.deepEqual(runColor(props, "Flag"), [255, 255, 255], "forced: the page's color in a forced-colors rule is forced too");
  assert.ok(textOf(props, "Flag").bw, "@media (forced-colors: active) matched (its border)");
  assert.equal(ctx.matchMedia("(forced-colors: active)").matches, true);
  assert.equal(ctx.matchMedia("(prefers-contrast: more)").matches, true);
  assert.equal(ctx.matchMedia("(prefers-color-scheme: dark)").matches, true, "the high contrast theme's scheme");
  const fields = [...props.values()].filter((p) => p.val !== undefined || p.ph !== undefined);
  assert.ok(fields.length >= 2, "two fields");
  for (const f of fields) assert.deepEqual(rgb(f.bg?.color), [0, 0, 0], "a field on Field");
  assert.ok(fields.some((f) => f.dis && rgb(f.col)?.join() === "63,242,63"), "a disabled field in GrayText");
  // Off again: the page's own colors.
  ctx.__oriel.event(0, "forcedColors", "null");
  ctx.__oriel.render();
  assert.deepEqual(runColor(props, "Plain"), [0x33, 0x66, 0x99], "off: the page's color");
  assert.equal(ctx.matchMedia("(forced-colors: active)").matches, false);
}

{
  // Not forced: system color keywords resolve to the defaults.
  const { props } = boot({ os: "windows" });
  assert.deepEqual(runColor(props, "Sys"), [0x33, 0x90, 0xff], "Highlight: its default");
  assert.deepEqual(runColor(props, "Flag"), [0x11, 0x11, 0x11], "no forced-colors rule");
}
console.log("forced colors: ok");
