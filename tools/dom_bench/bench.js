// The native DOM against linkedom (docs/native-dom.md, phase 0): the same DOM
// work as the render bench's rows, without the renderer. `document` is the
// native one, or linkedom's when the tool loaded it (globalThis.parseHTML).
const doc = globalThis.parseHTML
  ? globalThis.parseHTML("<!doctype html><html><body></body></html>").document
  : document;
let body = doc.body;
if (!body) { body = doc.createElement("body"); doc.append(body); }
const now = () => performance.now();
const median = (xs) => [...xs].sort((a, b) => a - b)[xs.length >> 1];
const ROWS = +(globalThis.ROWS || 1000), RUNS = 7;
const times = { build: [], walk: [], update: [], clear: [] };
let sink = 0;
for (let r = 0; r < RUNS; r++) {
  let t = now();
  const list = doc.createElement("div");
  for (let i = 0; i < ROWS; i++) {
    const row = doc.createElement("div");
    row.className = "row";
    row.innerHTML = `<span class="n">${i}</span><span class="dot"></span><span>Row ${i}: the quick brown fox</span>`;
    list.append(row);
  }
  body.append(list);
  times.build.push(now() - t);
  if (r === 0) {
    // What was built, as text: the same for both implementations.
    const out = [];
    const dump = (n, d) => {
      if (n.nodeType === 1) {
        out.push(`${d}<${n.localName} class=${n.getAttribute("class")} id=${n.getAttribute("id")}>`);
        for (let c = n.firstChild; c; c = c.nextSibling) dump(c, d + 1);
      } else out.push(`${d}#${n.nodeType} ${n.data}`);
    };
    dump(list, 0);
    let h = 0;
    for (const line of out) for (let k = 0; k < line.length; k++) h = (h * 31 + line.charCodeAt(k)) | 0;
    globalThis.CHECK = `${out.length} nodes, hash ${h >>> 0}, row 7: ${list.children[7].textContent} / ${list.children[7].lastElementChild.textContent}`;
  }
  // What the renderer reads: every node, its type, name, class and text.
  t = now();
  for (let n = list.firstChild; n; ) {
    sink += n.nodeType;
    if (n.nodeType === 1) { sink += n.localName.length; const c = n.getAttribute("class"); if (c) sink += c.length; }
    else sink += n.data.length;
    if (n.firstChild) { n = n.firstChild; continue; }
    while (n && !n.nextSibling && n !== list) n = n.parentNode;
    n = n === list ? null : n.nextSibling;
  }
  times.walk.push(now() - t);
  t = now();
  let i = 0;
  for (const row of list.children) row.lastElementChild.textContent = `Row ${i++}: updated ${r}`;
  times.update.push(now() - t);
  t = now();
  body.textContent = "";
  times.clear.push(now() - t);
}
const impl = globalThis.parseHTML ? "linkedom" : "native  ";
print(`${impl} check: ${globalThis.CHECK}`);
print(`${impl} ${ROWS} rows: build ${median(times.build).toFixed(2)} ms, walk ${median(times.walk).toFixed(2)} ms, update ${median(times.update).toFixed(2)} ms, clear ${median(times.clear).toFixed(2)} ms` + (sink ? "" : " "));
