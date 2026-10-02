# Native DOM: design

Status: proposal (2026-10-02). Owner: perf/native-engine.

The native renderer (`-Dnative_ui`) runs the page's DOM as JavaScript inside
QuickJS (linkedom, vendored in `src/native_ui/js/vendor/linkedom`), and its
style engine and flattener as JavaScript too (`css.js`, `render.js`). This
document proposes moving the DOM into Zig, then the style engine and the
flattener, in phases that each must be faster than what they replace.

## Why

Render bench on the desktop (Linux, one visible run), building rows, after
the QuickJS work (fixed Map hashing, JSON fast path, bytecode runtime):

| | build 1000 / 3000 rows | update 1000 / 3000 rows |
|---|---|---|
| native, QuickJS (main) | 83 / 250 ms | 10.0 / 30.6 ms |
| JavaScriptCore, interpreter only | 65 / 209 ms | 8.4 / 33.4 ms |
| JavaScriptCore with its JIT | 18 / 60 ms | 2.4 / 4.3 ms |
| WebView | 19 / 69 ms | 10 / 40 ms |

JavaScriptCore's speed is almost all its JIT, which we don't use (memory: 440+
MB; not allowed on iOS). Interpreter-level work on QuickJS is near its limit
(an inline property cache gave 0.5%; see the vendor README). What's left is the
amount of JavaScript run per row.

Where building 1000 rows spends its JavaScript time (QuickJS function profiler,
`-DORIEL_QJS_FUNC_PROFILE`):

| share | where |
|---|---|
| ~45% | `render.js`: styling, flattening, encoding the native nodes |
| ~33% | linkedom: creating elements, the tree, mutation callbacks |
| ~6% | `html.js`: innerHTML |

Cost of single operations in QuickJS (`qjs`, ns per operation):

| operation | ns |
|---|---|
| call a C function / C getter | ~35 / ~19 |
| call a JS method / JS getter | ~54 / ~62 |
| linkedom `firstChild` / `nextSibling` | 142 / 128 |
| linkedom `getAttribute("id")` | 256 |
| linkedom `createElement("span")` | 1,940 |
| linkedom create + append + remove | 3,544 |

A call into C is cheaper than any linkedom operation, and linkedom's element
creation is two orders of magnitude above a C call: a native DOM reached from
JavaScript through C functions can be several times faster, and the renderer
reading the tree benefits too (every `firstChild`, `nextSibling`,
`getAttribute` it does today is a linkedom call).

## Goal and gates

Each phase lands only if it is faster than what it replaces, on these
measurements, and breaks nothing:

- the QuickJS harness (`src/native_ui/js/test/bench-qjs.js`): DOM and render
  times for building and updating 1000 / 3000 rows;
- the render bench on the desktop (one visible run per version);
- memory (PSS after the tests): no worse than linkedom's;
- tests: `npm test` (React, inputs, html, observer, render…), `zig build test
  -Dnative_ui`, the showcase and canvas demo screenshots unchanged, GhostPen
  usable; on Windows, macOS and Android through the peer sessions.

Target at the end: building 1000 rows within 1.5× the WebView (~30 ms), updates
at least as fast as today, memory and startup leads kept.

## Design

### The document store (Zig)

One store per window (per `Engine`), owned by Zig:

- **Nodes**: a pool of fixed-size records addressed by a `u32` index with a
  generation (stale handles detectable). Fields: kind (element, text, comment,
  fragment, document), tag (an interned name id), parent, first child, last
  child, previous and next sibling (indexes), a small inline attribute array
  (spilling to a heap array), text (owned bytes for text and comments), flags
  (connected, dirty bits for the renderer), the JS wrapper (see below).
- **Names**: tag and attribute names interned once (ids), so comparisons and
  selector matching are integer compares.
- **Attributes**: (name id, value bytes); `class` also kept split into token ids
  for selector matching and `classList`.
- **Mutation log**: every change appends a compact record (kind, node,
  attribute name, old value when asked). The renderer reads its dirty marks
  straight from the store (no JavaScript observer); page `MutationObserver`s
  get records built from the log when they ask.

Children lists are linked (prev/next), like linkedom's but without its
interleaved attribute and end markers, so insert and remove are O(1).

### Memory and copying

The store must not copy or allocate per operation where it can avoid it:

- **No allocation per node.** Nodes are records in a pool (slabs of fixed-size
  records, a free list for reuse), addressed by `u32` index + generation, not
  pointers: no malloc/free per node, stable handles when the pool grows, and
  tree walks touch small adjacent records.
- **Strings aren't copied into Zig.** Text and attribute values are kept as
  the QuickJS strings the page gave (a `JSValue`, one reference count
  increment): `el.className = s`, `t.data = s` and `getAttribute` hand the same
  string back and forth without conversion. Bytes are made only where native
  code needs them (the renderer's text, once, cached until the text changes).
- **Names are QuickJS atoms.** Tag names, attribute names and class tokens are
  `JSAtom`s (interned by QuickJS already): comparing, hashing and selector
  matching are integer operations, and `el.localName` returns the atom's string
  without building one.
- **Attributes inline.** A few (name atom, value) pairs inside the node record,
  spilling to a pooled array only for elements with many.
- **Children are linked, collections are views.** Insert and remove relink
  indexes in O(1); `children` and `childNodes` are live views read on access,
  not arrays kept in sync.
- **The mutation log is a ring of fixed records**, reused, read in place by the
  renderer.
- **innerHTML** converts the markup to bytes once (the only copy), parses it in
  place and creates text and attribute values as QuickJS strings directly
  (slices of the input, no intermediate buffers).
- **No JSON between the store and the renderer** once the flattener is native
  (phase 3): props go from the store into `tree.zig`'s nodes directly.

Ownership is explicit: the store owns node records and holds one reference to
each string value and wrapper it keeps; freeing a node releases exactly those.
Every Zig change gets the usual review (leaks, use after free, ownership,
reference counts) and allocation-failure tests.

### JavaScript bindings (QuickJS, C/Zig)

- Each node gets at most one wrapper object (identity: `a.firstChild ===
  a.firstChild`), a QuickJS class instance holding the node handle, created
  when JavaScript first sees the node. Prototypes per interface (`Node`,
  `Element`, `HTMLElement`, `HTMLDivElement`…), so `instanceof` and React's
  checks work.
- The hot API is native (C functions and getters): `createElement`,
  `createTextNode`, `append`/`appendChild`/`insertBefore`/`removeChild`/
  `remove`/`replaceChildren`, `parentNode`, `firstChild`, `lastChild`,
  `nextSibling`, `previousSibling`, `children`, `childNodes`, `nodeType`,
  `localName`/`tagName`, `id`, `className`, `classList`, `get/set/has/
  removeAttribute`, `textContent`, `innerHTML`/`outerHTML` (a Zig HTML parser
  and serializer), `cloneNode`, `isConnected`, `contains`, `querySelector(All)`/
  `matches`/`closest` (a Zig selector engine, shared with the style phase).
- The long tail stays JavaScript, written on top of the native primitives:
  events (`EventTarget`, dispatch, bubbling), `MutationObserver` (over the
  mutation log), `style` (`CSSStyleDeclaration` over the `style` attribute),
  `dataset`, form fields' `value`/`checked`, `Range`, `TreeWalker`… Most of it
  can come from linkedom's own code, adapted.
- Expandos (`el.__reactFiber$…`, the renderer's own fields) live on the
  wrapper, so the wrapper must live as long as its node can be reached from
  the page: the store keeps a strong reference to the wrapper while the node is
  connected or has expandos, and a detached node without expandos is owned by
  its wrapper (freed in the wrapper's finalizer). (Open question below.)

### The renderer

Phase by phase, the renderer reads more from the store directly:

1. `render.js` unchanged, reading the tree through the native accessors (faster
   than linkedom's getters), and taking dirty marks from the store.
2. The style engine in Zig: rules parsed once, selectors compiled to match on
   name ids, matched rules and computed styles cached per node in the store
   (the sharing `render.js` already does). `render.js` asks the store for a
   node's computed values.
3. The flattener in Zig: the store produces `tree.zig`'s nodes and props
   directly, without the JSON ops; JavaScript only runs the page.

## Phases

| phase | what | gate |
|---|---|---|
| 0 | Prototype: the store and the hot bindings (createElement, className/setAttribute, append, textContent, innerHTML for plain markup, tree getters, getAttribute), in the QuickJS harness only | building 1000 rows' DOM ≥ 3× faster than linkedom (harness) |
| 1 | Drop-in DOM: the rest of the API linkedom gives our tests, pages and React; dirty marks from the store; linkedom kept behind a build option until the gate | all tests pass; DOM part ≥ 3× faster; render bench build/update faster; memory no worse |
| 2 | Style engine in Zig | render time for building rows ≥ 2× faster; same screenshots |
| 3 | Flattener in Zig, no JSON ops | build 1000 rows ≤ ~30 ms on the desktop, updates ≤ today's |

Phase 0 decides whether the rest is worth it: if a native DOM isn't clearly
faster through QuickJS's C calls, we stop there.

**Status (2026-10-02):** phases 0 and 1 are in. With `-Dnative_ui` the native
DOM is the default; `-Dnative_dom=false` builds on linkedom. On the desktop
the render bench builds 1000 rows in 39.7 ms (linkedom: 84.5 ms) and updates
them in 5.6 ms (9.8 ms), and memory after two rounds stays at 127 MB (152 MB).
Linux is verified (tests, showcase, GhostPen, the bench); Windows, macOS/iOS
and Android are next.

**Phase 3, step one: rows stamped from the DOM (2026-10-02).** Profiling
showed styles weren't the cost for rows (style() and matching ~3% of the
JavaScript time building them, thanks to style sharing): the flattener and
emit were (~60%), per child: an id, map entries, a node object, a leaf call
and its bookkeeping. So phase 2 waits and the flattener's commonest case went
native first:

- Node ids of DOM nodes are `2^30 +` the store index (`idOf`, `elementFor`
  through `__nuiDom.index`/`nodeAt`), so the tree can name an element's node
  without asking JavaScript.
- A flex row of simple leaves (render.js's row shapes: ordinary tags, class
  and style attributes only, each child empty or one text node, no listeners
  or labels) registers a plan once (`host.stampPlan`: each child's leaf
  styles, its text-transform, the CSS order). Its node is emitted as usual,
  with no children; after the ops, `host.stamp(row id, row, plan)` has the
  tree read the children from the store (`dom_stamp.zig`: text with
  whitespace collapsed as the runtime does) and make, keep or update their
  leaves (`Tree.stampRow`). The row owns them: they go with it, or when the
  page's ops set its children.
- A text change inside a stamped row stamps it again (updateText): leaves
  whose text is unchanged stay, the row isn't re-attached.
- Not on Android (no leaf bridge: its backend mirrors each node's props).

Render bench on the desktop: build 1000 rows 40 -> 25 ms, 3000 rows 120 ->
77 ms, update 1000 5.4 -> 3.6 ms, memory after the tests 192 -> 174 MB.
A stamped and an unstamped page make the same tree (a differential page:
text, order, transforms, empty and filled children, removals, and the rows
that must take the general path).

## Risks and open questions

- **API surface.** Pages and React use far more DOM than the hot path. Mitigation:
  a differential test that runs the same scripts against linkedom and the
  native DOM and compares the serialized tree and the observed values; React's
  tests already in `npm test`.
- **Wrapper lifetime and expandos.** Keeping wrappers alive while nodes are
  connected costs memory per node (one small object, which linkedom spends
  anyway: its nodes *are* JS objects). Needs care with QuickJS's cycle
  collector (a wrapper reachable from a connected node must not be collected).
- **Selector coverage.** The style engine and `querySelector` need the selectors
  `css.js` supports today (and linkedom's, for `querySelector`).
- **Platforms.** All Zig and C, so it builds wherever the engine does; each
  backend's tests run through the peer sessions.
- **Maintenance.** We own a DOM. linkedom stays available behind a build option
  until phase 1 passes everywhere.
