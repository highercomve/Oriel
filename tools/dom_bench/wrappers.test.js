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

print("wrappers: ok");
