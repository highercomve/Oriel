# Native renderer (experimental)

An optional second renderer: the app's HTML, CSS and JavaScript run without
a WebView, and the page is drawn with the platform's own widgets. The goal is
React Native's footprint (a hello world at about 40 MB on Android, against
about 105 MB with the WebView) while keeping web code: the same `index.html`,
`style.css` and `app.js`, and any framework that renders through the DOM
(React DOM, Vue, Svelte, plain JS).

It is not a browser. It runs the subset of HTML and CSS that maps onto
native views, and says so when a page uses something outside it.

## How it works

```
index.html, app.js, style.css (the app's assets, as for the WebView)
        │
QuickJS-ng ── the page's JavaScript and Oriel's runtime (compiled to
        │  bytecode at build time)
        │
The DOM: the native DOM (a Zig store; linkedom with -Dnative_dom=false):
        │  document, elements, events, timers, window.oriel (invoke/listen)
        │  → the app's Zig commands, as today
        │
Style engine: CSS parsed once; per element the cascade (selectors,
        │  specificity, inline styles), custom properties, inheritance,
        │  media queries (width, prefers-color-scheme, pointer)
        │
Flattener: the DOM → native nodes, several elements per native view
        │  (below), only what changed since the last render; the differences
        │  go to Zig as operations (create / update / children / remove), or
        │  by three faster paths that skip the JSON:
        │    host.text   one text run's new words
        │    host.leaf   a node made from a style defined once
        │    host.stamp  flex rows (and lists of them) read straight from
        │                the native DOM by Zig
        │
Tree (Zig): one node per native view, Yoga (flexbox) layout, text measured
        │  by the platform (sizes cached), CSS paint order, the frames
        │
Backend: GTK 4 (Linux), Direct2D (Windows), AppKit (macOS), UIKit (iOS),
         Android views (JNI): one view draws the page, platform widgets
         for the fields
```

Everything runs on the UI thread, as a browser's main thread: the page's
JavaScript, styles, layout and widget updates. Async commands run on the
worker pool as with the WebView, and resolve their promises back on the UI
thread. `App.emit` reaches the page through the same
`window.oriel.__emit(name, payload)` call as a WebView page.

## The parts

| Part | Where | What it does |
|---|---|---|
| JavaScript engine | `src/native_ui/vendor/quickjs-ng`, `qjs_shim.c` | QuickJS-ng, vendored and built with Zig. The shim makes the engine and its `__host` functions: `ops`, `text`, `leaf`/`leafStyle`, `stamp`/`stampPlan`/`stampList`, `frame` (a layout read), `vsync`, `invoke`, `timer`, `focus`, `scrollTo`, `log`, `asset` |
| Runtime bytecode | `tools/qjs_bytecode.c`, `build.zig` | Oriel's runtime (`runtime-native.js`, or `runtime.js` on linkedom) compiled to QuickJS bytecode by a host tool at build time and loaded with `JS_ReadObject`: nothing to parse at startup. Bytecode made on a 64-bit host loads on 32-bit targets |
| The runtime | `src/native_ui/js/src/main.js` | What a page expects from a browser: timers, `requestAnimationFrame`, events and their default actions, `location.hash` and `history`, `matchMedia`, `localStorage`, `KeyboardEvent`, forms, `window.oriel` |
| The native DOM | `src/native_ui/dom` (`store.zig`, `html.zig`, `selector.zig`, `serialize.zig`, `capi.zig`, `dom_qjs.c`), `js/src/dom/native.js` | The document in a Zig store: nodes in slabs, names interned, `innerHTML` parsed and serialized natively, selectors compiled and matched natively; JavaScript holds thin wrappers. `docs/native-dom.md` |
| linkedom | `js/vendor/linkedom`, `js/src/dom/linkedom.js` | The JavaScript DOM the renderer started on, vendored; `-Dnative_dom=false` |
| Style engine | `js/src/css.js` | Stylesheets parsed once, rules indexed by their rightmost selector, the cascade, `var()`, `calc()`, `color-mix()`, inheritance, `@media`; elements with the same styles share one computed style |
| Flattener | `js/src/render.js`, `html.js`, `icons.js` | Styled DOM → native nodes (below), incremental: only elements marked by the mutation observer are restyled and flattened. Emits ops, or uses the direct paths: `host.text` for a text run, `host.leaf` for nodes from a shared style, row plans for stamping |
| Transitions, animations | `js/src/transitions.js`, `animations.js` | CSS transitions and `@keyframes`; while they run, only the animated nodes are sent each frame (transform-only frames skip the flattener) |
| Canvas | `js/src/canvas.js`, each backend, `OrielCanvas.kt` | The 2d context as a recorded program, replayed by the backend into a bitmap of the canvas's own (below) |
| Engine | `src/native_ui/engine.zig` | One per window: QuickJS, the tree and the backend behind a small interface (`Backend`). Runs the page's commands, timers and answers on the UI thread, renders after each call into JavaScript or once per frame (`request_frame`), and paces `requestAnimationFrame` to the display (`request_display_frame`) |
| Node tree | `src/native_ui/tree.zig` | One node per native view: the ops applied, CSS mapped onto Yoga, layout, sticky, tables, a text's longest word as its minimum width in a row, CSS paint order (z-index, positioned boxes), hit testing, scrolling; leaf styles and stamped rows (`createLeaf`, `stampRow`); hooks for backends that keep their own copy of the props (`on_props`, `on_text`, `on_leaf_style`, `on_create`, `on_remove`) |
| Row stamping | `src/native_ui/dom_stamp.zig` | A flex row of simple leaves, or a list of identical rows, read straight from the native DOM into the tree, without a JavaScript object per child |
| Text sizes | `text_measure_cache.zig`, the backends | Text is measured by the platform's own engine (Pango, DirectWrite, Core Text, StaticLayout); a text's natural size is kept on its node, and sizes by content and width in a bounded cache |
| Icons | `js/src/icons.js`, `svg_path.zig` | Inline SVG as vector shapes; path data parsed for backends without a parser (Core Graphics, Direct2D) |
| Backends | `gtk.zig`, `win32.zig`, `appkit.zig`, `uikit.zig`, `apple_draw.zig`, `android.zig` + `OrielNative.kt` | One view draws the whole page; fields are the platform's widgets placed over it |
| Tools | `examples/render-bench`, `tools/flatten_diff`, `tools/dom_bench`, `prof.zig` | The bench (WebView vs native, on-screen times on Android: `onscreen.py`); the same tree with and without a flattener change; the DOM alone; per-stage timings (`-Dnative_ui_prof`) |

## The DOM

With `-Dnative_ui` the page's DOM is the native one by default: a Zig store
of nodes and attributes (`src/native_ui/dom`) behind QuickJS bindings, with
the JavaScript side's interfaces on top (`src/native_ui/js/src/dom/native.js`;
design in `docs/native-dom.md`). Building 1000 rows of the render bench takes
about half as long as on linkedom, and memory after its tests stays flat.

`-Dnative_dom=false` builds the same renderer on linkedom (the JavaScript DOM
vendored in `src/native_ui/js/vendor/linkedom`): to compare the two, or as a
fallback while a page needs something the native DOM lacks. The JavaScript
side reaches either through one module, `#dom` (`src/dom/linkedom.js` or
`src/dom/native-backend.js`); `npm run build` makes `runtime.js` (linkedom)
and `runtime-native.js` (the native DOM), and the build embeds the one chosen.

## Flattening: several elements, one native view

| HTML | Native view |
|---|---|
| An element whose children are all text and inline elements (`b`, `i`, `strong`, `em`, `a`, `span`, `code`, `small`, `br`) | One text view with styled runs (Pango attributes, Android spans) |
| A box that only lays out its children (no background, border or shadow) | No view: a layout node; its children are placed in its parent |
| A box with a background, border, radius or shadow | One plain view |
| `button` (with an icon and a label) | One native button |
| `input`, `textarea` | One native text field |
| `input type=checkbox` | One native switch |
| `input type=range` | One native slider (min, max, step; GtkScale on GTK, a trackbar on Windows, SeekBar on Android, NSSlider/UISlider on Apple): dragging sends `input`, letting go `change` |
| `svg` with `<use href="#symbol">`, `img` | One image (the SVG rasterized at its size and color) |
| `canvas` (2d context) | One view that replays the recorded 2d program (see below) |
| `display: none`, `[hidden]` | Nothing |

Events go the other way: a click on a native view becomes a `click` on its
element (bubbling through the fake DOM); text fields send `input`; Enter in
a single-line field submits its `form`.

## CSS

Supported: selectors (types, classes, ids, attributes, `:not`, `:first-child`,
`:focus`, `:hover`, `:active`, descendant and child combinators, `::before`/`::after`), the
cascade and `!important`, `var()` with fallbacks, `calc()`, `color-mix()`,
inheritance of text properties, `@media` on width, color scheme and pointer;
for layout `display` (`flex`, `block`, `inline-flex`, `none`, `grid`
approximated by wrapping rows, and tables: `table`, row groups, rows and
cells with automatic column widths, `colspan` and `border-spacing`), the
flexbox properties, `gap`, sizes, margins, padding,
`position: absolute`/`fixed`/`relative`/`sticky` and `inset`,
`overflow`, transforms (translate moves the box; scale and rotate are drawn
around its center); for drawing colors, linear and radial gradients,
borders, `border-radius`, `box-shadow` (blurred like CSS), `opacity`, fonts,
`text-align`, `white-space`; transitions and `@keyframes` animations on
opacity, backgrounds, color, transforms, sizes, border colors and shadows
(src/native_ui/js/src/transitions.js, animations.js: while they run, only
the animated nodes are sent each frame).

Ignored for now (the layout still works): animating `background-position`,
skew and 3D transforms, `filter`, `backdrop-filter` (a blurred background is
drawn opaque). Not supported: floats,
inline blocks flowing in text, `rowspan`, `img`, `iframe`,
`contenteditable`, layout queries beyond sizes and
`scrollHeight`.

## Limits and costs

- The fake DOM and style engine cost memory (a few MB), still far below a
  WebView renderer.
- Code that measures layout or draws (`getBoundingClientRect`
  beyond sizes Yoga knows) does not work.
- DOM-based UI libraries that rely on the browser's layout or event details
  may not work.

## Canvas

`<canvas>` works with a 2d context, without a bitmap (`src/native_ui/js/src/canvas.js`):
`getContext("2d")` returns a recorder, and each drawing call appends a compact
op to the element's program, which travels as the node's `cv` prop and is
replayed on every paint. On GTK the program draws with Cairo into the
canvas's own image surface (kept from frame to frame while the size holds),
which is then painted on the page, clipped to the box's border-radius. On
macOS and iOS it draws with CoreGraphics into a CGBitmapContext the same way
(apple_draw.zig: the box at the display's backing scale, at most 16 M
pixels; text with CoreText), and on Windows with Direct2D into its own
bitmap render target. A
program can't harm the page: an unbalanced `restore()` is ignored, a
`clearRect` clears the canvas only, and a call with an argument that isn't a
finite number is dropped (by the recorder and again by the parser), as in a
browser. A `scale(0)` hides what follows until the `restore()` that undoes it.

The element sizes like a replaced element: the bitmap's size, or with one
CSS dimension (or stretched in a column) the bitmap's ratio, and it doesn't
shrink in a flex container.

Supported: `fillRect`, `strokeRect`, `clearRect`, `beginPath`, `closePath`,
`moveTo`, `lineTo`, `rect`, `arc`, `ellipse`, `bezierCurveTo`,
`quadraticCurveTo` (as a cubic), `fill` (winding and evenodd), `stroke`,
`clip`, `save`/`restore`, `translate`/`scale`/`rotate`, `fillText`,
`strokeText`, colors (hex, `rgb()`, `hsl()`, names) and linear and radial
gradients, `globalAlpha`, `lineWidth`/`lineCap`/`lineJoin`, `font` (size,
weight, style, family), `textAlign` and `textBaseline`.

Not a bitmap: no `drawImage`, no `getImageData`/`putImageData`, no
`measureText` (a width estimate; Pango measures the DOM's text) and no
patterns. The program re-runs whole on every paint, so it must stand for
the whole bitmap: a `clearRect` — or an opaque `fillRect` — that covers it
all with no clip or transform in effect drops everything recorded before it
(a game loop's clear-then-redraw then keeps one frame's ops); drawing
without such a clear accumulates, as in a browser.

Every backend draws canvases. On Android (`OrielCanvas.kt`) the program is
parsed once per change and replayed into an `android.graphics.Bitmap` of
the canvas's own (frame size × density, at most 16384 px a side and 16 M
pixels), kept while the size holds and recycled when the node goes or the
view leaves its window; it is drawn at the box, clipped to the
border-radius. On Windows, `strokeText` outlines the font's own glyphs (no
fallback fonts), and a radial gradient's two circles share a center offset
as Direct2D draws them (the inner radius moves the stops).

### Canvas from Zig

With the native renderer, the app's Zig code can draw into a page's
`<canvas>` itself, with no JavaScript per frame: `oriel.canvas`
(`src/native_ui/zig_canvas.zig`). The page lays the canvas out (and its
buttons, scores and menus); Zig simulates and draws.

```zig
const canvas = oriel.canvas;

const Game = struct {
    target: canvas.Canvas,
    program: canvas.Program,
    // … the game's state

    fn frame(g: *Game, _: canvas.Frame) bool {
        const p = &g.program;
        p.begin();
        p.fillStyle(canvas.rgb(0x10141b));
        p.fillRect(0, 0, 640, 360);
        p.circle(g.x, g.y, 6);
        p.fillStyle(canvas.rgb(0x6d8bff));
        p.fill();
        return g.target.commit(p); // false: the window or the canvas went
    }
};

// On the UI thread (a command, or after the page asked for it), once the
// page shows <canvas id="game" width="640" height="360">:
const window = oriel.App.getWindow("main").?;
game.target = canvas.Canvas.open(window, "game") orelse return; // null: not native, or not rendered yet
game.program = .init(gpa);
try canvas.onFrame(window, &game, Game.frame); // each display frame
```

- **Finding the canvas**: by its element's `id` attribute (render.js sends
  it with the canvas's props). A `Canvas` is a value holding the window's
  engine serial and the node's id, no pointer: after the window closes or
  the page replaces the element, `commit` finds the element again by id, or
  returns false.
- **The program**: the same model as the page's 2d context (paths, arcs,
  rectangles, text, transforms, gradients: `CanvasCmd`), so every backend
  replays it as a page's canvas (GTK and Apple bitmaps, Win32 Direct2D,
  Android's hardware canvas through `Backend.canvas`). Coordinates are the
  canvas's drawing space (its `width`/`height` attributes, `Canvas.size()`);
  the box scales it as in a browser. Recording never fails: out of memory
  marks the program and `commit` refuses it.
- **Memory**: `commit` gives the program's memory to the tree and takes the
  previous frame's back (the two arenas swap contents), so a program drawn
  every frame allocates nothing once warm. The tree owns what was committed
  until the next commit or the node goes.
- **Threads**: build a program on any thread; `commit`, `open`, `onFrame`
  and `stopFrames` run on the UI thread. The frame callback runs there, at
  the display's rate (the same display-frame path as
  `requestAnimationFrame`), and frames stop when no callback and no
  `requestAnimationFrame` wants one. A simulation on a worker hands its
  state (or a built program) to the UI thread with `App.runOnMain`.
- **Who draws**: once Zig commits to a canvas, the page's own drawing into
  it (its 2d context, or a `cv` prop) is ignored, until `release()`.
- **The WebView** has no such canvas (`open` returns null; the module is
  `oriel.canvas` only with `-Dnative_ui`): an app that supports both draws
  with the page's 2d context there.

render-bench runs the canvas balls both ways (`zig_balls.zig`). GTK, 180 Hz
desktop: 1000 balls at 150 fps from Zig (13 µs of Zig work a frame, then
the backend's 4.5 ms replay) against 90 from JavaScript (2.9 ms of physics
and recording, 1.8 ms encoding, then the same replay); 200 balls hold the
display's 180 either way.

## Milestones

1. **Linux prototype** (`-Dnative_ui`): QuickJS-ng and Yoga built with Zig,
   the JS runtime, the GTK backend; the showcase running with it; memory
   against the WebKitGTK build.
2. **Android** (`src/native_ui/android.zig`, `OrielNative.kt`): the same
   engine; like on GTK, one view (`NuiView`) draws the page on a Canvas,
   with real EditText/Spinner/SeekBar widgets over the fields. See
   "Android" below. A native window never creates a WebView. The showcase
   APK measured with `dumpsys meminfo` against the WebView build.
3. **Windows** (`src/native_ui/win32.zig`): one child window, the canvas,
   draws boxes, gradients, borders, shadows, text (DirectWrite, color
   emoji) and icons (Direct2D path geometries from
   `src/native_ui/svg_path.zig`, which parses SVG path data) with
   Direct2D; fields are real EDIT and COMBOBOX controls over it, with
   Enter and Escape sent to the page first. Clicks, the wheel, keys and
   hover are hit-tested in Zig as on GTK. The render target's DPI is the
   window's, so the tree stays in CSS pixels. A transparent window (overlays)
   clears to transparent and gets the same DWM blur-behind as a WebView2
   one, so only what the page paints shows; always-on-top and placement
   are the window's, as for WebView2 windows. A native window never
   creates WebView2. Commands run from the message loop (queued, as sync web
   commands are) and answer only engines whose window is still open. The
   showcase, idle on its first tab: 31 MB private working set in one
   process, against 90 MB in seven processes with WebView2.

   Not yet: color emoji inside the EDIT controls (GDI draws them as
   outlines), owner-drawn selects (a COMBOBOX keeps the system look), IME
   composition shown on the canvas (fields get it from Windows), and
   accessibility (UI Automation).
4. **macOS and iOS** (`src/native_ui/appkit.zig`, `uikit.zig`, sharing
   `apple_draw.zig`): see "Apple" below. The showcase's `tour` and `chat`
   UI tests pass on both; GhostPen's menu, Settings, Playground and its
   transparent dictation and captions overlays run on AppKit.
5. Then: grid, and accessibility (UI Automation, NSAccessibility, UIAccessibility, AT-SPI, Android's AccessibilityNodeProvider).

## Apple (macOS, iOS)

`-Dnative_ui` builds for macOS and iOS. Both backends draw the page the
same way, in `apple_draw.zig`: boxes, borders, shadows (stacked layers, as on
GTK), gradients and icons with CoreGraphics, text with CoreText (the system
font at the CSS weight, from NSFont/UIFont, which are toll-free bridged to
CTFont; a node's framesetter and frame are kept between layout and paint
until its props change). CoreGraphics has no SVG path parser:
`svg_path.zig` turns path data into move/line/curve calls (arcs as cubics).

| | macOS (AppKit) | iOS (UIKit) |
|---|---|---|
| The page | one flipped NSView, the window's content view | one UIView in the controller's safe area, like a web view |
| `input` / `textarea` / `select` | NSTextField (NSSecureTextField), NSTextView in an NSScrollView, NSPopUpButton | UITextField, UITextView, a UIButton with a UIMenu |
| `input type=range` | NSSlider (`accent-color` tints the track) | UISlider |
| Input | clicks (control-click and right-click: `contextmenu`), hover and the hand cursor, the scroll wheel and trackpad, keys | taps, long presses (`contextmenu`), drags with a fling (gesture recognizers) |
| Dark mode | the view's effective appearance | the trait collection |

Native controls sit above everything the page draws, so each one is held
by a view clipped to the part of its field the page shows: its content
box within its clip, minus a bar painted over it later across its whole
width (a fixed header or footer).

The page renders at most once per frame (`Backend.request_frame`), however
many events arrive (a chat streams a hundred tokens a second), and a page
whose render takes long gets fewer frames, at least twice its render time
apart, so commands and events still get through between them. The page's
commands run from the main loop, never inside its JavaScript (a command may
close the window, and with it the engine), and answers, timers and frames
find their window by token, so one that arrives after it closed is dropped.

Windows: transparency, always on top and placement as for a web view window
(`overlay.setup` on macOS). On iPhone a second window is presented full
screen with a close button (UIKit's), since nothing else closes it there;
on iPad it gets a scene of its own.

Debugging: `ORIEL_NUI_SNAPSHOT=<dir>` (macOS) writes each native window as
drawn, fields included, to `<dir>/<label>.png` a moment after each layout,
for runs nobody watches; `ORIEL_NUI_TRACE=1` logs clicks.

Memory (the showcase, idle on its first tab, `footprint`): on macOS about
70 MB for the native build against about 96 MB for the WebView build and its
WebKit processes (GPU, WebContent, Networking); in the iOS simulator 196 MB
against 550 MB (simulator processes carry the simulated system frameworks,
so device numbers are lower, but the WebKit processes are what goes).

Images (`<img>`, a `data:` URI or an app asset) are decoded with ImageIO:
the size a file declares is read from its header first, and a picture over
4096 x 4096 px keeps that size for layout and isn't drawn (as on GTK);
what's kept decoded is at most 2048 px on its longer side, and drawn per
`object-fit`. Default checkboxes and radios are drawn as on GTK, and a text
area's placeholder under its empty NSTextView / UITextView.

Not yet: keyboard avoidance on iOS (a field under the keyboard isn't
scrolled up), and the hardware keyboard on iOS (only fields get keys).
CoreText, like Pango, breaks a word that doesn't fit its line, where CSS
lets it overflow.

## Android

`android.zig` and `OrielNative.kt`. Like on GTK, one view (`NuiView`)
draws the whole page on a Canvas: boxes, borders, shadows, gradients, text
(StaticLayout with spans), icons (Path) and canvases (`OrielCanvas.kt`),
in CSS paint order (z-index, then positioned and sticky boxes over the
rest). Fields are real widgets placed over it: EditText, Spinner for a
`select`, SeekBar for `input type=range`; one the page draws over (a sticky
footer) is clipped to what shows.

Kotlin keeps its own copy of each node's props: it draws from them and
measures text with them. Everything runs on the UI thread, and the JNI
boundary is crossed per change, not per element:

| What crosses | When |
|---|---|
| A node's props as JSON (`nuiProps`) | The general path: a node made or changed by the page's ops |
| A text run's new words (`nuiText`) | `host.text`: a text-only change keeps the node's paint; only the styled text and its layout are made again |
| Leaf styles and leaves, one batch (`nuiLeaves`) | `host.leaf` and stamped rows: each leaf style once (its props JSON, parsed once into a template), then a compact record per node (id, kind, style, text). Sent before anything else names one of them |
| The frames, one packed array (`nuiFrames`) | After each layout or scroll: per node its id (as int bits, exact for any id), frame, clip, content box and subtree size |
| Text sizes (`nuiMeasure`) | Only on a miss: a text's natural size is kept on its node, sizes by content and width in a cache, and Kotlin keeps its last answer and one-line width |
| A display frame (`nuiRequestFrame` → `displayFrame`) | While the page wants animation frames: one `Choreographer` callback per frame at the display's rate (120 on a 120 Hz phone), none when it stops |

Touches come back as taps, drags with fling, long presses (`contextmenu`)
and the mouse wheel, hit-tested in Zig on the tree. A transparent window
(an overlay) opens in a translucent Activity, so nothing is drawn where the
page draws nothing. armv7 and x86 builds work (32-bit: the store's tests
and the bytecode were checked under qemu).

Debugging: an app gets no environment variables on Android, so Oriel reads
them from a system property when it loads,
`adb shell setprop debug.oriel.env "'ORIEL_NUI_TRACE=1 ORIEL_NUI_MEM=1'"`.
`ORIEL_NUI_TRACE` logs the ops and, from NuiView (tag `OrielNui`), each draw
and every 120th display frame; `ORIEL_NUI_MEM` the JavaScript heap and the
node count; `ORIEL_NUI_DUMP` what NuiView holds after each layout (kind,
frame, colors, text), to compare two builds on a device.
`examples/render-bench/onscreen.py` turns the trace into the time until a
change is on screen.

Speed (render bench, a Chromebook, arm64 ReleaseFast, the median of 3; the
page's time includes NuiView applying the change, "on screen" adds
Android's layout pass and the draw):

| | Before the direct paths | Now | On screen now |
|---|---|---|---|
| Build 1000 rows | 194 ms | 13–14 ms | 35–37 ms |
| Build 3000 rows | 712 ms | 36–40 ms | 108–188 ms |
| Update 1000 rows | 78 ms | 31 ms | 37–38 ms |
| Update 3000 rows | 229 ms | 74–78 ms | 89–91 ms |
| Animate 200 boxes | 57 fps | 59 fps (60 Hz display; 118 fps on a 120 Hz phone's canvas demo) | |
| Memory after the tests (PSS) | 127 MB | 109–114 MB | |

"Before": the native DOM with every change as JSON. The gains came from
the text bridge (an update of 1000 rows 78 → 37–44 ms), text sizes cached in Zig and
Kotlin (builds 35–45% faster), and stamping (build 1000 rows 110 → 13 ms).
