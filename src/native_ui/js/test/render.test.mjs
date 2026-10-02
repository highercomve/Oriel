import assert from "node:assert/strict";
import { parseHTML } from "../vendor/linkedom/esm/index.js";
import { StyleEngine } from "../src/css.js";
import { Renderer, UA_CSS } from "../src/render.js";
import { transitionsOf } from "../src/transitions.js";

globalThis.requestAnimationFrame = () => 0;

function makeRenderer(document, css, reference = false, direct = false) {
  const engine = new StyleEngine();
  engine.addSheet(UA_CSS + css);
  const nodes = new Map(), batches = [];
  const leafStyles = new Map();
  const directCreates = [];
  const renderer = new Renderer(document, engine, {
    leafStyle: direct ? (id, json) => { leafStyles.set(id, JSON.parse(json)); return true; } : undefined,
    leaf: direct ? (id, style, text, isText) => {
      if (nodes.has(id)) return false;
      const props = structuredClone(leafStyles.get(style));
      if (isText) props.runs[0].t = text;
      nodes.set(id, { kind: isText ? "text" : "view", props, kids: [] });
      directCreates.push(id);
      return true;
    } : undefined,
    text: direct ? (id, text) => {
      nodes.get(id).props.runs[0].t = text;
      return true;
    } : undefined,
    ops(json) {
      const ops = JSON.parse(json);
      batches.push(ops);
      for (const [op, id, x] of ops) {
        if (op === "c") nodes.set(id, { kind: x, props: {}, kids: [] });
        if (op === "p") nodes.get(id).props = x;
        if (op === "k") {
          // Native nodes have one parent: attaching a moved child also
          // detaches it from its previous parent's children.
          for (const [parent, n] of nodes) if (parent !== id) n.kids = n.kids.filter((k) => !x.includes(k));
          nodes.get(id).kids = x;
        }
        if (op === "d") nodes.delete(id);
      }
    },
    frame: () => [0, 0, 600, 400, 400],
  });
  // A fresh traversal with independent selector matches is the reference.
  if (reference) {
    renderer.matchOf = (el) => engine.matching(el);
    renderer.simpleLeaves = false;
  }
  const tree = (id = 0) => {
    const n = nodes.get(id);
    return n && { kind: n.kind, props: n.props, kids: n.kids.map((k) => tree(k)) };
  };
  return { renderer, nodes, batches, tree, directCreates };
}

function fixture(css, direct = false) {
  const { document, window } = parseHTML("<html><body><main></main></body></html>");
  const got = makeRenderer(document, css, false, direct);
  const observer = new window.MutationObserver(() => {});
  observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
  got.renderer.observer = observer;
  const check = () => {
    got.renderer.render();
    const ref = makeRenderer(document, css, true);
    ref.renderer.render();
    assert.deepEqual(got.tree(), ref.tree());
  };
  return { document, ...got, check };
}

{
  const { document } = parseHTML('<html><body></body></html>');
  const { renderer } = makeRenderer(document, '');
  const element = document.createElement('div');
  const primary = renderer.idOf(element, 'el');
  assert.equal(typeof renderer.ids.get(element), 'number', 'ordinary elements need no id dictionary');
  const pseudo = renderer.idOf(element, 'before');
  assert.notEqual(pseudo, primary);
  assert.equal(renderer.idOf(element, 'el'), primary, 'expanding id storage preserves the primary id');
  assert.equal(renderer.idOf(element, 'before'), pseudo);
  assert.notEqual(renderer.idOf(element, 'row0'), primary);
}

// The first edit after typed creation still has a lazy previous snapshot.
// A declined text bridge must compare against the original text.
{
  const f = fixture('.row { display: flex }', true);
  f.document.querySelector('main').innerHTML = '<div class="row"><span>before</span></div>';
  f.renderer.render();
  f.renderer.observer.takeRecords();
  let declined = 0;
  f.renderer.host.text = () => { declined++; return false; };
  f.document.querySelector('span').textContent = 'after';
  f.check();
  assert.equal(declined, 1, "first edit reaches the direct bridge before fallback");
}

// A full restyle invalidates matching while preserving last-style reads
// for elements no longer visited under a hidden ancestor.
{
  const f = fixture('.row { display:flex } .leaf { width:40px }', true);
  f.document.querySelector('main').innerHTML = '<div class="row"><span class="leaf">one</span></div><div class="row"><span class="leaf">two</span></div>';
  f.check();
  const leaves = [...f.document.querySelectorAll('.leaf')];
  assert.ok(Object.isFrozen(f.renderer.fc.get(leaves[1]).root.kids));
  f.renderer.engine.addSheet('.leaf { width:75px; color:blue }');
  f.renderer.markAll();
  f.renderer.render();
  for (const leaf of leaves) assert.equal(f.renderer.styleOf(leaf).width, '75px');
  leaves[1].parentNode.style.display = 'none';
  f.renderer.markAll();
  f.renderer.render();
  assert.equal(f.renderer.styleOf(leaves[1]).width, '75px');
}

for (const direct of [false, true]) for (const extra of ["", ".row:first-child .n { color: red } .row + .row .dot { width: 9px }"]) {
  const f = fixture(`.row { display: flex } .n { width: 30px } .dot { width: 5px } .theme span { color: green } ${extra}`, direct);
  const stage = f.document.querySelector("main");
  stage.innerHTML = `<section>${Array.from({ length: 30 }, (_, i) => `<div class="row"><span class="n">${i}</span><!-- gap --><span class="dot"></span><span>Row ${i}</span></div>`).join("")}</section>`;
  f.check();
  if (direct) {
    assert.ok(f.directCreates.length > 0);
    assert.ok(!f.batches.flat().some(([op, id]) => f.directCreates.includes(id) && (op === "c" || op === "p")), "direct creation avoids redundant JSON create/props operations");
    assert.ok(!f.batches.flat().some(([op, id, kids]) => f.directCreates.includes(id) && op === "k" && !kids.length), "new leaves need no empty child operation");
  }
  const row = stage.querySelector(".row"), text = row.lastElementChild;
  text.textContent = "Changed";
  f.check();
  row.setAttribute("data-nui-focus", "");
  row.style.width = "200px";
  text.style.color = "blue";
  stage.className = "theme";
  f.check();
  text.removeAttribute("style");
  stage.className = "";
  row.parentNode.append(row);
  f.check();
  row.remove();
  stage.append(row);
  f.check();
  text.textContent = "Changed after reattachment";
  f.check();
  row.setAttribute("hidden", "");
  f.check();
  row.removeAttribute("hidden");
  f.check();
  const count = f.batches.length;
  f.renderer.render();
  assert.equal(f.batches.length, count, "unchanged frames send no operations");
}

// Descendants distinguish otherwise identical cousins for :has().
{
  const f = fixture(".card { width: 20px } .card:has(.active) { width: 80px }");
  f.document.querySelector("main").innerHTML = '<div class="card"><span class="active">A</span></div><div class="card"><span>B</span></div>';
  f.check();
  const cards = f.document.querySelectorAll(".card");
  assert.equal(f.renderer.styleOf(cards[0]).width, "80px");
  assert.equal(f.renderer.styleOf(cards[1]).width, "20px");
  cards[0].firstChild.className = "";
  cards[1].firstChild.className = "active";
  f.check();
}

// Equivalent box styles can still have different descendant rules. Flex
// templates must distinguish selector ancestry and start fresh each frame.
{
  const f = fixture(".row { display: flex } .a .row span { color: red } .b .row span { color: blue }", true);
  const main = f.document.querySelector("main");
  for (const order of [["a", "b"], ["b", "a"]]) {
    main.innerHTML = order.map((cls) => `<section class="${cls}"><div class="row"><span>first</span><span>second</span></div><div class="row"><span>third</span><span>fourth</span></div></section>`).join("");
    f.check();
  }
}

// Direct and JSON text updates agree with a fresh traversal, including
// fallbacks that change kind/flow and general renders after direct writes.
for (const direct of [false, true]) {
  const f = fixture(".row { display: flex } .label { color: red; text-transform: uppercase }", direct);
  const main = f.document.querySelector("main");
  main.innerHTML = '<div class="row"><span class="label">Old</span><span>Fixed</span></div>';
  const label = main.querySelector(".label");
  f.check();
  for (const text of ["New", "quote \" \\ Ω\u0000", "", "   ", "Restored"]) {
    label.textContent = text;
    f.check();
  }
  label.firstChild.data = "Changed in place";
  f.check();
  label.append(f.document.createTextNode(" and more"));
  f.check();
  label.textContent = "Single";
  f.check();
  label.style.width = "50px";
  f.check();
  label.textContent = "Latest";
  f.check();
  // A changed click listener uses markFlat and must rebuild click props.
  label.addEventListener("click", () => {});
  f.renderer.markFlat(label);
  f.check();
  // If the native bridge declines, use the ordinary property operation.
  if (direct) f.renderer.host.text = () => false;
  label.textContent = "Fallback";
  f.check();
  if (direct) f.renderer.host.leaf = () => false;
  label.append(f.document.createElement("div"));
  f.check();
  label.innerHTML = "Mixed <b>bold</b>";
  f.check();
  main.firstChild.remove();
  f.check();
}

// Repeated flex leaves may differ in text emptiness, order, listeners and
// inline styles; complex children and pseudo-elements must stay general.
for (const css of [
  ".row { display: flex; align-items: center } span { order: 2 } .first { order: -1; align-self: end }",
  ".row { display: flex } span { display: inline-flex; justify-content: center }",
  ".row { display: flex } span::after { content: 'after' }",
  ".row { display: flex } .first { position: fixed }",
  ".row { display: flex } span { transition: width 100ms linear }",
]) {
  const f = fixture(css, true), main = f.document.querySelector("main");
  main.innerHTML = '<div class="row"><span class="first">text</span><span></span></div><div class="row"><span class="first"></span><span>changed</span></div>';
  main.lastElementChild.lastElementChild.__listens = 1;
  f.check();
  main.innerHTML = '<div class="row"><span class="first" style="width: 50px">one</span><span>two</span></div><div class="row"><span class="first" style="width: 80px">three</span><span><b>mixed</b></span></div>';
  f.check();
}

// Text leaves keep the parent's layout adjustments outside flex rows too;
// inline aggregation and structural selectors must use the fallback.
for (const css of [
  "div { display: block } span { display: block }",
  "div { display: grid; gap: 4px }",
  "div { display: block } span { display: inline }",
  "div { display: flex } span:empty { width: 50px }",
  "div { display: flex } span::before { content: 'prefix' }",
]) {
  const f = fixture(css, true);
  const main = f.document.querySelector("main");
  main.innerHTML = '<div><span>Old</span><span>Sibling</span></div>';
  f.check();
  const label = main.querySelector("span");
  for (const text of ["New", "", "Restored"]) {
    label.textContent = text;
    f.check();
  }
}

// The cached root props retain defaults for the parent's next traversal;
// on the wire, absence resets a previous row/center to column/stretch.
{
  const { document } = parseHTML("<html><body></body></html>");
  const f = makeRenderer(document, "");
  const emit = (props) => f.renderer.emit(new Map([[1, { kind: "view", props, kids: [] }]]), false);
  emit({ fd: "row", ai: "center" });
  emit({ fd: "column", ai: "stretch" });
  assert.deepEqual(f.nodes.get(1).props, {});
  const count = f.batches.length;
  emit({ fd: "column", ai: "stretch" });
  assert.equal(f.batches.length, count);
}

// Animation ticks use the same wire defaults as a normal render.
{
  const { document } = parseHTML("<html><body></body></html>");
  const f = makeRenderer(document, "");
  const originalNow = Date.now;
  let now = 1000;
  Date.now = () => now;
  try {
    f.renderer.specs.set(1, transitionsOf({ transition: "width 100ms linear" }));
    const emit = (w) => f.renderer.emit(new Map([[1, { kind: "view", props: { fd: "column", ai: "stretch", w }, kids: [] }]]), false);
    emit(0);
    now = 1010;
    emit(100);
    now = 1060;
    f.renderer.tick();
    assert.deepEqual(f.nodes.get(1).props, { w: 50 });
  } finally {
    Date.now = originalNow;
  }
}

// Finishing transient runs must keep mixed inline whitespace and paint.
{
  const f = fixture("span { color: red }");
  const main = f.document.querySelector("main");
  main.innerHTML = " A <span> B </span>C ";
  f.check();
  const props = f.nodes.get(f.renderer.idOf(main, "el")).props;
  assert.equal(props.runs.map((r) => r.t).join(""), "A B C");
  assert.deepEqual(props.runs[1].c, [255, 0, 0, 1]);
  assert.ok(props.runs.every((r) => !Object.hasOwn(r, "ws")));
}


// A text-only button keeps a box that centers its label in its height (a
// row of flex: 1 buttons stretches the short ones to the tallest); the label
// spans its width, so the button's text-align applies (a menu item's left).
{
  const f = fixture(".seg { display: flex } .seg button { flex: 1 } .menu { display: block; width: 100%; text-align: left }");
  const stage = f.document.querySelector("main");
  stage.innerHTML = '<div class="seg"><button>A</button><button>A much longer label</button></div><button class="menu">Item</button>';
  f.check();
  const find = (n, pred) => pred(n) ? n : n.kids.map((k) => find(k, pred)).find(Boolean);
  const tree = f.tree();
  const labelOf = (t) => find(tree, (n) => n.kind === "text" && n.props.runs?.[0]?.t === t);
  const boxOf = (label) => find(tree, (n) => n.kids.includes(label));
  const a = labelOf("A"), item = labelOf("Item");
  assert.ok(a && item, "the labels are text nodes");
  assert.equal(boxOf(a).kind, "view", "inside a box");
  assert.equal(boxOf(a).props.jc, "center", "centered in its height");
  assert.equal(boxOf(a).props.ai ?? "stretch", "stretch", "spanning its width (stretch: the wire default)");
  assert.equal(a.props.ta, "center", "a button's label is centered by its text-align");
  assert.equal(item.props.ta ?? "left", "left", "a menu item's stays left (left: the wire default)");
}

console.log("render: incremental trees, selector sharing, and wire defaults pass");
