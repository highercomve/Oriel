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

Linux desktop, ReleaseFast, 2026-10-02. The latest comparison runs one visible
process for the previous native runtime, the updated native runtime and
WebView, serially, in identical floating 900 × 700 windows. Each reports
medians of three trials in the second benchmark round. The page is unchanged
and synchronous rendering/layout reads remain inside the timed section.

| Step | Native before this pass | Current native | Fresh WebView |
|---|---:|---:|---:|
| Build 1,000 rows | 127.15 ms | 122.37 ms | 21 ms |
| Build 3,000 rows | 352.95 ms | 327.05 ms | 68 ms |
| Update 1,000 rows | 16.36 ms | 10.85 ms | 10 ms |
| Update 3,000 rows | 50.93 ms | 34.78 ms | 41 ms |

This pass reduces updates 32–34% and builds 4–7%. Native is about 15% faster
for the 3,000-row update, and close at 1,000 rows; WebView still wins builds
by a large margin. These are single-process comparisons, not confidence
intervals or proof of performance on every platform.
[Current comparison, trials and window geometry](results/2026-10-02-rows-phase4-desktop.json).

Native list replacement now detaches Yoga children in bulk, avoiding
quadratic child-vector shifting. Simple new flex leaves build single text
runs directly. GTK retains frames for text edits only when measured natural
width/height are exactly unchanged, the font context matches and the text
fits without wrapping (or has `nowrap`). Painting remains dirty, and Yoga's
measurement cache is invalidated for future resizing. Changed metrics,
wrapped text and other backends continue through layout.

Earlier passes reuse HTML/attribute templates, avoid repeated selector
compilation, directly mark private renderer mutations, share native styles,
copy prepared Yoga styles, cache measurements and compact native lookups.
Page observers retain their queued records and DOM nodes remain fresh.

Current native startup to first frame is 204 ms versus WebView's 486 ms.
Native animation/canvas remain about 60 fps; WebView is about 62 fps. PSS
after the second round is 216 MB native versus 335 MB WebView. Across all
passes, versus `e5f1a2a`, row builds improved 50–60% and updates 88–89%.
[Original native/WebView comparison](results/2026-10-02-rows-desktop.json),
[preceding pass](results/2026-10-02-rows-phase3-desktop.json).

Three serial paired QuickJS processes, two trials per step per process, isolate
the preceding pass's JavaScript changes. The fake host excludes native apply/layout/paint;
values are medians of six measurements:

| Step | DOM before → after | JS render before → after |
|---|---:|---:|
| Build 1,000 rows | 74.10 → 48.95 ms | 144.60 → 132.55 ms |
| Build 3,000 rows | 239.75 → 144.45 ms | 336.15 → 313.45 ms |
| Update 1,000 rows | 7.60 → 6.15 ms | 6.25 → 5.45 ms |
| Update 3,000 rows | 25.80 → 22.05 ms | 21.75 → 20.25 ms |

DOM builds improve 34–40%; JavaScript rendering improves 7–8% for builds and
7–13% for updates. Bridge payload is unchanged by this pass; the preceding
shared-style pass had already reduced build traffic 86–88%.
[Latest isolated results](results/2026-10-02-rows-phase3-qjs.json),
[shared-style pass](results/2026-10-02-rows-phase2-qjs.json),
[first text/observer pass](results/2026-10-02-rows-qjs.json).

Repeat the isolated harness from the repository root with QuickJS-NG:

```sh
qjs src/native_ui/js/test/bench-qjs.js src/native_ui/runtime.js examples/render-bench/web
```

[Research and remaining implementation priorities](../../docs/native-renderer-performance.md)
describe the remaining construction/rendering cost and the WebView gap.

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
