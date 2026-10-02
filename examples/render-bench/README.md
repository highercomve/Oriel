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

### Flattening and emission follow-up

On `2143d84`, row leaves premerge font/layout setup, copy ordinary font fields
directly, share style/flattening snapshot storage and avoid iterator pair arrays
in emission. Properties and text runs remain owned per node; regression tests
cover later font/style edits and interactive/empty leaves. All checks pass.

Isolated QuickJS row-build rendering improves 3.4–4.6%. The final native desktop
comparison is mixed; it does **not** establish a clear overall construction win:

| Step | Before (`2143d84`) | Updated native |
|---|---:|---:|
| Build 1,000 rows | 91.56 ms | 95.50 ms |
| Build 3,000 rows | 289.90 ms | 279.52 ms |
| Update 1,000 rows | 10.85 ms | 10.64 ms |
| Update 3,000 rows | 35.41 ms | 34.54 ms |

One visible process per version, both built before timing, 900×700 windows,
unchanged synchronous layout reads, second-round medians of three trials.
Build trial ranges overlap. The preceding candidate was also mixed and remains
recorded. WebView numbers below are earlier reference measurements. The shared
macOS width-change layout shortcut is still open.
[Final comparison](results/2026-10-02-rows-phase7-desktop.json),
[preceding candidate](results/2026-10-02-rows-phase7-first-desktop.json),
[isolated rendering](results/2026-10-02-rows-phase7-qjs.json).

### Construction pass

The next pass avoids token Sets for simple class names, initializes ordinary
DOM elements/text without the constructor chain, and caches resolved font sizes
by computed style and parent size. Relative-font style reuse now invalidates
correctly after parent font changes. Full JavaScript/native checks pass.

Both binaries were built first, with no compilation during timing. One visible
process per version used the unchanged page, 900×700 windows, synchronous
layout reads and second-round medians of three trials:

| Construction | Before (`a6d6e53`) | Updated native |
|---|---:|---:|
| 1,000 rows | 106.75 ms | 91.64 ms |
| 3,000 rows | 300.47 ms | 291.27 ms |

The smaller build improves 14%; the larger median improves 3%, but its trial
ranges overlap. Isolated QuickJS DOM construction improves about 21% at both
sizes. The DOM-only candidate had mixed larger-list results; adding font-size
caching gave the final result above. General style sharing, measurement and
layout still dominate the remaining construction gap versus WebView.
[Construction comparison](results/2026-10-02-rows-phase6-desktop.json),
[DOM-only candidate](results/2026-10-02-rows-phase6-dom-only-desktop.json),
[isolated DOM/render timings](results/2026-10-02-rows-phase6-qjs.json).

### Preceding allocation pass and WebView reference

Linux desktop, ReleaseFast, 2026-10-02. The preceding comparison runs one visible
process for the previous native runtime, the updated native runtime and
WebView, serially, in identical floating 900 × 700 windows. Each reports
medians of three trials in the second benchmark round. The page is unchanged
and synchronous rendering/layout reads remain inside the timed section. Both
native binaries were built first, using reviewed main `9f21bb9` as the baseline
and `780f945` as current. Measurements waited for the user's Yocto build to
finish; compiler/Yocto checks were quiet before and after the comparison.

| Step | Native before this pass | Current native | Fresh WebView |
|---|---:|---:|---:|
| Build 1,000 rows | 125.66 ms | 106.33 ms | 19 ms |
| Build 3,000 rows | 340.51 ms | 304.82 ms | 72 ms |
| Update 1,000 rows | 11.77 ms | 10.69 ms | 10 ms |
| Update 3,000 rows | 39.00 ms | 33.44 ms | 41 ms |

This allocation pass reduces updates 9–14% and builds 10–15%. Native is about 18% faster
for the 3,000-row update, and close at 1,000 rows; WebView still wins builds
by a large margin. These are single-process comparisons, not confidence
intervals or proof of performance on every platform.
[Current comparison, trials and window geometry](results/2026-10-02-rows-phase5-reviewed-desktop.json).

The owned LinkeDOM source now allocates listener Maps only on the first
listener. Flattening uses scalar primary IDs, shared empty child arrays and
leaf snapshots, and a single style cache with epoch invalidation. Runtime and
tests import `src/native_ui/js/vendor/linkedom`; the build has no dependency
source patches.

Native list replacement also detaches Yoga children in bulk, avoiding
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

That pass measured native startup to first frame at 220 ms versus WebView's 482 ms.
Native animation/canvas remain about 60 fps; WebView is about 62 fps. PSS
after the second round is 194 MB native versus 353 MB WebView, and down from
228 MB for the reviewed native baseline. Earlier passes already substantially
reduced the original row costs.
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
