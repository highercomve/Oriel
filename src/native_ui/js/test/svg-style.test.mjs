// node test/svg-style.test.mjs: an SVG's own <style> (Vite's logo: class
// fills and a prefers-color-scheme rule, on a root with fill="none")
// paints its shapes; the cascade: its sheet and the style attribute over
// presentation attributes, media queries answered, display: none and
// opacity.
import assert from "node:assert/strict";
import { parseHTML } from "../vendor/linkedom/esm/index.js";
import { viewport } from "../src/css.js";
import { iconFor } from "../src/icons.js";

const { document } = parseHTML(`<html><body>
<svg id="logo" viewBox="0 0 48 48" fill="none">
  <style>
    .parenthesis { fill: #000; }
    @media (prefers-color-scheme: dark) { .parenthesis { fill: #fff; } }
    #bolt { fill: #863bff; }
    .gone { display: none; }
    .half { opacity: .5; }
  </style>
  <path class="parenthesis" d="M1 1h4v4z"/>
  <path id="bolt" fill="red" d="M10 10h4v4z"/>
  <path fill="red" style="fill: #0f0" d="M20 20h4v4z"/>
  <path class="gone" fill="#123" d="M30 30h4v4z"/>
  <g class="half"><path fill="#00f" d="M40 40h4v4z"/></g>
  <path d="M5 5h1v1z"/>
</svg></body></html>`);
const svg = document.getElementById("logo");
const fills = () => iconFor(svg, { color: "black" }, document).shapes.map((s) => s.fill && s.fill.map((v) => +v.toFixed(2)).join(","));

viewport.dark = false;
assert.deepEqual(fills(), [
  "0,0,0,1",       // .parenthesis
  "134,59,255,1",  // #bolt over its fill attribute
  "0,255,0,1",     // the style attribute over the fill attribute
  // .gone: display: none, not drawn
  "0,0,255,0.5",   // in a group at opacity .5
  null,            // the root's fill="none", inherited
]);
viewport.dark = true;
assert.equal(fills()[0], "255,255,255,1", "the dark scheme's rule");
// As an image (an <img> of it): light, whatever the page's scheme.
assert.equal(iconFor(svg, { color: "black" }, document, null, { image: true }).shapes[0].fill.join(","), "0,0,0,1");
assert.equal(viewport.dark, true, "the page's scheme left as it was");
viewport.dark = false;
console.log("svg style: ok");
