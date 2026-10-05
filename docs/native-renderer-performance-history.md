# Native renderer performance: experiment history

[Current performance summary](native-renderer-performance.md) · [Documentation](README.md)

These notes record dated investigations, primarily the 2026-10-02 LinkeDOM
optimization passes. Statements about the current renderer and proposed next
steps describe the implementation at the time of each experiment. Their
baselines precede the native DOM, stamping, and later rendering changes; use
the current summary for headline figures and measurement conditions.

## Current priorities after callback tuning, 2026-10-04

The typed QuickJS dispatch pass reduced isolated callback overhead but did
not establish an end-to-end win in render-bench or the 500-ball JS game.
On a diagnostic 12-second desktop Breakout run, native painting had a
2.68 ms median, the page call 1.79 ms, and layout 0.02 ms. Profiling adds
overhead, game states are unseeded, and stage medians must not be added as
one representative frame. They identify where to investigate next.

Android now retains requested display frames while hidden or detached,
removes the posted Choreographer callback, and resumes it on visibility
or reattachment. Render-bench on the Android 35 x86_64 emulator advanced
its trace counter by 480 during eight hidden seconds before the change,
and zero after it; both resumed drawing. Timers and services retain their
existing behavior. This establishes eliminated background frame work,
not a whole-device energy reduction.

Next experiments, each requiring a new before/after comparison:

1. **Canvas recording and command storage.** Profile recorder writes,
   native decoding and Android unpacking separately. The Android hardware
   path already draws directly to the GPU; adding hardware acceleration
   again would not help. It still creates a `CvOp` object per command and
   a new `Replay` with paths, matrices, paints and arrays for each replay.
   Reusable bounded command storage and replay state could reduce GC and
   per-frame allocation. A native recorder for hot 2d methods could also
   replace interpreted numeric-buffer writes, while retaining normal
   canvas semantics and the JavaScript implementation as fallback.
2. **Retained painting and batched shapes.** GTK replays each canvas
   program even when an unrelated page edit caused the repaint, and its
   circle-mask fast path covers only a lone circle. Breakout groups 16
   circles in each path. Measure retained raster/display-list caching and
   a batch fast path with correct overlap, alpha, clipping and fill rules.
   Android's existing circle batching is a useful comparison. Reuse static
   content without changing canvas persistence or transparent compositing.
3. **Explicit lazy lists.** Large feeds need a model-backed visible-row
   list with reuse (RecyclerView or equivalent), rather than allocating
   and laying out every row. Preserve the full-DOM benchmark and its
   synchronous geometry guarantees; this is an additional application API,
   not an invisible replacement for ordinary HTML lists.

[Full desktop comparison](../examples/render-bench/results/2026-10-04-native-dispatch-desktop.json),
[background scheduling checks and diagnostic stage timings](../examples/render-bench/results/2026-10-04-android-background-frames.json).

The target is to beat the WebView on the same page, including synchronous
layout reads. Being native does not by itself achieve that: Oriel currently
runs its DOM, CSS matching, flattening and diff in interpreted JavaScript
before it reaches Yoga and platform text measurement.

## Changes implemented in this checkout

Text-only mutations of existing text leaves now avoid walking their row,
siblings and ancestors in JavaScript. A direct `host.text(id, string)` bridge
changes a single native text run without encoding or parsing its entire
property object or resetting unchanged Yoga styles. It retains font and box
properties, invalidates platform measurement caches, and dirties Yoga for
the subsequent synchronous layout read. General rendering handles empty
content, structural selectors, mixed inline content, styles, transitions,
animations and other unsupported cases. Android uses it too: its backend
forwards the new run to NuiView, which keeps the node's paint and rebuilds
only the styled text (update 1000 rows there: 78 -> 37-44 ms).

The renderer's document observer now ignores detached DOM construction;
attaching the finished subtree marks the insertion and computes its
styles. Its private observer now marks connected mutations directly, without
allocating queued records or per-record added/removed arrays. Synchronous
layout reads see those marks immediately. Page-created observers retain their
queued records and original behavior. The observer changes live directly in the owned LinkeDOM source under
`src/native_ui/js/vendor/linkedom`, together with its upstream license and
version metadata. Runtime code and tests import that source; the build never
patches npm packages. Any other dependency we modify must also be vendored
before applying the change. Style mutation
hooks also avoid notifying the renderer for detached elements.

Earlier improvements replace allocating child/attribute collections with
linked traversal, trim runs in place, and omit Yoga's column/stretch defaults
from JSON. Computed style sharing and derived box-property caches already
existed; adding them again would not improve this implementation.

The second pass adds these build and update improvements:

- Repeated small HTML fragments reuse a bounded syntax template while
  allocating fresh DOM nodes. Markup changes, invalid input and custom
  elements keep the general parser.
- Ordinary text leaves skip the general flow builder. New simple flex rows
  reuse frame-local child style/layout setup, keyed by selector ancestry and
  child structure. Structural selectors, pseudo-elements, nested content,
  positioning and animation retain the general path.
- New text and view nodes reference immutable native style records through
  typed host calls. Containers attach children through the usual operation.
  Style storage is bounded; unsupported nodes and declined calls fall back
  to JSON. Text strings remain individually owned. Android uses them too:
  each leaf style reaches Kotlin once, and the nodes made from it as compact
  records in one batch per change (Tree.on_leaf_style, Tree.on_create).
- GTK shares text measurements across nodes, using full bounded keys and
  invalidating on Pango context pointer/serial changes. Natural text sizes
  live directly on nodes, eliminating repeated hash-table lookups. Large
  removals compact the native node table to remove hash-table tombstones.
- Single-run updates reuse font metadata and normalize text without the
  general run builder. Layout and measurement invalidation remain intact.

The GTK cache follows Pango's context change serial rather than assuming
font metrics stay unchanged.
[Pango context serial](https://docs.gtk.org/Pango/method.Context.get_serial.html).

The third pass reduces work still left inside those fast paths. HTML templates
clone private shallow element/attribute prototypes, so each assignment keeps
fresh nodes without reapplying identical attributes. Template storage remains
bounded and document-specific; custom tags and `is` attributes stay general.
A fixed ancestor walk replaces CSS selector compilation for the SVG/MathML
eligibility check on every `innerHTML` assignment. New flex leaves reuse their
encoded native style template, and eligible text updates reuse owned run
objects only after every affected leaf has validated.

Each native immutable style now also owns a prepared Yoga style node. New
nodes copy its style once rather than repeating dozens of setters. Children,
measurement callbacks, contexts and layout stay independent. Tests compare
copied-style layout with the JSON property path and verify that updating one
node does not change another's style.
[Yoga 3.2.1 style-copy implementation](https://github.com/facebook/yoga/blob/v3.2.1/yoga/YGNodeStyle.cpp#L34).

The fourth pass removes quadratic child clearing in native list replacement:
one bulk Yoga detach replaces repeated removals from the beginning of its
child vector. Native child storage reserves capacity before changing ownership.
Tests cover ordering, moving nodes between parents, emptying a list, and
destroying a parent while retaining its detached children.

GTK can also retain frames after a text edit when natural width and height
are exactly unchanged, the font-context epoch matches, and the text is
unwrapped at its current content width (or explicitly `nowrap`). It still
invalidates Yoga's measurement cache for future resizing, and independently
marks painting dirty. Wrapped text, changed metrics, changed contexts and
other backends continue through layout. Tests check changed word breaks
after a narrow resize, wrapped-text updates and font-context invalidation.
Simple new flex leaves also normalize a single text node directly rather
than allocating a general run flow.

The tests compare incremental native operations against independently
rebuilt trees, exercise both direct and JSON text updates, check observer
insertion/removal behavior in the actual runtime bundle, and check owned
native text allocations with Zig's testing allocator. Linux is measured;
Apple and Windows need platform benchmark verification.

## What the controlled measurements establish

The latest comparison runs one visible ReleaseFast process for the previous
native runtime, the updated native runtime and WebView, serially. All use
the unchanged benchmark page, synchronous layout reads, identical 900 × 700
floating windows, and medians of three trials from the second round.

| Step | Native before this pass | Current native | Fresh WebView |
|---|---:|---:|---:|
| Build 1,000 rows | 127.15 ms | 122.37 ms | 21 ms |
| Build 3,000 rows | 352.95 ms | 327.05 ms | 68 ms |
| Update 1,000 rows | 16.36 ms | 10.85 ms | 10 ms |
| Update 3,000 rows | 50.93 ms | 34.78 ms | 41 ms |

Native updates improve 32–34% this pass; builds improve 4–7%. The native
3,000-row update is about 15% faster than the fresh WebView result; 1,000-row
updates are close. Builds still trail WebView substantially. These
single-process runs do not establish confidence intervals.

Native startup to first frame is 204 ms versus WebView's 486 ms. Native PSS
after the second round is 216 MB versus 335 MB; animation/canvas remain
about 60 fps native and 62 fps WebView. Across all passes, compared with
`e5f1a2a` (242.54/815.57 ms builds, 93.43/305.35 ms updates), reductions are
50–60% for builds and 88–89% for updates.
[Latest full comparison and individual trials](../examples/render-bench/results/2026-10-02-rows-phase4-desktop.json),
[preceding pass](../examples/render-bench/results/2026-10-02-rows-phase3-desktop.json),
[original comparison](../examples/render-bench/results/2026-10-02-rows-desktop.json).

Three serial paired QuickJS processes, two trials per step per process,
isolate the preceding pass's JavaScript changes. The fake host excludes native apply,
layout and paint; values are medians of six measurements.

| Step | DOM before → after | JS render before → after |
|---|---:|---:|
| Build 1,000 rows | 74.10 → 48.95 ms | 144.60 → 132.55 ms |
| Build 3,000 rows | 239.75 → 144.45 ms | 336.15 → 313.45 ms |
| Update 1,000 rows | 7.60 → 6.15 ms | 6.25 → 5.45 ms |
| Update 3,000 rows | 25.80 → 22.05 ms | 21.75 → 20.25 ms |

DOM build CPU drops 34–40%; JavaScript rendering drops 7–8% for builds and
7–13% for updates. Wire traffic is unchanged by this pass. The previous pass
had already reduced build traffic 86–88%. Even the new 49 ms construction time
for 1,000 rows exceeds WebView's entire 20 ms build time, so the remaining gap
requires more than bridge tuning.
[Latest isolated results](../examples/render-bench/results/2026-10-02-rows-phase3-qjs.json),
[shared-style pass](../examples/render-bench/results/2026-10-02-rows-phase2-qjs.json),
[first-pass isolated results](../examples/render-bench/results/2026-10-02-rows-qjs.json).

Earlier profiling found repeated native text-cache lookups and node-map
fragmentation after bulk removal. The shared measurement cache did not reach
its capacity (about 15,000 entries, 1 MB of keys); raising its limit would not
have fixed that cost. Per-node natural sizes and node-map compaction address
the measured problem instead. Profiling adds overhead; its timings are
diagnostic rather than directly comparable with ReleaseFast measurements.

## Ways to close the remaining gap, in priority order

1. **Batch the remaining bridge calls and extend precise native updates.**
   Shared immutable styles and typed creation are now implemented for
   ordinary views and single-run text. Repeated style objects no longer
   cross the bridge for each new row. Bulk creation could further reduce
   per-node calls; partial property updates could avoid resetting unchanged
   Yoga fields. Compare full-path CPU and memory before expanding this.
   Preserve reset semantics and platform mirrored props. React Native's
   architecture identifies serialization as a bottleneck and uses direct
   native interfaces; that is evidence for the approach, not a promised
   speedup for Oriel. [React Native architecture](https://reactnative.dev/blog/2024/10/23/the-new-architecture-is-here).

2. **Move DOM construction and the hottest rendering loops into native
   code.** Even the optimized fake-DOM construction alone takes about 49 ms
   for 1,000 rows. The desktop WebView measurement for construction *and
   layout* is 20 ms, so removing JSON alone cannot close that gap.
   Introduce native-owned node storage and a JavaScript DOM facade gradually,
   beginning with create/append/text/attribute operations and a bulk subtree
   path. Keep the existing parser and selector machinery for unsupported
   operations while validating React DOM, events, mutation observation,
   inherited styles, reparenting and layout reads. Native node ownership
   needs explicit QuickJS lifetime and cycle handling; this is a renderer
   change, not simply a new JavaScript engine flag. React Native also keeps
   its renderer and layout tree in shared C++ code.
   [Rendering pipeline](https://reactnative.dev/architecture/render-pipeline).

3. **Carry precise dirtiness through layout and placement.** Yoga already
   avoids recalculating clean subtrees. The direct text path uses this by
   preserving styles and marking only measured text dirty. General property
   updates should distinguish layout, measurement and paint changes, apply
   changed Yoga fields only, and reuse native frame/clip state where ancestor
   geometry allows it. Profile the post-Yoga placement walk separately;
   changing a row's height can legitimately move following rows, so skipping
   those frame updates blindly would be incorrect.
   [Yoga incremental layout](https://www.yogalayout.dev/docs/advanced/incremental-layout).

4. **Retain paint work and reduce native node overhead where semantics
   permit.** Oriel already flattens inline text and omits drawing widgets for
   plain layout boxes. Additional layout-node removal needs tests for flex
   sizing, padding, clipping, hit testing and inherited transforms. Retained
   display lists and batched drawing can help canvas/animation workloads;
   they will not fix the row benchmark's forced-layout time because that
   measurement ends before painting.
   [React Native view flattening](https://reactnative.dev/architecture/view-flattening),
   [Qt retained scene graph](https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph.html).

5. **Offer explicit containment/virtualized lists for large visible UIs.**
   Offscreen layout and painting can be skipped with appropriate containment
   and intrinsic-size contracts; arbitrary CSS does not make that safe.
   Preserve scroll extent, accessibility, focus and synchronous measurements.
   Test equivalent opt-in behavior on both renderers, rather than changing
   the native benchmark to do less work than its WebView counterpart.
   [CSS content visibility](https://web.dev/articles/content-visibility).

GC threshold tuning is lower priority. QuickJS uses reference counting plus
cycle collection, so delaying cycle collection does not remove the normal
allocation and reference-counting cost of building the DOM. Check GC time
and retained memory before increasing thresholds.
[QuickJS internals](https://quickjs-ng.github.io/quickjs/developer-guide/internals/).

## Acceptance criteria

Use the unchanged render-bench page on both renderers, ReleaseFast, identical
window geometry and synchronous `offsetHeight` flushing. Record startup,
build/update medians, frame rates and memory after both rounds; separate DOM,
JS rendering, native apply, text measurement and layout when profiling.
Commit `18a2a86` changed native layout reads to flush rendering: earlier native
DOM-only timings are not valid comparison baselines. Accept an architectural
change only after correctness checks and an actual full-path improvement;
the WebView advantage on rows remains the benchmark to beat.

## DOM allocation and flattening pass

LinkeDOM listener storage is now lazy: DOM nodes without listeners allocate no
listener Map. The renderer stores primary native IDs as numbers, expands them
only for auxiliary nodes, shares immutable empty child arrays and simple leaf
snapshots, and uses one computed-style cache with epoch invalidation. Tests
cover listener allocation, event semantics, auxiliary IDs, hidden-node styles,
and full restyles. The vendored fork and all unmodified npm dependencies are
reproducible from the tracked sources and lockfile.

The visible phase-5 native pair measured builds of 1,000/3,000 rows at
256.08 → 201.72 ms / 756.52 → 641.84 ms, and updates at
26.70 → 23.80 ms / 80.59 → 72.68 ms. Unrelated background compilation
was active throughout this pair, so these differences are indicative and
include scheduling noise; the absolute times must not be compared with the
earlier WebView measurements. Both versions used the same 900×700 window
and unchanged benchmark page, with second-round medians of three trials.
Full reports are in
`examples/render-bench/results/2026-10-02-rows-phase5-desktop.json`.

After rebasing onto review fixes in `9f21bb9`, a fresh comparison used reviewed
main as baseline and `780f945` as current. Both native binaries were built before
timing, and measurements waited for Yocto and compiler activity to settle.
Builds of 1,000/3,000 rows improved 125.66 → 106.33 ms /
340.51 → 304.82 ms; updates improved 11.77 → 10.69 ms /
39.00 → 33.44 ms. Fresh WebView measured 19/72 ms for builds and 10/41 ms
for updates. Native leads the larger update by about 18%, remains close for the
smaller update, and still trails builds significantly. Native second-round PSS
improved 228 → 194 MB; WebView measured 353 MB. These are medians from one
process per variant, rather than confidence intervals. This quiet run supersedes
the noisy phase-5 measurements for assessing the changes. See
`examples/render-bench/results/2026-10-02-rows-phase5-reviewed-desktop.json`.

## Further construction pass

The owned LinkeDOM now avoids a token Set for single-token className reads and
writes, while retaining normalization and exposed live classList behavior.
Ordinary div/span and document-created text nodes initialize the same fields
and prototypes directly; custom constructors and upgrades retain the general
path. Differential constructor-layout, DOM-link, observer, class and custom
element tests cover those boundaries.

Flattening caches resolved font sizes by computed style and resolved parent
size, avoiding repeated unit parsing and keyword-map allocation. Style identity
reuse also compares resolved font size: equal relative CSS strings can resolve
differently after a parent changes. Regression tests cover em/percentage sizes
and inline parent/child updates.

Final visible native comparison against a6d6e53 measured 1,000-row builds
106.75 → 91.64 ms (14%) and 3,000-row builds 300.47 → 291.27 ms (3%).
The larger-list trial ranges overlap, so that smaller difference is indicative.
The DOM-only candidate had a mixed larger-list result and remains recorded
separately. All binaries and checks completed before measurements. The page and
synchronous layout reads were unchanged; both versions used 900×700 windows
and medians of three trials in the second round.

Three serial paired QuickJS processes measured DOM builds 44.45 → 35.30 ms
and 135.40 → 106.60 ms, about 21% faster; JS rendering measured
122.00 → 119.00 ms and 258.80 → 250.70 ms. Bridge traffic is unchanged.
The factory-only ablation indicates about 3% less DOM time than class-name
allocation avoidance alone. The largest remaining cost is flattening/emission;
construction remains well behind WebView.

Reports: `2026-10-02-rows-phase6-desktop.json`,
`2026-10-02-rows-phase6-dom-only-desktop.json`,
`2026-10-02-rows-phase6-qjs.json`, and
`2026-10-02-rows-phase6-ablation.json` under `examples/render-bench/results`.

## Flattening and emission follow-up

Based on `2143d84`, including the latest main and the Apple natural-size cache
and word-minimum-width fixes. Row leaf plans now merge box/font properties once;
each leaf owns its properties and text run. Ordinary three-field font runs copy
the fields directly; decorated runs retain the general copy. Eligibility already
rules out attributes other than class/style, so only labels/listeners need
additional click checks on that path. Direct leaves share one style/flattening
cache record; later style updates replace their record. Emission uses Map.forEach
to avoid entry-pair iterator arrays, retaining the initial kind-change scan so
parents reattach remade children regardless of traversal order.

Full JavaScript and ReleaseFast native checks pass. New differential cases cover
owned runs/props, decorated fonts, labels/listeners, empty/text transitions,
disabled/onclick fallback and later inline font/style edits. Generated runtime is
rebuilt from owned sources. Shared layout code was not changed.

Three serial paired QuickJS processes (six trials per step) measured rendering
120.60 → 115.00 ms for 1,000-row builds and 243.25 → 234.90 ms for 3,000,
about 4.6% and 3.4% less. DOM time and bridge payload are essentially unchanged.
Updates show no consistent improvement.

The final visible Linux comparison is mixed:

| Step | Before `2143d84` | Updated native |
|---|---:|---:|
| Build 1,000 | 91.56 ms | 95.50 ms |
| Build 3,000 | 289.90 ms | 279.52 ms |
| Update 1,000 | 10.85 ms | 10.64 ms |
| Update 3,000 | 35.41 ms | 34.54 ms |

Each variant ran once, visibly, at 900×700, with synchronous layout reads and
second-round medians of three trials. Both binaries and checks finished before
timing; compiler/Yocto monitoring was quiet. Build trial ranges overlap
(1,000: 90.85–98.80 vs 86.59–114.20; 3,000: 280.69–293.03 vs 262.29–284.82).
This establishes reduced allocations and a modest isolated rendering gain,
**not a clear overall native construction win**. The preceding candidate also
had mixed build medians (91.72 → 94.79 and 285.53 → 275.24), and is retained.
No new WebView/macOS comparison was run; native construction remains far behind
the earlier WebView reference.

The macOS width-change proposal remains open. A changed text width can also
change its Yoga word minimum, flex distribution, ancestor sizing or scroll
extent. A future shortcut must prove those dependencies unchanged and preserve
Yoga measurement invalidation and consistent frame/clip state after later
layout or scrolling. The reported 37 ms macOS vs 12 ms Linux update is peer
information, not a measurement made by this pass.

Reports: `2026-10-02-rows-phase7-desktop.json`,
`2026-10-02-rows-phase7-first-desktop.json`, and
`2026-10-02-rows-phase7-qjs.json` under `examples/render-bench/results`.

## Hermes and native list investigation

The last allocation pass did not establish an overall native build win. This
investigation changes the priority: **measure an alternative JS engine before
spending more time on small copies or undertaking a complete native DOM rewrite**.
This is a workload-specific conclusion from a new experiment, not a claim that
one engine always wins.

The same c860083 bundle, owned LinkeDOM, CSS, row algorithm and fake host ran under
QuickJS-ng 0.17.0 (CLI Release, -O3), Node 24.16.0/V8, and V8 with JIT disabled.
Three serial rounds, two trials each, yielded these medians:

| Build | QuickJS DOM / render | V8 DOM / render | V8 --jitless DOM / render |
|---|---:|---:|---:|
| 1,000 | 36.05 / 115.30 ms | 10.80 / 13.25 ms | 20.20 / 21.80 ms |
| 3,000 | 108.25 / 237.75 ms | 14.55 / 34.95 ms | 59.60 / 72.45 ms |

The Node adapter imports the existing harness and changes only file loading,
CLI/output globals and incompatible Node Event/microtask globals. Separate
untimed verification compared every ops/style/leaf/text call and argument:
all 24 step transcripts are exactly equal. Payload sizes match. V8 row-build
rendering is roughly 7–9 times faster in this isolation; even --jitless is
roughly 3–5 times faster. Engine internals matter beyond the presence of JIT.
These numbers exclude source parsing/boot and **native apply, layout and paint**.
They are not estimates for integrated native timings; the standalone QuickJS
harness also differs from the embedded app. This first experiment did not time
Hermes; the subsequent engine comparison below does.
[Raw observations and trace validation](../examples/render-bench/results/2026-10-02-rows-engine-investigation.json).
Reproduce with `test/bench-qjs.js` or `test/bench-node.mjs`; add `node --jitless`
for the third configuration.

### What other implementations actually do

- **Hermes:** its original ahead-of-time bytecode compilation removed runtime
  source parsing and emphasized startup/memory. That alone does not remove row
  allocations during a warm build. Newer static_h work supports native AOT and
  baseline JIT alongside interpreted bytecode; current development notes also
  describe faster object access and contiguous Map/Set backing storage with less
  GC overhead. Evaluate a pinned build/mode instead of assuming all Hermes
  configurations have the same behavior. [Original design](https://engineering.fb.com/2019/07/12/android/hermes/),
  [compilation/runtime modes](https://github.com/facebook/hermes/blob/static_h/doc/blog/2025-11-02-hermes-compilation-runtime-modes.md),
  [June 2026 development release notes](https://github.com/facebook/hermes/blob/static_h/doc/blog/2026-06-05-new-hermes-stable-release.md).
- **React Native/Fabric:** JavaScript creates native shadow nodes through direct
  interfaces; rendering does not require Oriel-style HTML parsing, DOM allocation,
  CSS matching and JS flattening first. Shadow-tree diffing/host-view flattening
  are C++ work. Native view flattening removes host views, not all logical/layout
  nodes or their layout cost. Our typed leaf/style calls already adopt part of
  this approach. [Pipeline](https://reactnative.dev/architecture/render-pipeline),
  [flattening](https://reactnative.dev/architecture/view-flattening),
  [createNode/appendChild bindings](https://github.com/facebook/react-native/blob/main/packages/react-native/ReactCommon/react/renderer/uimanager/UIManagerBinding.cpp).
- **FlashList, Qt Quick and Flutter lists:** create the visible portion, recycle
  delegates/cells or build children lazily. FlashList v2 progressively measures
  and corrects predicted geometry before paint. Qt explicitly pools delegates;
  Flutter recommends lazy list builders. This is a major reduction in work,
  but does not demonstrate faster construction of all N rows. Reusing native
  allocations alone also does not eliminate our JS DOM construction.
  [FlashList v2](https://shopify.engineering/flashlist-v2),
  [Qt ListView reuse](https://doc.qt.io/qt-6/qml-qtquick-listview.html),
  [Flutter list/layout guidance](https://docs.flutter.dev/perf/best-practices).
- **Flutter layout:** explicit constraints and dependency information let it
  stop layout propagation where parents do not depend on a changed child size,
  or where tight constraints make the outer size invariant. This is a concrete
  model for the open macOS width-change shortcut, though CSS flex/intrinsic/
  scrolling dependencies require our own correctness proof.
  [Inside Flutter](https://docs.flutter.dev/resources/inside-flutter).

### Concrete next experiments

1. Add an isolated alternative-engine backend behind the existing host contract.
   Test a pinned Hermes build with JIT/AOT modes or a platform-appropriate JIT
   engine using the same DOM/runtime first. Require the full JS behavior suite,
   synchronous geometry semantics, full native timings, startup, footprint and
   target-platform builds before choosing an engine. This preserves page APIs
   and directly targets the newly measured execution gap.
2. Keep bulk typed subtree construction/native templates as a separate experiment:
   instantiate a repeated structure from native styles and text slots, with
   bounded storage, fresh DOM identities and correct fallback. Native template
   expansion must eliminate per-node JS bookkeeping/host crossings to improve
   on our existing cached styles; adding another cache is insufficient.
3. Offer an explicit model-backed native list for large application feeds, with
   lazy rows and reuse, while retaining the current full-N benchmark as a
   separate test. Generic DOM virtualization cannot silently substitute estimated
   extents for synchronous CSS geometry reads.
4. Carry child-size dependencies through layout for the macOS width shortcut;
   keep this independent of construction/engine changes and test other backends.

### Alternative engines tested, 2026-10-02

Built all engines before measuring, waited for three quiet samples ten seconds
apart with no compiler/Yocto workers, then ran three serial rounds with rotated
engine order. Each row label has six observations. The new packaging script
inlines the **unchanged runtime** and assets from the existing fake-host harness,
allowing Hermes native AOT to compile the runtime rather than executing it via
eval. These are fresh comparisons within this experiment; do not mix their
absolute timings with the earlier eval-based experiment.

Medians, **DOM / JS render** (style, flatten, emission), in milliseconds:

| Engine / mode | Build 1,000 rows | Build 3,000 rows | Update 3,000 rows |
|---|---:|---:|---:|
| QuickJS-ng 0.17.0, Release | 37.30 / 113.90 | 116.40 / 232.30 | 17.80 / 18.55 |
| JavaScriptCore 2.52.6 | 7.05 / 13.15 | 9.95 / 22.80 | 2.10 / 1.80 |
| V8, Node 24.16.0 | 11.35 / 13.50 | 14.25 / 31.65 | 1.25 / 2.00 |
| Hermes bytecode interpreter | 23.50 / 22.00 | 70.50 / 66.50 | 10.00 / 9.50 |
| Hermes native AOT | 21.50 / 20.50 | 62.50 / 61.50 | 9.50 / 11.50 |
| zjs, Zig ReleaseFast | 60.55 / 61.20 | 211.00 / 194.65 | 27.90 / 14.10 |
| Kiesel, Zig ReleaseFast | 176.50 / 153.00 | 552.00 / 480.00 | 78.50 / 47.50 |
| V8 --jitless | 21.05 / 19.05 | 61.35 / 71.10 | 7.10 / 5.60 |
| JavaScriptCore --useJIT=false | 31.65 / 24.35 | 94.00 / 71.55 | 14.60 / 8.85 |

JavaScriptCore's sum of construction/render medians is 32.75 ms versus QuickJS's
348.70 ms for 3,000 rows, about 10.6 times faster in this isolation. V8 is about
7.6 times faster; Hermes native AOT about 2.8 times faster. Neither Zig-written
engine improves total row building versus QuickJS on this workload. These are
**not native desktop timings**: source parsing/boot, native bridge application,
layout, text measurement, painting, memory and startup remain unmeasured.
The sample is small and the fixture runs 1,000-row steps before 3,000-row steps,
so engine tiering/warm-up affects the larger-row observations.

Verification runs separately from timing. All nine modes match QuickJS's exact
ops/style/leaf/text calls and arguments across the first twelve row steps.
QuickJS, V8, JavaScriptCore, zjs and Kiesel match all 24 steps in the final check.
Hermes differs at canvas steps 16–23: canvas width becomes 400 instead of 600.
This minimal for-of destructuring/closure reproduction prints
`height:150 height:150` in the pinned Hermes revision under both `-O` and `-O0`,
where JavaScriptCore prints `width:300 height:150`:

```js
const p = {};
for (const [name, def] of [["width", 300], ["height", 150]]) {
  Object.defineProperty(p, name, { get() { return name + ":" + def; } });
}
print(p.width, p.height);
```

This is the same pattern used by `canvas.install`. Hermes therefore is not a
compatible replacement yet, despite correct row output. Kiesel also failed an
initial trace smoke entering canvas with `TypeError: Cannot convert undefined
to Object`; after normalizing CLI globals, its final trace and three timing
rounds completed. That does not establish production stability. The packaging
clears native Event/microtask globals and `navigator` before boot; QuickJS's CLI
has a configurable, read-only navigator incompatible with the runtime assignment.

Hermes is pinned to `6e2181b288b0306d8bd1988d38d32aa879b745d5` on static_h,
Release (-O3), Hades GC, HEAP_HV_PREFER32. Bytecode uses `hermesc -O`;
native AOT uses `shermes -O -enable-eval -script` and its shared runtime.
Hermes and Kiesel use Date.now's integer milliseconds; small update/no-op
measurements have correspondingly limited resolution. The other CLIs expose
performance.now. Hermes's automatic JIT configuration in this revision enables
it only on ARM64. Forcing JIT on x86-64 fails because the backend header is absent;
neither Hermes result here is a JIT result.
[Pinned JIT configuration](https://github.com/facebook/hermes/blob/6e2181b288b0306d8bd1988d38d32aa879b745d5/include/hermes/VM/JIT/Config.h).

#### Engines written in Zig

- [Kiesel](https://codeberg.org/kiesel-js/kiesel), pinned
  `caeb23e4500fc35099b5945b20efe9bd4ece1e4b`: custom bytecode VM written in Zig,
  using BDWGC and libregexp. Built with Zig 0.16.0, ReleaseFast, Intl/Temporal
  disabled. It runs this fixture but is substantially slower.
- [zjs](https://github.com/aneryu/zjs): Zig-native embedding API and CLI,
  non-moving tracing collector, targets trusted in-process execution;
  [limitations](https://github.com/aneryu/zjs/blob/main/LIMITATIONS.md).
  Built unchanged with Zig 0.16.0, ReleaseFast defaults. Exact pinned revision
  and raw observations are in the report. Row rendering is faster than QuickJS,
  but DOM construction is slower and total building loses.
- [zig-js](https://github.com/zig-utils/zig-js): pure Zig engine with a
  JavaScriptCore-shaped C API; APIs are pre-stabilization. Requires Zig
  0.17.0-dev and sibling zig-gc/zig-regex packages, so it was investigated but
  not built/tested in this Zig 0.16 project. Its published benchmark claims
  are not measurements of Oriel's workload.
- [Lightpanda's Zig runtime integration](https://github.com/lightpanda-io/zig-js-runtime)
  uses V8; [Bun](https://bun.com/docs/project/license) uses JavaScriptCore.
  A runtime written in Zig does not imply its JavaScript engine is Zig-written.

The measured next candidate is an optional **JavaScriptCore native backend**
under the existing host contract. Linux has the JavaScriptCoreGTK C API installed;
macOS supplies JavaScriptCore. Windows/build distribution, synchronous geometry,
callback/lifetime/exception handling, behavior tests, startup, footprint and
complete native desktop timings must be checked before selecting it. V8 remains
a strong candidate, especially where JSC deployment is impractical. Keep
QuickJS available while evaluating; no production engine changed in this pass.

[Raw samples, pinned builds, fixture hashes and transcript checks](../examples/render-bench/results/2026-10-02-rows-alternative-engines.json).
[Packaging/runner reproduction](../examples/render-bench/README.md#alternative-javascript-engines).

## Canvas recording in JavaScript, 2026-10-03

The render-bench canvas test with 1000 balls (a path, a fill color and a fill
per ball, each frame) spent its JavaScript time recording and encoding the
program, not in the page's physics. QuickJS, desktop, one frame:

| | before | after |
|---|---|---|
| page physics | 0.10 ms | 0.10 ms |
| recording (canvas.js) | 2.6 ms | 1.3 ms |
| `encodeProgram` | 1.9 ms | 0 |
| render-bench rAF callback, median (in the app, `-Dnative_ui_prof`, a loaded machine) | 3.35 ms + 2.26 ms encode | 1.58 ms |

- canvas.js records straight into the program's numbers (a Float64Array that
  doubles when full, strings by index), the form host.canvas takes:
  `programOf` hands them over without an encode pass; `commandsOf` decodes
  ops for the JSON `cv` prop and tests. The hot calls (fillStyle, beginPath,
  arc, fill) write their numbers inline (each call is ~70 ns in QuickJS), a
  color string is parsed once (cached paints, compared by identity first),
  the pen after an arc is worked out only when a curve needs it, the
  buffer's capacity is a field (a typed array's `length` is a getter call),
  and the renderer is told once per batch (`notified`, reset when it reads).
- QuickJS (vendored, marked "Oriel"): `<`, `<=`, `>`, `>=`, `==`, `===` and
  their negations compare two numbers as doubles in the interpreter loop
  when one is a float (they went through `js_relational_slow` and
  ToPrimitive); `OP_put_array_el` stores a number into a Float64Array
  without calling `JS_SetPropertyValue`. Under callgrind (60 frames): 7.10G
  → 6.03G instructions for the three QuickJS-side changes together with the
  capacity field. Both keep JS's semantics (NaN, -0, conversions, detached
  and resized buffers).
- What's left is the interpreter's own cost per call and per indexed write
  (~31 ns each, an Array's too): 4 calls and ~16 numbers per ball.
