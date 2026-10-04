# Changelog

Notable changes in Oriel releases.

## [0.9.0] — 2026-10-04

Oriel 0.9.0 lets apps react to notification clicks and buttons.

### Added

- Notification click actions: `oriel.notification.notify` takes `.actions`
  (buttons), and clicks on a notification or one of its buttons reach
  `oriel.notification.onAction(handler)` in Zig and the page's
  `notification:action` event as `{ id, action }` (`action` is null when the
  notification itself was clicked).
  - Linux: GNotification default action and buttons.
  - macOS (`.app` bundles) and iOS: `UNNotificationCategory` buttons and the
    notification center delegate.
  - Android: a tap opens the app and reports the click, also when it
    launches the app; buttons (at most 3) report theirs without opening the
    app and dismiss the notification.
  - Windows: a click on the balloon is reported; balloons have no buttons.
- The showcase's Notify button sends a notification with Like and Later
  buttons and shows which one was clicked.

## [0.8.0] — 2026-10-04

Oriel 0.8.0 introduces the optional, experimental native UI renderer as a
release-ready build mode alongside the default system WebView. The same app
HTML, CSS and JavaScript run in QuickJS and draw through Oriel's native
platform backends.

### Added

- Build apps with `-Dnative_ui` on Linux, Windows, macOS, Android and iOS.
- Forward Zig `-D` build options through `oriel android dev/build` and
  `oriel ios dev/build`; explicit options replace CLI defaults. For example:
  `oriel android build --abi arm64 --apk -Dnative_ui -Doptimize=ReleaseFast`.
- Android native renderer example projects for Breakout, Canvas Demo and the
  render bench.
- Render-bench power sampling on supported Android devices and Linux battery
  or RAPL sources, with instructions to compare against the WebView build.

### Improved

- Android stops scheduling native `requestAnimationFrame` callbacks while a
  window is hidden, then resumes pending frames when it becomes visible.
- Android native UI text metrics, controls, baseline alignment, scroll and
  input behavior more closely match the platform WebView. Slider thumbs remain
  fully visible at either endpoint.
- Native canvas drawing records values directly and sends transform and
  opacity changes without rebuilding the entire page tree.
- Native renderer line layout, inline decorations, SVG styles, gradients,
  scrolling and DOM cleanup are more consistent across platforms.
- QuickJS bridge callbacks use typed dispatch paths for native events,
  timers and frames. This reduces isolated callback overhead; current desktop
  end-to-end measurements do not show a clear overall speedup.
- Breakout caps long-run ball speed so physics work stays bounded, and its Zig
  mode responds to the ball-count setting.
- Android type checks use the selected NDK's libc headers when available.

### Notes

- The native renderer remains experimental and supports a subset of browser
  HTML, CSS and APIs. The default WebView build remains available.
- Android emulator benchmarks reach about 60 fps in the built-in workloads.
  There is no Android before/after comparison in this release, and the emulator
  run does not establish battery savings.
- iOS native UI code builds through the existing UIKit backend and remains
  experimental; physical-device verification depends on the app and Apple SDK.
