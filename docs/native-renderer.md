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

An SVG's own `<style>` (Vite's logo: class fills and a
`prefers-color-scheme` rule on a root with `fill="none"`) paints its
shapes (icons.js `svgSheet`/`styleOf`): its rules, by specificity and
order, media queries answered, over presentation attributes, and a shape's
`style` attribute over both; `fill`, `stroke`, the stroke's width, cap and
join, `display: none`, `visibility: hidden`, and `opacity`,
`fill-opacity` and `stroke-opacity` (multiplied into the shape's colors).
An SVG drawn as an image (`<img src="logo.svg">`) sees a light color
scheme, as a browser's SVG image does; an inline one follows the page.
Checked against WKWebView: the same logo inline and as an image, in dark
mode (white parentheses inline, black in the image).

Events go the other way: a click on a native view becomes a `click` on its
element (bubbling through the fake DOM); text fields send `input`; Enter in
a single-line field submits its `form`.

## CSS

Style sheets: every `<style>` and `<link rel="stylesheet">` (an app
asset), in document order, at boot and whenever the page changes one.
A sheet added, removed or disabled (`disabled` on a `<link>`, a sheet's
`disabled`), a `<style>`'s text changed, or rules inserted or deleted
through the CSSOM (`element.sheet`, `document.styleSheets`, `cssRules`,
`insertRule`/`deleteRule`, as CSS-in-JS libraries use them) all restyle
the page at the next render. Only the elements that the rules that came or
went match are styled again (a changed sheet is compared rule by rule, so
one inserted rule parses and matches one rule). Everything is restyled
when that can't be told: `:has()`, `@keyframes`, a selector the DOM can't
query, or more than 64 rules at once. A `<link>` added after boot fires
`load` (or `error`). The boot's sheets go through the parsed-sheet cache
(the build's and the process's); later ones are parsed when they come.
Constructed sheets (`new CSSStyleSheet()`) exist but aren't applied
(`adoptedStyleSheets` isn't supported).

Supported: selectors (types, classes, ids, attributes, `:not`, `:first-child`,
`:focus`, `:focus-visible`, `:hover`, `:active`, descendant and child combinators, `::before`/`::after`), the
cascade and `!important`, `var()` with fallbacks, `calc()`, `color-mix()`,
inheritance of text properties, `@media` on width, color scheme and pointer;
for layout `display` (`flex`, `block`, `inline-flex`, `none`, `grid`
approximated by wrapping rows, and tables: `table`, row groups, rows and
cells with automatic column widths, `colspan` and `border-spacing`), the
flexbox properties, `gap`, sizes (`width: max-content` and `fit-content`
too: the box isn't stretched; inside max-content, text doesn't wrap and
may overflow the container (the `mc` prop: measureFn doesn't hold it to
the width offered); inside fit-content, text that has to wrap takes the
whole width offered (`fc`)), margins, padding,
`position: absolute`/`fixed`/`relative`/`sticky` and `inset`,
`overflow`, transforms (translate moves the box; scale and rotate are drawn
around its center); for drawing colors, linear and radial gradients (and
repeating ones; see "Gradient stops" below),
borders, `border-radius` (with sides of different widths, the inner
corners are ellipses and colors meet on the lines from the outer to the
inner corners, as browsers draw a card's `border-left: 6px`; GTK:
roundedSides in gtk.zig), `box-shadow` (blurred like CSS), `outline`, `opacity`, fonts,
`text-align`, `white-space`, `<br>` (in text, in inline elements, and in
a line of text and inline boxes, where what follows it starts a new line:
a full-width break in a row that wraps; a last `<br>` adds no line);
transitions and `@keyframes` animations on
opacity, backgrounds, color, transforms, sizes, border colors and shadows
(src/native_ui/js/src/transitions.js, animations.js: while they run, only
the animated nodes are sent each frame).

**Scroll events** (each backend):

- Every change of a scroller's offset goes through the engine:
  `Engine.scrollBy` / `scrollByX` (wheel, scrollbar, touch), host.scrollTo
  and scrollIntoView, and a layout that clamps it (content that shrank).
  Each notes the node (`Tree.noteScroll`, once until the page hears) and
  asks for a display frame; at the next one, before the page's animation
  frame, `__oriel.scrolled([[id, scrollTop, scrollLeft], ...])` fires
  "scroll" on each scroller (it doesn't bubble), the window's (node -1)
  on the document and then the window: at most once a frame each, as
  browsers. A backend that scrolls a node itself (its own scroll view)
  must set `scroll_y`/`scroll_x` through these, or call
  `Tree.noteScroll` and request a frame.
- `host.frame(id)[6]`, `[7]` are the offsets: `scrollTop`/`scrollLeft`
  read them (they were 0; whole px on macOS and iOS, as WebKit gives
  them, after a fling between pixels) and set them (`host.scrollTo(id, y, x)`, NaN
  leaving an axis), and so do `scrollY`/`pageYOffset`/`scrollX`, the
  root's and `document.scrollingElement`'s (node -1), `element.scrollTo`,
  `scroll` and `scrollBy`.
- Keys scroll as browsers' default when the page doesn't take them:
  ArrowUp/Down 40px, PageUp/Down and Space (Shift: up) 87.5% of the view
  (whole px), Home/End to the ends, on the focused element's nearest
  scroller, else the window; never from a field.

**Scrollbars** (each backend):

- A backend whose WebView's scrollbars take room (Windows' classic ones)
  sets `Tree.scrollbar = .{ auto, thin }` in CSS px (Win32: 15, 10); an
  overlay platform leaves it 0 and nothing changes. A scroller (`scroll`,
  the window's node -1 too) that overflows, or has `sbs` (overflow-y:
  scroll, scrollbar-gutter: stable), then keeps that room at its right
  (`Node.gutter`): Tree.layout lays it out again with it, taken from its
  content box (a content-box px width shrinks; `sbw: "none"` keeps none,
  `"thin"` the thin width). `host.frame(id)[5]` is the gutter: JS's
  clientWidth leaves it (and the borders) out, and
  `document.documentElement.clientWidth` the window's.
- The backend draws the bar in that room and handles it: `dk` (dark: the
  scroller's color-scheme, the window's also from the system's), `sbc`
  (scrollbar-color [thumb, track]). Win32 draws WebView2's: track
  #fcfcfc / #2c2c2c, thumb and arrows #8b8b8b / #9f9f9f, a pill thumb 60%
  of the bar's width, arrow buttons as tall as it's wide; arrows scroll
  40px, the track 87.5% of the view (both repeating while held), the
  thumb drags, the wheel scrolls the system's lines per notch at 100/3 px
  a line (100px), as Chromium.

- Apple: overlay scrollbars (the default) take no room, as WKWebView's;
  a scroller the user scrolls (wheel, trackpad, touch) shows an overlay
  indicator a moment, fading out (apple_draw paintIndicators, from
  `Node.flashed_at`): iOS's as UIScrollView draws it (measured in
  WKWebView: 3 pt wide, 3 pt from the edges, black or white at half
  alpha), macOS's as AppKit's overlay knob (7 pt, 2 pt in; not compared:
  WKWebView's scrollers aren't in its snapshots). With scroll bars always
  shown (NSScroller.preferredScrollerStyle legacy: the System Settings
  choice, or a mouse without gestures), macOS sets `Tree.scrollbar = 15,
  11` (WebKit's classic widths) and draws a classic bar in the gutter
  (paintLegacyScrollbar; its look not compared either: the setting
  wasn't changed). clientWidth, clientHeight and scrollHeight match
  WKWebView on both (a bordered, overflowing scroller and the root).
- A scroller's `content_h` (and `content_w`) reaches its bottom (right)
  border: `content_h - frame.h` is how far it scrolls (to scrollHeight -
  clientHeight), and its children clip at its padding box, not over its
  borders. `host.frame[4]` (scrollHeight) is the padding box's content.

**Field edits and selection** (each backend with native text fields):

- Keys first: keydown (and keyup) on the field before the control acts, a
  prevented keydown (or keypress, which main.js fires after it for a
  character or Enter) keeping the key from the control.
- Then, for a key that edits, `Engine.event(id, "beforeinput", [inputType,
  data])` before the control applies it; `true` back means the page
  prevented it and the control must not make the edit. inputType as
  Chromium names them: `insertText` (data: the character),
  `insertLineBreak` (Enter in a textarea), `deleteContentBackward` /
  `deleteContentForward` (Backspace / Delete; `deleteWord…` with Ctrl or
  Option), `insertFromPaste` (data: the pasted text, without line breaks
  in a one-line field), `deleteByCut`, `historyUndo`. None for a key that
  changes nothing (Backspace at the start).
- After the edit, `"input"` with `[value, inputType, data]` (the same pair
  the beforeinput had; a plain value string still works, as an edit with
  no type).
- `Backend.selection(node) → [start, end]` and `Backend.set_selection(node,
  start, end)`, in UTF-16 units of the value (LF line ends: a Win32
  textarea's CR LF counts once): `el.selectionStart`, `selectionEnd`,
  `setSelectionRange()` and `select()` use them (host.selection,
  host.setSelection); without them main.js keeps what the page set.
  Win32 does all of this (IME composition stays the control's: no
  beforeinput for it). Android too (OrielNative.kt beforeInput): an
  InputFilter on each EditText sees every edit before it lands (hardware
  keys, the soft keyboard's commits, paste, cut and undo from Ctrl or the
  context menu), names it from the key or the menu item and puts the old
  text back when the page prevents it; a composition (the soft keyboard's
  underlined word) stays the field's. Selection: EditText's, in Java's
  UTF-16 units. Checked against the Android WebView: the same events,
  types, data and values for typing, Backspace, Delete, Enter in a
  textarea, Ctrl+V, Ctrl+X and Ctrl+Z (Chromium also selects what an undo
  restores; Android leaves the caret). Apple too: macOS asks in the text
  field's `textView:shouldChangeTextInRange:replacementString:` (the field
  editor's delegate is the field: OrielNuiTextField overrides it) and the
  text view delegate's, iOS in `textField:shouldChange…` /
  `textView:shouldChange…`; the type from the key that made the edit
  (macOS: the current event; iOS: the last hardware key the field's
  presses had; the soft keyboard's are insertText and
  deleteContentBackward); marked text (an input method) stays the field's.
  A text area undoes (NSTextView allowsUndo). Selection: the field
  editor's or text view's `selectedRange` (macOS), UITextInput's
  `selectedTextRange` (iOS), while the field is edited. Checked against
  WKWebView: typing, Backspace, forward Delete, Option+Backspace, Cmd+Z,
  in an input and a textarea, and with beforeinput prevented for a
  character and a word delete (macOS: the same events, types, data,
  values and selections line for line; iOS: the same types), and
  setSelectionRange then typing over it (macOS). Not checked: paste and
  cut (the user's clipboard was left alone).

**Transform and opacity frames** (the "x" channel): a frame that changes
only elements' transform or opacity (an animation loop writing
`style.transform`, a transition) skips the flattener (render.js
updateBoxes) and goes to Zig as numbers, `host.paint(Float64Array)`
(Tree.applyPaint): entries of `[code, node id, count, count values]`,
one after another. Code 1: tx, ty, sc, rot, op (5 values, NaN for unset),
as the JSON op `["x", id, tx, ty, sc, rot, op]` that a host without
`paint` still gets. A reader skips an entry it doesn't know by its count,
so new codes (a 2D matrix's 6 values) can be added without breaking
older readers; give a new code its own number and value count. Backends
get each change through `Tree.on_paint`, as before. (GTK desktop, render
bench "animate 200 boxes": 72 → 82 fps with the numbers and updateBoxes
updating its props in place.)

**Gradient stops** (`bg.gradient`, each backend):

- `stops` are `[r, g, b, a, pos]`. With only percentages, `pos` is a
  fraction of the gradient line (missing ones already filled in) and
  there is no `su`. Otherwise `su` gives each stop's unit (`%` a
  fraction, `p` px, `a` none given, `c` a calc() with both: its fraction
  in `pos` and its px in `sp`, one number per stop, as
  `calc(100% - 20px)` is 1 and -20): call `Gradient.resolve(line, buf)`
  (tree.zig) with the line's length in px (a linear gradient's
  `|w sin a| + |h cos a|`, a radial one's x radius from `radialIn`).
- `rep`: repeating-linear-gradient / repeating-radial-gradient. resolve()
  then returns one period's stops (0..1 within it, phased so a period
  starts at the line's start) and `period` (its length as a fraction of
  the line): draw them with a wrapping gradient one period long (Win32:
  D2D1_EXTEND_MODE_WRAP, the linear brush's end point and the radial
  radii times `period`; Cairo: CAIRO_EXTEND_REPEAT). A backend whose
  gradients can't wrap (CoreGraphics) lays the period out with
  `Gradient.expand(resolved, extent, buf)` instead (extent: how much of
  the line to cover, in line lengths). Win32 does this, Apple
  (apple_draw.zig gradient: expand over the line, a radial one out to the
  box's farthest corner in ray lengths, at most 1024 stops) and Android
  (OrielNative.kt resolveStops, a port of resolve(); Shader.TileMode.REPEAT
  with the linear end point and the radial radius times `period`) and
  GTK (gtk.zig gradient: resolve() over the line, the linear end point or
  the radial unit circle times `period`, CAIRO_EXTEND_REPEAT). resolve() combines a
  `c` stop's parts, so Win32 and Apple have calc() stops; Android's
  resolveStops needs `sp` ported.

**Corner radii** (`br`, each backend):

- `br` is four corners (top-left, top-right, bottom-right, bottom-left),
  each one length (px, or `"N%"`) for both axes, or `[x, y]` when they
  differ: `border-radius: 50%` on a 120x80 box is `"50%"` (an ellipse
  60x40), `border-radius: 40px / 20px` is `[40, 20]` per corner, and a
  longhand's two values (`border-top-left-radius: 60px 20px`) the same.
  A backend reading a corner as one number sees an array there.
- Resolve with `Node.radiusXY()` (tree.zig): an x percentage is of the
  box's width, a y one of its height, and all corners are scaled down
  together until adjacent ones fit (CSS's overlap rule). A corner with
  either axis 0 is square. `Node.radius()` is a circular fallback (the
  smaller axis) for a backend that draws no ellipses yet.
- Draw every rounded shape with the ellipses: the background, the border
  (a uniform one stroked inset by half its width, each axis; uneven sides
  as the ring between the border box and `paddingBoxXY`), the children's
  clip (`Node.paddingClipXY()`: each inner x radius less the left or right
  border, y less the top or bottom), the outline and box-shadow (each
  rounded corner grown on both axes: `Radii.grown`). Win32, GTK
  (gtk.zig roundRectXY, roundedSides) and Apple (apple_draw.zig
  addEllipseRect, roundedSides: every solid rounded border is the filled
  ring, as WebKit draws it) and Android (OrielNative.kt radii(): the same
  resolution in Kotlin, as Path.addRoundRect's eight values; sides() with
  one wedge per run of same-colored sides) do all of these. Android also
  clips an `<img>` to its content edge's curve (each corner less the border
  and padding on its sides), as browsers clip a replaced element; the
  other backends clip it to its content box only.

**Inline boxes** (a run's `ib`, each backend): a padded, bordered or
rounded inline element amid the text (a `<code>` chip, a highlighted
`<span>`) stays runs (a row can't flow text around a box mid-line), and
render.js gives them its decoration: `ib = { k, p, m, bw?, bc, br?, bg? }`
(tree.zig InlineBox): `k` one per element (stable across renders; two
like chips side by side are two boxes), padding `p` and margins `m`
[top, right, bottom, left] px, border widths `bw` with one color `bc`,
circular corner radii `br` [tl, tr, br, bl] px, and its background `bg`
(no longer the runs' own `bg`). Consecutive runs with the same `k` are one
box. As browsers draw it (box-decoration-break: slice):

- The start side's margin, border and padding (`InlineBox.start()`) take
  room in the line before its first character, the end side's (`end()`)
  after its last; the vertical ones take none (they overflow the line).
- Over each line fragment of its text: the background, then the border,
  as tall as the font's content area (ascent and descent) plus the top
  and bottom padding and border; the start side (its border, padding and
  corners) only on its first fragment, the end side only on its last; a
  fragment that wraps stops at the line's text (not over the space it
  wraps after). Under the text.
- Apple (apple_draw.zig inlineBoxRoom, paintInlineBoxes): the room as
  CoreText kerning (on the character before the box and on its last one;
  a first-line indent for a box at the very start), the fragments from
  the glyphs' positions and advances. Checked against WKWebView (a chip in
  a sentence, one that wraps over two lines, a bordered one). GTK
  (gtk.zig boxRoom, paintInlineBoxes): the room as an invisible U+2061
  shaped that wide before the box's text and after it (it breaks as a
  letter, so the room stays with the text), the fragments from Pango's x
  ranges, the content area from the font's rounded ascent and descent on
  the line's baseline; checked against WebKitGTK (the same cases, and a
  `<mark>` with padding). Win32 (win32.zig inlineBoxRoom,
  paintInlineBoxes): the room as DirectWrite character spacing
  (IDWriteTextLayout1: leading on its first character, trailing on its
  last, with the letter-spacing), the fragments from HitTestTextRange per
  line around the line's baseline, on whole pixels; checked against
  WebView2 (chips in a sentence, a wrapped one, bordered, margined and
  rounded ones, on 1.6 lines, with letter-spacing). Android
  (OrielNative.kt inlineBox): the room as a word joiner (U+2060: no
  break) under a ReplacementSpan that wide before the box's first
  character and after its last, the fragments from the StaticLayout's
  selection path around each line's baseline; a run's own background (a
  `<mark>`) is drawn the same way, over the content area, not as a
  BackgroundColorSpan over the whole line box. Checked against the
  Android WebView (a chip in a sentence, one that wraps, a bordered span,
  `<mark>`, a padded highlight with margins that wraps).
- An inline box at a line's start or end is a node in the line's row
  (Baselines): render.js takes its vertical padding and border off its
  top and bottom margins, so they overflow the line, as an inline box's
  do, instead of making it taller.

**Baselines** (each backend): a line of inline content with boxes in it
(a code chip at a line's end, a button or checkbox beside its label) is a
row with `align-items: baseline`, its inline boxes on the row's baseline
(not placed by text-align). Yoga asks a text node for its first baseline
(tree.zig baselineFn): its top padding and border plus `Node.baseline`,
which the backend's measure sets (the first line box's half-leading plus
the ascent, as it places the line; Apple's measureText does), else an
estimate (0.9 em of ascent in a line box of `lh` or 1.2 em); a box's is
its first child's; an input's or select's, its one line of text centered
in its content box. Checked on Apple against WKWebView (a chip, a button,
a checkbox, an input, an inline-block chip in 24px). GTK's measuredText
sets it to the first line's extent's top, where paintText draws it (every
text with a line box is drawn line by line on CSS's baselines, not
Pango's, which sat 0.2 to 1.2px off); checked against WebKitGTK. Win32's
measure sets it where its uniform lines put the first (cssBaseline);
checked against WebView2 (a label, button, checkbox, input, select and a
28px span in one row, each pair alone, a chip after a 28px heading).
Android's measure sets it from the StaticLayout's first line
(getLineBaseline(0), or a plain line's style's one-character layout),
with each text's natural size in the measure batch, cached beside the
sizes; checked against the Android WebView (a code chip at a line's end,
a button and a checkbox beside labels, an input, a 24px inline-block
chip, a mixed-size line with a button). A box's baseline is
its first child's top plus that child's baseline; while Yoga sizes a row
it read the child's top from the box's previous layout (0 the first
time), so a button beside text made the row a few pixels taller than
WebKit's. build.zig patches Yoga's Baseline.cpp (patchedYogaBaseline,
like patchedYogaLayout: the build stops if Yoga's text changes) to take
the child's top from the box's top padding and border and how it places
the child (justify-content in a column, the child's alignment in a row);
tree.zig's test "a button beside text sits on the text's baseline on
the first layout" (29 without it, 28 as it should be).

**The app's CSP** (shared): the runtime keeps the WebView's rules for
compiling strings. When `security.csp`'s script directive (`script-src`,
else `default-src`) lacks `'unsafe-eval'` (Oriel's default), the page's
`eval` (direct and indirect), `new Function` and every other Function
constructor (`Function.prototype.constructor`, async and generator ones)
and a string given to `setTimeout`/`setInterval` are refused, with
WebKit's `EvalError` message (naming the directive) and the violation
logged as an error; `eval` of a non-string still returns it. Engine.create
decides (engine.zig `evalRefusal`) and the QuickJS context refuses it
itself (an Oriel hook in `JS_EvalObject`, quickjs.c
`JS_OrielSetEvalRefused`), so a page can't get around it by replacing
globals; the host's own `JS_Eval` (the runtime, page scripts) runs, and
the runtime compiles nothing from strings itself (render.js parses a
`calc()` of numbers: `arithmetic`). Inline event handlers (`onclick="…"`)
are compiled by the host (`host.compileHandler`), refused when the
directive has no `'unsafe-inline'` (or a nonce or hash turns it off), as
in the WebView. Nothing hands the page a way to run text: `__host` is
gone from the page's global object once the runtime has it, it has no
prototype (a getter on Object.prototype never sees it), and its text
runners (`evalScript`, `evalModule`, `compileHandler`) are kept in the
runtime's closure, off it; `__oriel` is a read-only, frozen global and
its `boot` (which runs the document's scripts) runs once. Checked
against WKWebView under the default CSP: the same EvalErrors, `eval(42)`,
no string timer, no inline handler; engine.zig's test covers both a
refusing and an allowing CSP.

**Screen scale** (each backend): `platform.dpr` in the platform JSON,
the screen's pixels per CSS px, read as a window opens (Apple: the main
screen's backing scale / UIScreen's scale; GTK: the scale factor; Win32:
DPI / 96; Android: the density). main.js makes it `devicePixelRatio` and
answers `resolution`, `min-resolution`, `max-resolution` (dppx, x, dpi,
dpcm) and `-webkit-min-device-pixel-ratio` queries with it; without one
it's 1. Apple passes it (checked against WKWebView: 1 on a 1x Mac, 3 on
an iPhone); the others add theirs. When a window goes to a screen with
another scale, the backend sends `Engine.event(0, "dpr", scale)`:
devicePixelRatio follows and resolution queries' `change` listeners fire
(macOS: the view's viewDidChangeBackingProperties). `document.documentElement`'s
clientWidth and clientHeight are the viewport's, as in browsers.

**Mixed-font line boxes** (each backend): with `line-height: normal`
(no `lh`), a line's box stacks every inline box on it on the baseline,
the block's own font (the strut, its `fz`/`ff`/`mono`) among them: each
font's normal line box (ascent + descent + gap, rounded as the backend's
WebView rounds them) with half its leading above the ascent; the line is
as tall as the most above plus the most below, and the text as tall as
its lines' sum. A 28px span on one line of four makes only that line
taller (WKWebView: 68, not 4 × 32 or 96); a 13px code chip in 16px text
changes nothing. With an explicit `lh` every line stays that tall (the
props carry it in px, not as the factor a `line-height: 1.5` is for each
inline box, and WebKit's lines came out uniform). Win32 (lineExtents,
lineShift: each line drawn where its own box puts it) and Apple
(apple_draw.zig linePlaces: each line's glyph runs' fonts and the strut;
the places kept with the frame; lineOrigin, the measured height and
`Node.baseline` use them) do this; checked against WKWebView on ten
paragraphs (bold, a link, a 20px span, code, code on one line of three,
small, line-height 1.5 with code, a 28px span on one line of four, serif
with code): every paragraph's top and height the same.


**Text metrics** (each backend, to match its own WebView):

- Android: text paints are linear with subpixel positions (TEXT_FLAGS in
  OrielNative.kt, and canvas text): the canvas is in dp, and without them
  Android hints glyph advances at that small size (13.33px Roboto came out
  7 px short over a sentence, 12px 3 px long). A text's width goes to Yoga
  to 1/64 px, as Chrome keeps it, not rounded up and 1 px more; the layout
  drawn is a whole px wider so it doesn't wrap. Widths now match the
  Android WebView's within Yoga's rounding (10 to 32px, bold, monospace).

- `line-height: normal` (no `lh` in the props; the UA sheet sets none) is
  the font's ascent + descent + line gap, each rounded to whole pixels, as
  WebKit and Chromium make it (Noto Sans at 16px: 17 + 5 + 0 = 22; at
  36px: 49). Use the font's own unhinted metrics (GTK: Pango with
  hint-metrics off; DirectWrite's font metrics; CoreText's ascent, descent
  and leading; Android's `Paint.FontMetrics`), not the text engine's
  default line spacing, which may differ (Pango's own lines are 23 at
  16px). A text node is lines × that tall, the glyphs centered in each
  line box.
- An explicit `lh` is a line box exactly that tall (glyphs centered and
  overflowing when it's shorter than the font): Pango keeps lines no
  shorter than its own minimum, so GTK sizes and centers them itself.
  WebKit (WebKitGTK, WKWebView) keeps a computed line-height in whole
  pixels (145% of 16px is 23); Chromium (WebView2) keeps the fraction: GTK
  floors `lh`, as its WebView does.
- Fonts of different sizes in one text (a `<code>`, a 28px `<span>`): each
  run's inline box is its font's rounded ascent and descent plus the
  leading of its line-height (a run's own `lh`, render.js: a unitless
  line-height times the run's size, else the text's), or of its line gap
  when normal, split with the smaller half above. Every line also has the
  strut (the text's own font and `lh`). A line box reaches the highest top
  and the lowest bottom of the boxes on it, so only the lines with the
  bigger font are taller (WebKitGTK, measured: a 28px span on one of four
  16px lines makes 22 + 38 + 22 + 22). GTK (lineExtents) and Win32
  (lineExtents) stack each line on its own baseline.
- `ff` on text props and runs, always: the CSS font-family list,
  unquoted, comma-separated, or `default` when the page sets none (a CSS
  keyword, never a family's name). Resolve a list as browsers do: the first
  family installed, or the first generic name (`serif`, `sans-serif`,
  `monospace`, `system-ui`, `ui-*`); don't hand the whole list to the font
  matcher (fontconfig lets a real family later in it beat the `system-ui`
  alias). `default` is the WebView's own default face: WebKitGTK's is
  sans-serif (its default-font-family setting; GTK maps it so), Chromium
  (WebView2) and WKWebView use Times. Win32: the first installed name, or
  Chromium's generic families on Windows (system-ui Segoe UI, sans-serif
  Arial, serif Times New Roman, monospace Consolas). Form controls are
  `-webkit-small-control, system-ui` (UA_CSS; a textarea `monospace`), as
  Chromium draws them: in the platform's control font, which is Arial on
  Windows (Win32 maps the name so); a backend that doesn't know the name
  takes the `system-ui` after it. On Linux the WebView is WebKitGTK, and
  its controls are WebKit's in the GTK theme (measured): render.js
  uaCssWebkitGtk, with `platform.uiFont` (gtk-font-name's family and size,
  floored to whole px: Adwaita Sans 11pt is 14px) on every control, a 1px
  `#cdcdcd` border rounded 5px, white text fields and `#f4f4f4`
  buttons and selects, 12px checkboxes, 20px sliders, and
  `platform.accent` (the theme's `accent_bg_color`) as their
  `accent-color`. GTK sizes fields as WebKit does (gtk.zig fieldSize): a
  text field `size` (20) digit widths and 6px, a textarea `cols` digits by
  `rows` lines, a select its longest option and its arrow, a line the
  font's normal height (`Tree.fields_sized`: measureFn keeps a textarea's
  width). On macOS a `<button>` is WKWebView's (measured; render.js
  UA_CSS_MAC and pushButton): while the page leaves its background,
  border and `appearance` alone, AppKit's push button — no border
  (WebKit's computed one is 0), padding `2px 6px 3px` plus the bezel's
  2px a side, white with 4px corners and a hairline edge (the default
  11px label: 18px tall); otherwise the CSS box on
  ButtonFace (rgb(192, 192, 192)), its outset border darkened on the
  bottom and right as WebKit's Color::dark (inset: top and left; on every
  platform). WebKit draws a tall button (a 20px font) as a square bevel
  button; Oriel keeps the push button. iOS buttons keep UA_CSS_WEBKIT's.
- `Backend.font_metrics` (host.fontMetrics): `[ascent, descent, lineGap]`
  in px, unhinted, for the default sans (or monospace) at a size; the
  runtime uses it for an image's line (the baseline gap below an inline
  image). Without it, Noto Sans's proportions.
- Yoga rounds a text node's width up (it mustn't wrap) but its top and
  height to the nearest pixel, as browsers' line boxes are
  (src/native_ui/yoga/PixelGrid.cpp).
- In a row that wraps (`flex-wrap`), Yoga put an item aligned to the start
  of its line at the line's top, its leading margin lost, and centered
  items without their margins; build.zig (patchedYogaLayout) compiles
  Yoga's CalculateLayout.cpp with both fixed, and stops if Yoga's text
  changes.

**Outline** (`ol` in a node's props, sent only when it has one: a style
other than none/hidden, a width above 0 and a visible color):
`{ w, c, o?, s? }`: width in px, color `[r, g, b, a]` (currentColor
resolved), `o` the outline-offset in px (absent: 0; may be negative), `s`
`"dashed"` or `"dotted"` (absent: solid; `auto` and the 3D styles draw
solid). A backend draws it as a border of its own around the border box
grown by `o + w` on every side, its corner radii the box's grown as much
(a square corner stays square), with the node's transform and opacity but
outside its own overflow clip, after its content and children, taking no
room in the layout. GTK: `outline()` in gtk.zig (it reuses the border and
dashed-border drawing). `:focus-visible` matches as in browsers: focus
that came by the keyboard (a key was the last input, or there was no
pointer press yet), or a text field (input of a text type, textarea,
contenteditable) however it got focus.

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

## Native bridge performance

Input events, timer callbacks, display frames and renderer calls use typed
QuickJS calls rather than formatting and compiling JavaScript source on
each call. Argument values and the `__oriel` receiver are preserved; promise
jobs and rendering still settle at the end of the outermost call.

Run the bridge correctness checks and microbenchmark on a POSIX host:

```sh
zig build test-native-dispatch
```

The benchmark compares source evaluation with direct calls to the same
small functions. It excludes DOM updates, layout and drawing. A Linux
x86_64 run showed roughly 92–96% less bridge time for events, vsync and
render calls. That is a reduction in bridge overhead, not an equivalent
improvement in frame time or a measurement of battery consumption.

The full render-bench and Breakout comparison did not show a clear
end-to-end gain: row timings and memory were similar; a 500-ball JS game
on the 180 Hz desktop measured 138.3 versus 139.0 fps, with essentially
unchanged process CPU. The virtual-display animation tests hit their
60 Hz limit. See the [measurements and limitations](../examples/render-bench/results/2026-10-04-native-dispatch-desktop.json).

Repeating timers that cancel themselves no longer post an extra native
timeout. Active intervals keep their cadence (callback time is deducted
from the next delay) and continue after a callback exception. The runtime
tests cover cancellation, exceptions, arguments and interval timing:

```sh
cd src/native_ui/js
npm test
```

## Pointer and key events

A backend reports the pointer through one engine event, `"pointer"`, on the
node under it (0 for none), with the data
`[phase, x, y, buttons, pointerId, pointerType, modifiers]`:

| Field | Value |
|---|---|
| `phase` | `"down"`, `"move"`, `"up"` or `"cancel"` (the system took the gesture: a scroll) |
| `x`, `y` | the view's coordinates in CSS px (the page's `clientX`/`clientY`) |
| `buttons` | pressed buttons as in the DOM (1: primary); 0 for a hover move and on up |
| `pointerId` | 1 for the mouse or the one touch |
| `pointerType` | `"mouse"`, `"touch"` or `"pen"` |
| `modifiers` | shift 1, control 2, alt 4, meta 8 |

The page (`main.js`, `pointerEvent`) dispatches `pointerdown`/`move`/`up`/`cancel`
and then `mousedown`/`move`/`up` (a mouse) or `touchstart`/`move`/`end`/`cancel` (a
touch, with `touches` and `changedTouches`), bubbling to the window. The element a
pointer went down on gets that pointer's moves and its up wherever they happen
(implicit capture, as browsers do for touch; `setPointerCapture` moves it,
`releasePointerCapture` drops it). The backend's own `"click"` still follows the
up, and gets the up's coordinates.

On `"down"` the event's result says whether the page takes the drag: true
when a listener prevented the default, or the element or an ancestor has
`touch-action: none` (or `pinch-zoom`). Then the backend doesn't scroll, fling
or long-press for that touch. Otherwise, when it starts a scroll, it sends
`"cancel"`.

Moves go at most once per display frame: the backend keeps the latest one and
sends it at the next frame, before the page's animation frame (a backend
without a display link sends them as they come). Hover (`"hover"`, the node
under the pointer for `:hover` and `mouseover`/`mouseenter`) works as before.

Keys: `"key"` with `[key, modifiers, repeat]` (`keydown`, `event.repeat` set on
auto-repeat) and `"keyup"` with `[key, modifiers]`. A `keydown` the page
lets through is followed by `keypress` for a character or Enter (never
with Control); WebKit's also for Escape, and on macOS with Command
(measured). A prevented `keypress` uses the key too.

Apple (measured against WKWebView, typing ab, Enter, Escape, Cmd+A and
ArrowLeft into an input and a textarea, and into an input that prevents
b, Enter, Cmd+A and ArrowLeft): a native field's keys reach the page,
on the field, before the field acts on them, and a prevented keydown
never reaches it (no character, no caret move, no select-all). Shift,
Control, Option and Command have their own keydown and keyup. No keyup
for a key let go while Command is down (WebKit fires none). While an
input method composes (marked text) its keys are the field's alone: the
page hears none of them (not measured: an input method here needs a system
setting changed). macOS: a local
event monitor (key down, key up, flags changed) on the window's first
responder, the page's view or a field's (its field editor's delegate).
iOS: the fields' own presses (subclasses of UITextField and UITextView),
key up 10 ms after UIKit's (it types the character a little after the
press, and the page hears input before keyup, as in WebKit), and the
page view passes a field's presses on through UIView's own.

A press focuses what it's on, as a browser's mousedown does (main.js
pressFocus): the nearest focusable element from its target up, so a press
in a field's padding or border (outside its native control) focuses the
field too; on nothing focusable the focus leaves. A mouse or pen on its
`"down"` when the page didn't prevent it; a touch at its tap, before the
click (a scroll that starts on a field doesn't focus it). On macOS and iOS
a press focuses no button, link or checkbox (WebKit's), and a label leaves
it to its click.

A text field's `change` comes from main.js, as browsers fire it: on blur
(before `blur`) and on Enter in a one-line field (after Chromium's
`beforeinput` `insertLineBreak`, before the form's submit), when the user
edited it (an `"input"` from the backend) and its value differs from the
one at focus or at the last change. A script's value fires nothing.
Backends send `"change"` only for sliders and selects.

Focus: a native field that gets or loses the keyboard sends `"focus"` or
`"blur"` (data `null`) on its node. The page then sets `:focus` and
`document.activeElement`, and fires `blur` and `focusout` on the old
element and `focus` and `focusin` on the new one, as browsers do;
`element.focus()` does the same. GTK: a focus controller on each field
(nothing is sent while a field is being removed). Android sends them
too; each backend must, or `:focus` never matches on its fields.

Tab: a `"key"` Tab (Shift+Tab back) that the page doesn't prevent moves
the focus as browsers order it: positive `tabindex` first (ascending, then
document order), then the rest in document order; links with `href`,
enabled form controls, `<summary>` in `<details>`, contenteditable and
`tabindex >= 0`, if shown (not `display: none` or `visibility: hidden`);
it wraps at the ends. The element focused is scrolled into view
(`block: "nearest"`) and matches `:focus-visible`, which draws browsers'
focus ring unless the page styles its outline: the platform's browser's
(`setFocusRingOS` in render.js). WebKitGTK's (Linux) is 2 px in
`platform.accent` at 0.8 alpha (WebKit's blue without one), over a
control's border (offset -2, 5px corners), just outside a link or another
box (offset 1); Chromium's (Windows, Android) 2 px near-black (Android:
orange) in a white halo; WKWebView's (measured) the system blue at half
alpha, 4 px on macOS and 3 px on iOS, just off a box or link and over a
control's edge. Outlines take `r`, a least outer corner radius, and `h`, a
1 px halo colour. Before any pointer input a script's `focus()` is
visible too, as in browsers. An inline element has no box of its own: its
outline (the page's, or the focus ring of a link with `:focus-visible`)
is set on its text runs (Run `ol`), and the backend draws it around each
line fragment of them (GTK: runRing, one box per line, the spaces where a
line wraps left out; Win32 and Android (OrielNative.kt runRing: the
StaticLayout's selection path per line, merged with Path.op) one outline
around a wrapped link's boxes, as Chromium); a backend that doesn't read `ol` on runs draws no
ring on an inline link.
Backends must give Tab to the page, also while a native field has the
keyboard, and not move the focus themselves when the page used the key;
when the page focuses an element that isn't a native field, the keyboard
goes to the page's view. GTK: a capture-phase key controller on the
overlay sends a field's keys to the page first (below).

On Apple platforms Tab visits what WKWebView's does (measured): on macOS
without Full Keyboard Access (the system's keyboard navigation setting,
off by default; `platform.fullKeyboardAccess`, read as a window opens)
only text fields, selects, textareas and contenteditable, plus anything
with an explicit `tabindex >= 0` (a button or link without one is
skipped); with Full Keyboard Access, every control, as above. On iOS the
same as macOS's default, but a `tabindex` doesn't bring in a button,
checkbox or range. WKWebView on iOS moves nothing on a hardware Tab while
nothing has focus; here the first Tab focuses the first element (more
useful than doing nothing). macOS takes Tab from AppKit's key-view loop
in a local event monitor; iOS from the page view's presses and a Tab key
command.

Backends: macOS (mouse moves, drags, buttons; key up from a local event monitor,
AppKit not sending `keyUp:` to the page's view) and iOS (one touch; a drag the
page doesn't take scrolls as before), GTK (mouse moves, drags and buttons;
moves coalesced on the frame clock; keyup from the key controller, repeat
from the keys held; while a native field has the keyboard, the overlay's
capture-phase key controller sends its keydown and keyup on the field
first, and a prevented keydown never reaches it; modifier keys are keys
of their own, their flag set on their keydown), Android (one touch, or the mouse on ChromeOS with its
buttons and hover moves; a touch the page doesn't take scrolls as before and
gets a cancel, a mouse drag doesn't scroll; moves coalesced on
Choreographer's frame; keydown with repeat and keyup from the page's view).
Windows (the mouse's buttons, moves and drags, the window capturing the
mouse while a button is down; one touch or pen through WM_POINTER, a touch
the page doesn't take scrolls and gets a cancel, a pen also hovers; moves
coalesced on the display frame; keydown with repeat from lParam's bit 30,
keyup with the key its keydown sent, a typed character's too).

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

A path of many whole circles (a game's balls, eight or more in one path)
filled nonzero in an opaque color is drawn circle by circle, which gives
the same pixels (win32.zig and apple_draw.zig fillCircles, OrielCanvas.kt
fillCircles): one path of hundreds of circles was most of Breakout's frame
at 500 balls (Android emulator, JS mode: 20 → 55 fps). Android also makes such
a path's curves only when something needs them (a fill that isn't of
circles, a stroke, a clip, another kind of segment): its replay at 500
balls went from 4.9 to 3.1 ms a frame.

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

   Not yet: color emoji inside the fields (RichEdit 5, kept for its
   multi-level undo, draws them as outlines: msftedit registers no D2D
   class here and TO_DISPLAYFONTCOLOR has no effect), owner-drawn selects (a COMBOBOX keeps the system look), IME
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
Colors are sRGB, as CSS's: every fill, stroke, gradient, text color and
canvas bitmap is in the sRGB color space (not the device's, whose values
would reach a wide-gamut display unmatched), and a macOS window's backing
store is sRGB too, so translucent colors blend in sRGB as WebKit's layers
do (checked against WKWebView pixel for pixel: opaque and half-alpha
swatches, a gradient, text, a border and a canvas fill). A rounded border
whose sides differ in width is the ring between the border box and the
padding box (elliptical inner corners), each color clipped to its wedge
and neighboring sides of one color sharing one, as on GTK (`roundedSides`).
An inline link's ring (a run's `ol`) is a box per line its text is on
(`paintRunRings`: spaces at the line's ends left out, its runs under one
box), as tall as the font's content area, as WebKit draws it even in a
taller line box. An `<img>` is clipped to its content edge's curve.

| | macOS (AppKit) | iOS (UIKit) |
|---|---|---|
| The page | one flipped NSView, the window's content view | one UIView in the controller's safe area, like a web view |
| `input` / `textarea` / `select` | NSTextField (NSSecureTextField), NSTextView in an NSScrollView, NSPopUpButton | UITextField, UITextView, a UIButton with a UIMenu |
| `input type=range` | NSSlider (`accent-color` tints the track) | UISlider |
| Input | clicks; the right, middle, back and forward buttons as pointer downs and ups (`buttons` from `pressedMouseButtons`), `contextmenu` on the right button's press or a Control-click's (button 0, buttons 1, with `ctrlKey`; its click still follows), `auxclick` after a non-primary release, all in WKWebView's order (measured); hover and the hand cursor, the scroll wheel and trackpad, keys | taps, long presses (`contextmenu`), drags with a fling (gesture recognizers) |
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
| A display frame (`nuiRequestFrame` → `displayFrame`) | While the visible page wants animation frames: one reused `Choreographer` callback per frame at the display's rate (120 on a 120 Hz phone), none while hidden or when it stops |

Display callbacks suspend when the view or its window becomes hidden or
detached. The pending request stays intact and resumes on visibility or
reattachment, so an app need not restart its animation loop. This suspends
display-driven animation and Zig frame hooks; it does not suspend JavaScript
timers or background services. Android emulator render-bench checks observed
480 frame-counter increments during eight hidden seconds before the change,
none after it, and rendering resumed on reopening.
[Scheduling checks and desktop stage timings](../examples/render-bench/results/2026-10-04-android-background-frames.json).

The page's CSS px are Chromium's: the view's width in DIPs rounded up to
whole px (1080 px at density 2.625 is 412 CSS px, not 411.43), the page
scaled to fit (`Nui.cssScale`), so `innerWidth`, media queries and what
fits in a row match the WebView's.

Windows does the same at fractional scales: the client area in whole CSS
px rounded up (784 px at 125% is 628, at 150% 523), drawn at the monitor's
scale (the last fraction of a px cut, as WebView2 does).
`document.documentElement.clientWidth`/`clientHeight` are the viewport's,
on every backend. `ORIEL_NUI_SCALE=1.25` (testing) forces a scale on
Win32, as `--force-device-scale-factor=1.25` does for WebView2 (through
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`).

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
