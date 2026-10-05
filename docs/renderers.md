# WebView and native rendering

[Back to Oriel](../README.md) · [Documentation](README.md)

## Native renderer (experimental)

Build with `-Dnative_ui` and the app's HTML, CSS and JavaScript are drawn
with native views instead of a WebView: QuickJS runs the page, Oriel's own
native DOM (a Zig document store) holds it, Yoga lays it out, and GTK 4,
Direct2D, AppKit, UIKit or Android views draw it. There is no browser
process. On a Linux desktop it beats the WebView on every test of the
render bench: 1000 rows built in 6.4 ms (the WebView: 20) and updated in
2.8 ms (9), the first frame in 69 ms (431), animation at the display's
refresh rate (165 fps on a 180 Hz screen, against 62), and 174 MB after
the tests (561). On a 120 Hz Android phone it builds 1000 rows in 13.8 ms,
ten times faster than the same rows as plain Android views (132), and
draws 1000 canvas balls at 91 fps from JavaScript and at the display's
120 fps from Zig. Videos of both renderers running the bench are on the
site. Pages are laid out as in a browser: `box-sizing`, `calc()` sizes,
rounded `overflow: hidden`, CSS line boxes, and pointer and key events on
every platform. Mixed-font lines and inline decorations keep their baselines,
SVG files honor their own styles, and fields on Windows, Android and Apple
platforms send `beforeinput`, input types and selection changes.
`-Dnative_dom=false` builds it on linkedom
instead. The performance numbers above are dated runs, not a guarantee for
every page; the [render bench](../examples/render-bench) records the conditions.

Details, numbers on every platform and a comparison with React Native:
[the native renderer page](https://highercomve.github.io/Oriel/docs/native-renderer/),
[`docs/native-renderer.md`](../docs/native-renderer.md) and
[`docs/native-dom.md`](../docs/native-dom.md).

## Native UI in 0.8.0

Oriel 0.8.0 adds the optional, experimental native UI renderer. Add
`-Dnative_ui` to an app build to render its HTML, CSS and JavaScript with
QuickJS and platform views instead of a WebView. Android and iOS `oriel dev`
and `oriel build` commands now forward Zig `-D` options, including
`-Dnative_ui`. See the [native renderer guide](https://highercomve.github.io/Oriel/docs/native-renderer/) and the [0.8.0 changelog](../CHANGELOG.md).

- **Two renderers, one frontend:** the system WebView or `-Dnative_ui`, with
  QuickJS, a DOM written in Zig, Yoga layout and drawing on all five platforms.
  React, Vue, Svelte, Preact and CSS-in-JS apps run on the native renderer;
  Alpine needs its CSP build or an explicit `unsafe-eval` policy.
- **Closer to the platform WebView:** mixed-font line boxes, baseline alignment,
  padded and bordered inline text, SVG styles, native field editing and scroll
  events. Android now uses fractional text widths and WebView-sized controls;
  macOS keeps the default AppKit button appearance until CSS customizes it.
- **Canvas and animation:** draw from JavaScript or Zig (`oriel.canvas`), with
  numeric canvas recording and transform/opacity updates that skip flattening.
  Breakout compares both with the WebView; the render bench also measures
  power on Android and Linux where battery or RAPL readings are available.
- **Native CSP enforcement:** QuickJS refuses `eval`, Function constructors
  and string timers when the app's policy disallows them.

The native renderer remains experimental: accessibility, full CSS grid,
shadow DOM and several browser APIs are still missing. See the
[support and limits](https://highercomve.github.io/Oriel/docs/native-renderer/).
