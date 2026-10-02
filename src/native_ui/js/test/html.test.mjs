// The innerHTML fast path (src/html.js) builds what linkedom's parser
// builds, or gives up (null) for markup it doesn't handle.
import { parseHTML } from "linkedom";
import { parseSimple } from "../src/html.js";

const { document } = parseHTML("<!doctype html><html><body></body></html>");
const same = [
  `<span class="n">1</span><span class="dot"></span><span>Row 1: the quick brown fox</span>`,
  `plain text`,
  `a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39; &#x41; &nbsp;x`,
  `<div id="x" data-a='1' hidden><b>bold</b> <i>it</i><br><img src="a.png" alt="&lt;img&gt;"><input type=checkbox checked></div>`,
  `<!-- note --><section><h2 title="T &amp; U">Title</h2><ul class="m"></ul></section>`,
  `<my-widget foo="bar">x</my-widget>`,
  `  <div>\n  <span>a</span>\n</div>  `,
  `<button-like>x</button-like>`,
];
const fallback = [
  `<p>a<p>b`, `<li>x`, `<table><tr><td>1</td></tr></table>`, `<script>1<2</script>`, `<div/>`,
  `<div>`, `</div>`, `<div></span>`, `<svg><path d="M0 0"/></svg>`, `&copy;`, `&amp`, `<a href="#">x</a>`,
  `<div a=1 a=2></div>`, `<textarea>x</textarea>`, `<!-- open`, `<div <span>`,
];
let failed = 0;
for (const html of same) {
  const viaParser = document.createElement("div");
  viaParser.innerHTML = html;
  const frag = parseSimple(document, html);
  const viaFast = document.createElement("div");
  if (frag) viaFast.replaceChildren(frag);
  if (!frag || viaFast.innerHTML !== viaParser.innerHTML || viaFast.textContent !== viaParser.textContent) {
    failed++;
    console.error(`html: differs for ${JSON.stringify(html)}\n  parser: ${viaParser.innerHTML}\n  fast:   ${frag ? viaFast.innerHTML : "(null)"}`);
  }
}
for (const html of fallback) {
  if (parseSimple(document, html) !== null) { failed++; console.error(`html: should fall back: ${JSON.stringify(html)}`); }
}
if (failed) { console.error(`html: ${failed} failed`); process.exit(1); }
console.log(`html: all ${same.length + fallback.length} cases pass`);
