# Render bench

One static page, timed in Oriel's two renderers: the WebView (WebKitGTK on
Linux) and the experimental native renderer (`-Dnative_ui`: QuickJS, a fake
DOM, Yoga layout, GTK drawing; see `docs/native-renderer.md`).

```sh
zig build -Doptimize=ReleaseFast                                  # WebView
zig build -Dnative_ui -Doptimize=ReleaseFast -p zig-out-native    # native
./zig-out/bin/oriel-render-bench                                  # GUI
RENDER_BENCH=1 ./zig-out-native/bin/oriel-render-bench            # one JSON line, then exits
```

`RENDER_BENCH` is an environment variable because GTK rejects command-line
options it doesn't know.

## What it measures

Each test runs 3 times; the median is reported.

| Test | What |
|---|---|
| startup → page script | Process start until the page's first script runs |
| startup → first frame | … until its first `requestAnimationFrame` |
| build N rows | Create N styled rows, then force layout (`offsetHeight`) |
| update N rows | Change every row's text, then force layout |
| animate 200 boxes | `requestAnimationFrame` moving 200 boxes for 2 s: frames per second |
| canvas N balls | A `<canvas>` game loop: physics on N balls, then a full redraw (background, circles, text) each frame for 2 s: frames per second |
| memory (PSS) | Proportional memory of the app and all its child processes (a WebView page runs in WebKit's own processes) |

Times cover the DOM work and the layout it triggers, not painting, in both
renderers. The native renderer's `requestAnimationFrame` uses host timers on
a 60 Hz grid, so its frame rates cap at about 60. Its canvas is
not a bitmap: the 2d calls are replayed into Cairo each frame
(docs/native-renderer.md, "Canvas").

## Results

Linux desktop, ReleaseFast, 2026-10-02. One visible benchmark process per
version, each reporting medians of three trials, with identical floating
900 × 700 windows. Native before is `e5f1a2a`; after is the final working tree.
The WebView reference is from the earlier desktop comparison on the same page
and window geometry; it was not rerun for the final native measurement.
The same benchmark page forces rendering and layout in both renderers.

| Test | Native before | Native after | WebView |
|---|---:|---:|---:|
| startup → first frame | 236 ms | 205 ms | 522 ms |
| build 1000 rows | 243 ms | 153 ms | 20 ms |
| build 3000 rows | 816 ms | 460 ms | 69 ms |
| update 1000 rows | 93 ms | 20 ms | 10 ms |
| update 3000 rows | 305 ms | 63 ms | 40 ms |
| animate 200 boxes | 60 fps | 60 fps | 62 fps |
| canvas 200 / 1000 balls | 60 / 60 fps | 60 / 60 fps | 62 / 62 fps |
| memory at start | 108 MB | 110 MB | 291 MB |
| memory after tests / second round | 225 / 239 MB | 218 / 238 MB | 329 / 332 MB |

Across both optimization passes, native builds improved about 37–44%; text
updates improved about 78–79% versus `e5f1a2a`. This latest pass alone improved
builds 24–34% and updates 52–53% versus its phase-1 baseline (200/701 ms builds,
42/135 ms updates). Native still trails WebView on rows. These are
single-process comparisons, not confidence intervals or proof of performance
on every platform.
[Original comparison](results/2026-10-02-rows-desktop.json),
[phase-1 baseline](results/2026-10-02-rows-phase2-desktop.json),
[final native result and geometry](results/2026-10-02-rows-final-desktop.json).

The renderer now updates eligible text leaves directly, without traversing
unchanged rows or serializing full property objects. Native text updates
preserve font/layout props, invalidate measurement caches and mark Yoga
dirty. Complex cases use the general renderer; Android retains JSON ops.
The renderer observer also skips detached DOM construction and processes
the subtree when it is attached. Page observers retain their behavior.
Earlier changes avoid allocating child/attribute collections and omit
Yoga defaults from the JSON wire format.

The latest pass also reuses bounded HTML syntax templates and frame-local
setup for new simple flex rows, sends immutable styles once through typed
native creation calls, caches GTK text measurements across nodes, stores
natural sizes on nodes, and compacts native lookups after large removals.
Complex content and unsupported styles keep the general renderer.

Three serial paired QuickJS processes, with a fake host excluding native
apply/layout/paint, isolate this latest pass. Values are medians of six
measurements. The baseline already has direct text updates and detached
observer filtering:

| Step | DOM before → after | JS render before → after | Payload before → after |
|---|---:|---:|---:|
| build 1000 rows | 76.60 → 72.55 ms | 176.10 → 144.45 ms | 667 → 82.5 KB |
| build 3000 rows | 234.90 → 230.15 ms | 426.15 → 334.95 ms | 2089 → 299 KB |
| update 1000 rows | 7.55 → 7.45 ms | 10.20 → 6.20 ms | 17 → 17 KB |
| update 3000 rows | 26.30 → 25.50 ms | 37.75 → 21.60 ms | 55 → 55 KB |

Build traffic fell 86–88%; JavaScript render time fell 18–21% for builds and
39–43% for updates. These isolated times are not full native timings.
[Latest QuickJS results](results/2026-10-02-rows-phase2-qjs.json),
[earlier text/observer results](results/2026-10-02-rows-qjs.json).
Repeat the harness from the repository root with QuickJS-NG:

```sh
qjs src/native_ui/js/test/bench-qjs.js src/native_ui/runtime.js examples/render-bench/web
```

[Research and next implementation priorities](../../docs/native-renderer-performance.md)
explain the remaining build cost and approaches to closing the WebView gap.

## Historical results (before synchronous layout reads)

The native build/update times below exclude rendering and layout. Commit
`18a2a86` made `offsetHeight` and other layout reads flush pending rendering;
the earlier benchmark timed only DOM mutations. Comparing these values
with later build/update values falsely suggests a regression. Include the
render and layout flush inside the timed section on both revisions.

Linux, ReleaseFast, headless (Xvfb, software rendering), 2026-10-02, the
median of 3 runs:

| Test | WebView | Native |
|---|---|---|
| startup → page script | 388 ms | 83 ms |
| startup → first frame | 444 ms | 284 ms |
| memory at start | 342 MB | 151 MB |
| build 1000 rows | 19 ms | 112 ms |
| build 3000 rows | 71 ms | 340 ms |
| update 1000 rows | 10 ms | 9 ms |
| update 3000 rows | 42 ms | 32 ms |
| animate 200 boxes | 60 fps | 38 fps |
| canvas 200 balls | 60 fps | 47 fps |
| canvas 1000 balls | 60 fps | 33 fps |
| memory after the tests | 368 MB | 262 MB |
| memory after a second round | 369 MB | 268 MB |

These startup, memory and frame-rate numbers also predate later runtime
changes and use software rendering. They do not describe the current
desktop performance above.

The second round tells retained memory from a leak: before native windows
allocated with malloc and trimmed it after big removals (`malloc_trim`), the
native build grew to 401 MB after the tests and 437 MB after a second round
(smp_allocator and glibc keep freed pages); now about 260 MB, and +6 MB after a second round.
`ORIEL_NUI_MEM=1` logs the JS heap and the tree's size every 20 renders.
