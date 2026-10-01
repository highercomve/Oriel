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
Backend: GTK 4 (Linux), Android views (JNI), Direct2D (Windows); later UIKit, AppKit
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
inline blocks flowing in text, `position: sticky`, `img`, `canvas`,
`iframe`, `contenteditable`, layout queries beyond sizes and
`scrollHeight`.

## Limits and costs

- The fake DOM and style engine cost memory (a few MB), still far below a
  WebView renderer.
- Code that measures layout or draws (`canvas`, `getBoundingClientRect`
  beyond sizes Yoga knows) does not work.
- DOM-based UI libraries that rely on the browser's layout or event details
  may not work.

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
4. Then: transitions, `:hover`/`:focus`, grid, accessibility, and the
   Apple backends.
