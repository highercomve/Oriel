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
console.log(`gradients: all ${cases.length} cases pass`);
