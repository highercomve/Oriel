// node --expose-gc test/canvas-clear.test.mjs: a full clearRect restarts the
// canvas program even while a style is a gradient (a game loop drawing
// with one no longer grows its program without bound), and every gradient
// the page can still paint with is defined again after the restart.
import assert from "node:assert/strict";
import { install, commandsOf } from "../src/canvas.js";

class Canvas { constructor() { this.a = {}; } getAttribute(k) { return this.a[k] ?? null; } setAttribute(k, v) { this.a[k] = String(v); } }
install({ HTMLCanvasElement: Canvas }, () => {});
const el = new Canvas();
const cx = el.getContext("2d");
const ops = () => commandsOf(el);
const defined = (id) => ops().some((o) => (o[0] === "gl" || o[0] === "gr") && o[1] === id);

const g = cx.createLinearGradient(0, 0, 300, 0);
g.addColorStop(0, "red"); g.addColorStop(1, "blue");
const kept = cx.createRadialGradient(10, 10, 0, 10, 10, 5);
kept.addColorStop(0, "white");
cx.fillStyle = g;
for (let frame = 0; frame < 500; frame++) {
  cx.clearRect(0, 0, 300, 150);
  cx.fillRect(frame % 300, 10, 20, 20);
}
assert.ok(ops().length < 40, `the program restarts at each clear: ${ops().length} ops`);
assert.ok(defined(g.__grad), "the style's gradient is defined again");
assert.equal(ops().filter((o) => o[0] === "gs" && o[1] === g.__grad).length, 2, "with its stops");
assert.ok(defined(kept.__grad), "a gradient the page still holds stays defined");

// A gradient made per frame and dropped goes once it is collected; the one
// the style paints with stays even though the page dropped its object.
if (typeof globalThis.gc === "function") {
  (() => { cx.strokeStyle = cx.createLinearGradient(0, 0, 1, 1); })();
  const strokeId = cx.strokeStyle[1];
  for (let i = 0; i < 50; i++) cx.createLinearGradient(0, 0, i, i);
  for (let i = 0; i < 5; i++) { globalThis.gc(); await new Promise((r) => setTimeout(r, 0)); }
  cx.clearRect(0, 0, 300, 150);
  assert.ok(defined(strokeId), "the stroke style's gradient survives its object");
  const gradients = ops().filter((o) => o[0] === "gl" || o[0] === "gr").length;
  assert.ok(gradients <= 4, `dropped gradients go: ${gradients} defined`);
}
console.log("canvas clear: ok");
