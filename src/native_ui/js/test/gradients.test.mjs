import { background } from "../src/css.js";
// radial-gradient's shape, size and position, as the painters get them
// (tree.zig's Gradient.radialIn resolves `ext` against the box).
const g = (v) => { const { radial, ext, circle } = background(v).gradient; return JSON.stringify({ radial, ext, circle }); };
const cases = [
  ["radial-gradient(#fff, #000)", { radial: ["50%", "50%", "71%", "71%"], ext: "farthest-corner" }],
  ["radial-gradient(circle, #fff, #000)", { radial: ["50%", "50%", "71%", "71%"], ext: "farthest-corner", circle: true }],
  ["radial-gradient(ellipse at top left, #fff, #000)", { radial: ["0%", "0%", "71%", "71%"], ext: "farthest-corner" }],
  ["radial-gradient(circle closest-side at 20% 30%, #fff, #000)", { radial: ["20%", "30%", "71%", "71%"], ext: "closest-side", circle: true }],
  ["radial-gradient(farthest-side ellipse at right, #fff, #000)", { radial: ["100%", "50%", "71%", "71%"], ext: "farthest-side" }],
  ["radial-gradient(closest-corner at top right, #fff, #000)", { radial: ["100%", "0%", "71%", "71%"], ext: "closest-corner" }],
  ["radial-gradient(at bottom, #fff, #000)", { radial: ["50%", "100%", "71%", "71%"], ext: "farthest-corner" }],
  ["radial-gradient(40px at 10px 20px, #fff, #000)", { radial: [10, 20, 40, 40], circle: true }],
  ["radial-gradient(circle 30px, #fff, #000)", { radial: ["50%", "50%", 30, 30], circle: true }],
  ["radial-gradient(60px 20% at left top, #fff, #000)", { radial: ["0%", "0%", 60, "20%"] }],
  ["radial-gradient(ellipse 50% 25%, #fff, #000)", { radial: ["50%", "50%", "50%", "25%"] }],
];
// Invalid sizes: no gradient (CSS drops the declaration).
for (const v of ["circle 50%", "ellipse 30px", "10px 20px circle", "-5px", "closest-side 20px", "circle ellipse", "huge"]) {
  if (background(`radial-gradient(${v}, #fff, #000)`)?.gradient) { console.log("FAIL accepted", v); process.exit(1); }
}
let bad = 0;
for (const [v, want] of cases) { const got = g(v); if (got !== JSON.stringify(want)) { bad++; console.log("FAIL", v, got); } }
if (bad) { console.log(`${bad} failed`); process.exit(1); }
// Stop positions: fractions when they're all percentages (missing ones
// filled in evenly), else each stop's unit in `su` for tree.zig's
// Gradient.resolve; repeating gradients carry `rep`; "c 0 10px" is two stops.
const stops = (v) => { const { stops, su, rep } = background(v).gradient; return JSON.stringify({ pos: stops.map((s) => +s[4].toFixed(4)), su, rep }); };
const stopCases = [
  ["linear-gradient(red, yellow 20%, green, blue)", { pos: [0, 0.2, 0.6, 1] }],
  ["linear-gradient(red 30%, blue 10%)", { pos: [0.3, 0.3] }],
  ["linear-gradient(to right, red 30px, blue 130px)", { pos: [30, 130], su: "pp" }],
  ["repeating-linear-gradient(45deg, #c55 0 10px, #fc6 10px 20px)", { pos: [0, 10, 10, 20], su: "%ppp", rep: true }],
  ["repeating-linear-gradient(#222, #9cf 20%)", { pos: [0, 0.2], su: "a%", rep: true }],
  ["repeating-radial-gradient(circle, #36c 0 8px, #fff 8px 16px)", { pos: [0, 8, 8, 16], su: "%ppp", rep: true }],
];
for (const [v, want] of stopCases) { const got = stops(v); if (got !== JSON.stringify(want)) { bad++; console.log("FAIL", v, got); } }
if (bad) { console.log(`${bad} failed`); process.exit(1); }
console.log(`gradients: all ${cases.length + stopCases.length} cases pass`);
