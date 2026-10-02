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
QuickJS ── a fake DOM (linkedom): document, elements, events, timers,
        │  window.oriel (invoke/listen) → the app's Zig commands, as today
        │
Style engine: CSS parsed once; per element the cascade (selectors,
        │  specificity, inline styles), custom properties, inheritance,
        │  media queries (width, prefers-color-scheme)
        │
Flattener: the DOM → native nodes, several elements per native view
        │  (below); diffed against the last frame → operations
        │  create / update / children / remove
        │
Zig: one node per native view, Yoga (flexbox) layout, text measured by
        │  the platform, frames applied
        │
Backend: GTK 4 (Linux), Android views (JNI), Direct2D (Windows), AppKit (macOS),
         UIKit (iOS)
```

Everything runs on the UI thread, as a browser's main thread: the page's
JavaScript, styles, layout and widget updates. Async commands run on the
worker pool as with the WebView, and resolve their promises back on the UI
thread. `App.emit` reaches the page through the same
`window.oriel.__emit(name, payload)` call as a WebView page.

## Flattening: several elements, one native view

| HTML | Native view |
|---|---|
| An element whose children are all text and inline elements (`b`, `i`, `strong`, `em`, `a`, `span`, `code`, `small`, `br`) | One text view with styled runs (Pango attributes, Android spans) |
| A box that only lays out its children (no background, border or shadow) | No view: a layout node; its children are placed in its parent |
| A box with a background, border, radius or shadow | One plain view |
| `button` (with an icon and a label) | One native button |
| `input`, `textarea` | One native text field |
| `input type=checkbox` | One native switch |
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
approximated by wrapping rows), the flexbox properties, `gap`, sizes,
margins, padding, `position: absolute`/`fixed`/`relative` and `inset`,
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
inline blocks flowing in text, `position: sticky`, `img`, `iframe`,
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
pixels; text with CoreText). A
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

GTK, macOS and iOS draw canvases (Apple: a CGBitmapContext per node, in
apple_draw.zig); Windows and Android lay them out but draw nothing yet.

## Milestones

1. **Linux prototype** (`-Dnative_ui`): QuickJS-ng and Yoga built with Zig,
   the JS runtime, the GTK backend; the showcase running with it; memory
   against the WebKitGTK build.
2. **Android** (`src/native_ui/android.zig`, `OrielNative.kt`): the same
   engine; like on GTK, one view (`NuiView`) draws the boxes, text
   (StaticLayout with spans) and icons (Path) on a Canvas, with real
   EditText/Spinner widgets over the fields. Kotlin keeps a copy of each
   node's props (JSON, sent when they change) and gets the frames as one
   packed float array after each layout; taps, drags (with fling) and long
   presses are hit-tested in Zig. A native window never creates a WebView.
   The showcase APK measured with `dumpsys meminfo` against the WebView
   build.
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
5. Then: grid, accessibility (UI Automation, NSAccessibility, UIAccessibility, AT-SPI), and incremental styling (a full render restyles the whole document).

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