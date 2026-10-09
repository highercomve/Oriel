// dom_bench tools/dom_bench/wrappers.test.js: a node's wrapper keeps its
// identity, and what the page keyed to it, while its tree can be reached:
// weak references (WeakMap, WeakSet, WeakRef) to wrappers of a removed
// tree survive the store's pruning, a cycle collection and reattaching.
function check(ok, what) { if (!ok) throw new Error("FAIL: " + what); }
const root = document.appendChild(document.createElement("html"));
const body = root.appendChild(document.createElement("body"));

// A list in the document, rows the page only references weakly.
const list = document.createElement("ul");
for (let i = 0; i < 4; i++) list.appendChild(document.createElement("li"));
body.appendChild(list);
const keyed = new WeakMap();
const seen = new WeakSet();
keyed.set(list.children[0], "row 0");
seen.add(list.children[1]);
const ref = new WeakRef(list.children[2]);
// The page drops its own strong references (only `list` stays).
list.remove(); // detached: the store releases what nothing else references
gc();
__nuiDom.collect();
body.appendChild(list);
check(keyed.get(list.children[0]) === "row 0", "a WeakMap entry for a removed row");
check(seen.has(list.children[1]), "a WeakSet entry for a removed row");
check(ref.deref() === list.children[2], "a WeakRef to a removed row derefs to its wrapper");

// A detached clone the page walks and marks (Solid's way): the expando
// survives until the clone is inserted.
const tpl = document.createElement("div");
tpl.innerHTML = "<p><b>x</b></p><button>y</button>";
const copy = tpl.cloneNode(true);
copy.lastChild.marked = "click";
gc();
__nuiDom.collect();
body.appendChild(copy);
check(copy.lastChild.marked === "click", "an expando on a detached clone");

// The mutation hook runs page code: only once the store's operation is
// complete, so what that code changes can't break the operation.
const once = (kind, f) => { let done = false; return (k, target, node) => { if (k === kind && !done) { done = true; f(target, node); } }; };
{
  // insertBefore: the move's removal clears the destination.
  const P = document.createElement("div"), Q = document.createElement("div");
  const X = Q.appendChild(document.createElement("i"));
  P.appendChild(document.createElement("a"));
  const R = P.appendChild(document.createElement("b"));
  __nuiDom.observe(once(2, () => { P.textContent = ""; }), false);
  P.insertBefore(X, R);
  __nuiDom.observe(null, true);
  check(P.firstChild === null && P.lastChild === null, "insertBefore: the hook's clearing applies after the insertion");
  check(X.parentNode === null && R.parentNode === null && Q.firstChild === null, "insertBefore: no node left half-linked");
}
{
  // A deep clone: the copy's first insertion clears the source.
  const src = document.createElement("div");
  src.innerHTML = "<p>1</p><p>2</p><p>3</p>";
  __nuiDom.observe(once(1, () => { src.textContent = ""; }), false);
  const c = src.cloneNode(true);
  __nuiDom.observe(null, true);
  check(src.firstChild === null && c.childNodes.length === 3 && c.lastChild.textContent === "3", "a deep clone the hook empties the source of");
}
{
  // The parser: the first insertion removes the element being filled.
  const host = document.createElement("div");
  __nuiDom.observe(once(1, (target) => { if (target.parentNode) target.remove(); }), false);
  host.innerHTML = "<section><p><b>x</b><i>y</i></p></section>";
  __nuiDom.observe(null, true);
  gc();
  __nuiDom.collect();
  check(host.firstChild.localName === "section", "markup parsed while the hook removes what it fills");
}

print("wrappers: ok");
