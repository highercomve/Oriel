# Native renderer performance: findings and next changes

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
animations and other unsupported cases. Android keeps the JSON operations
because its native views mirror those properties.

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
  to JSON. Text strings remain individually owned. Android retains JSON.
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
