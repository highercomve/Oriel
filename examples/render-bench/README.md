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
| startup → page script | 359 ms | 44 ms |
| startup → first frame | 453 ms | 211 ms |
| memory at start | 321 MB | 95 MB |
| build 1000 rows | 19 ms | 113 ms |
| build 3000 rows | 78 ms | 354 ms |
| update 1000 rows | 11 ms | 10 ms |
| update 3000 rows | 44 ms | 34 ms |
| animate 200 boxes | 62 fps | 37 fps |
| canvas 200 balls | 62 fps | 60 fps |
| canvas 1000 balls | 62 fps | 53 fps |
| memory after the tests | 361 MB | 350 MB |

The native renderer starts several times faster and with a third of the
memory, and updates text as fast. Building large DOMs is about 5× slower
(QuickJS runs linkedom and the style engine; WebKit's DOM is native code),
and its memory grows with every rebuild (+255 MB here against +40 MB):
created and removed rows aren't all released yet. Boxes moved by
`requestAnimationFrame` reach only 37 fps against the WebView's 60 — but
the same page drawn as a canvas game loop nearly keeps the 60 its 16 ms
timer allows, and 53 at 1000 balls, where the WebView holds 62 (its canvas
is GPU-accelerated; the replay through the JSON props and the layout cost
the native one its last frames).
