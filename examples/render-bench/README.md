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
renderers. The native renderer's `requestAnimationFrame` is a 16 ms timer, not
the display's frame clock, so its frame rates cap at about 60. Its canvas is
not a bitmap: the 2d calls are replayed into Cairo each frame
(docs/native-renderer.md, "Canvas").

## Results

Linux, ReleaseFast, headless (Xvfb, software rendering), 2026-10-02:

| Test | WebView | Native |
|---|---|---|
| startup → page script | 553 ms | 80 ms |
| startup → first frame | 608 ms | 281 ms |
| memory at start | 295 MB | 147 MB |
| build 1000 rows | 21 ms | 118 ms |
| build 3000 rows | 71 ms | 359 ms |
| update 1000 rows | 10 ms | 10 ms |
| update 3000 rows | 43 ms | 33 ms |
| animate 200 boxes | 60 fps | 37 fps |
| memory after the tests | 334 MB | 235 MB |
| memory after a second round | 337 MB | 251 MB |

The native renderer starts several times faster, in half the memory, and
updates text as fast. Building large DOMs is about 5× slower (QuickJS runs
linkedom and the style engine; WebKit's DOM is native code), and animation
reaches about 37 fps against the WebView's 60.

The second round tells retained memory from a leak: before native windows
allocated with malloc and trimmed it after big removals (`malloc_trim`), the
native build grew to 401 MB after the tests and 437 MB after a second round
(smp_allocator and glibc keep freed pages); now 235 and 251 MB.
`ORIEL_NUI_MEM=1` logs the JS heap and the tree's size every 20 renders.
