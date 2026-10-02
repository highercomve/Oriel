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
attaching the finished subtree records the insertion and computes its
styles. Page-created observers retain their original behavior. The bundled
linkedom patch checks its expected source structure at build time so a
dependency upgrade cannot silently drop the optimization. Style mutation
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

The tests compare incremental native operations against independently
rebuilt trees, exercise both direct and JSON text updates, check observer
insertion/removal behavior in the actual runtime bundle, and check owned
native text allocations with Zig's testing allocator. Linux is measured;
Apple and Windows need platform benchmark verification.

## What the controlled measurements establish

The final visible ReleaseFast run uses the unchanged benchmark page and its
synchronous layout reads, a 900 × 700 floating window, and medians of three
trials in the second round. The phase-1 baseline was run separately on the
same desktop geometry. The WebView reference is from the earlier comparison.

| Step | Start of latest pass | Final native | WebView reference |
|---|---:|---:|---:|
| Build 1,000 rows | 200.10 ms | 152.96 ms | 20 ms |
| Build 3,000 rows | 701.17 ms | 459.80 ms | 69 ms |
| Update 1,000 rows | 42.48 ms | 20.36 ms | 10 ms |
| Update 3,000 rows | 134.54 ms | 62.77 ms | 40 ms |

This pass reduced builds 24–34% and updates 52–53%. Across both passes,
compared with `e5f1a2a` (242.54/815.57 ms builds, 93.43/305.35 ms updates),
the reductions are 37–44% and 78–79%. Final native startup to first frame was
205 ms; PSS was 110 MB at start and 238 MB after the second round. Animation
and both canvas workloads remained about 60 fps. Rows still lose to WebView;
these single-process runs do not establish confidence intervals.
[Baseline reports](../examples/render-bench/results/2026-10-02-rows-phase2-desktop.json),
[final report](../examples/render-bench/results/2026-10-02-rows-final-desktop.json),
[original native/WebView comparison](../examples/render-bench/results/2026-10-02-rows-desktop.json).

Three serial paired QuickJS processes, two trials per step per process,
isolate the latest JavaScript changes. The fake host excludes native apply,
layout and paint; values are medians of six measurements.

| Step | DOM before → after | Render before → after | Payload before → after |
|---|---:|---:|---:|
| Build 1,000 rows | 76.60 → 72.55 ms | 176.10 → 144.45 ms | 667 → 82.5 KB |
| Build 3,000 rows | 234.90 → 230.15 ms | 426.15 → 334.95 ms | 2,089 → 299 KB |
| Update 1,000 rows | 7.55 → 7.45 ms | 10.20 → 6.20 ms | 17 → 17 KB |
| Update 3,000 rows | 26.30 → 25.50 ms | 37.75 → 21.60 ms | 55 → 55 KB |

The baseline includes the first pass's text bridge and detached observer
filtering. Build traffic drops 86–88%; JavaScript render CPU drops 18–21%
for builds and 39–43% for updates. DOM construction alone still exceeds the
WebView's full build time; the remaining gap requires more than bridge tuning.
[Latest isolated results](../examples/render-bench/results/2026-10-02-rows-phase2-qjs.json),
[first-pass isolated results](../examples/render-bench/results/2026-10-02-rows-qjs.json).

Profiling found repeated native text-cache lookups and node-map fragmentation
after bulk removal. The shared measurement cache did not reach its capacity
(about 15,000 entries, 1 MB of keys); raising its limit would not have fixed
that cost. Per-node natural sizes and node-map compaction address the measured
problem instead. Profiling adds overhead; its timings are diagnostic.

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
   code.** Even the optimized fake-DOM construction alone takes about 73 ms
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
