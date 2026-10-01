import { mediaMatches, viewport } from "../src/css.js";
Object.assign(viewport, { width: 540, height: 680, dark: true });
const cases = [["(width<=720px)", true], ["(width <= 500px)", false], ["(400px < width <= 720px)", true], ["(min-width: 600px)", false], ["(max-width: 720px)", true], ["not (width<=720px)", false], ["only screen and (width<=720px)", true], ["(prefers-color-scheme:dark)", true], ["(height>=700px)", false], ["(width<=45em)", true], ["(400px<width)", true], ["screen and (width>=600px)", false]];
// Media Queries 4 ranges (Vite/lightningcss output), not, only.
let bad = 0; for (const [q, want] of cases) { const got = mediaMatches(q); if (got !== want) { bad++; console.log("FAIL", q, got); } }
if (bad) { console.log(`${bad} failed`); process.exit(1); }
console.log(`media: all ${cases.length} cases pass`);
