# Changelog

Notable changes in Oriel releases.

## [0.9.3] — 2026-10-05

- Android templates and examples now compile and target API 36, meeting the
  current Google Play target requirement. Updated AGP to 8.9.3 and generated
  Gradle wrappers to 8.14.3; minimum Gradle is 8.11.1. Android 10 remains supported.

## [0.9.2] — 2026-10-05

Oriel 0.9.2 lets a page find out where a dropped file lives now, so a handler
can send it on to the system.

### Added

- `oriel.drop.path(file)` for native-renderer pages: where a dropped file lives
  now, for a handler that forwards it (a transfer engine opens the path). The
  `File` a drop delivers carries an opaque `handle`; the answer is a path
  string, or `null` when the file was deleted or changed since the drop, the
  handle is unknown, or the platform can't resolve paths. The Linux and Windows
  native bridges answer it after the command policy check; a WebView page has
  no handles and no `drop:path`. Electron's `webUtils.getPathForFile` is the
  precedent. See `docs/drag-and-drop-design.md`.

## [0.9.1] — 2026-10-05

Oriel 0.9.1 adds system sharing, persistent folder access and service discovery,
and improves native controls, accessibility and platform integration.

### Added

- `oriel.network.mdns` service registration and browsing, with Android's
  NsdManager backend and the `oriel_mdns_*` C ABI for native libraries.
- System sharing APIs for sending content, receiving shared files and reading
  received files from pages, with platform capability reporting.
- Folder picking with lasting write access, including Android's Storage Access
  Framework and iOS folder access.
- `oriel.system.deviceName()` to read the name the user gave their device.
- Bluetooth and local-network permissions, per-platform permission extras,
  and support for app-owned Android Kotlin/Java sources and R8 rules.
- Optional Windows MSIX packaging and packaged Share Target support.
- Native push buttons, checkboxes and radio controls across supported backends;
  Apple accessibility trees for VoiceOver and macOS assistive technology.
- Native renderer forced-colors support, CSS system colors and contrast media
  queries, including Windows high-contrast settings.
- Windows native-renderer drag and drop, context menus and pointer handling.

### Improved

- Native controls follow dark mode and system accent changes, with improved
  keyboard behavior, read-only fields and accessible names.
- Windows 11 field styling, typography and overlay scrollbars.
- Native text layout, inline geometry, baselines, lists, fieldsets and borders
  across Linux, Windows, macOS, Android and iOS.
- Events received before page listeners are ready are queued for delivery.

### Fixed

- Android mDNS resolution no longer crashes while encoding services with
  multiple TXT attributes. Attributes are iterated directly rather than copied
  through Android ArrayMap's unsupported entry-set `toArray()` method.
- Windows packages fail clearly when WebView2Loader.dll is missing.
- Windows sharing preserves existing OpenWithProgids registrations.
- Native controls avoid spurious radio changes, clipped select controls and
  accidental button taps while scrolling on iOS.

## [0.9.0] — 2026-10-04

Oriel 0.9.0 lets apps react to notification clicks and buttons, brings
drag and drop to the native renderer, and closes desktop input gaps for
ChromeOS and desktop Android. Windows support for these lands in 0.9.1.

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
- Drag and drop into native-renderer pages (`-Dnative_ui`) on Linux,
  Android and macOS: `DragEvent`, `DataTransfer`, `Blob`, `File`,
  `FileReader` and `FileList`. Dropped files are opened read-only when they
  are dropped and read asynchronously; the page never sees their paths. See
  `docs/drag-and-drop-design.md`.
- The page's `<meta name="theme-color">` is reported to its window in both
  renderers; on ChromeOS and desktop Android it colours the window's caption.
- Native renderer on Android: a mouse right-click opens the page's context
  menu, and the pointer shows a hand over clickable elements (links amid text
  included) and an I-beam over text fields.

### Improved

- Native renderer mouse events report the changed `button` (2 for the
  secondary, 1 for the middle button), fire `auxclick` after a non-primary
  release, and give a mouse's `contextmenu` button 2. macOS sends right,
  middle and other buttons as WKWebView does.
- Links and other clickable elements inside a line of text take their own
  clicks in the native renderer.
- Native renderer border widths snap to device pixels as each platform's
  browser does; key scrolling glides like WKWebView's; `scrollWidth` matches
  WebKit's horizontal range.
- Android: `white-space: pre` text keeps its line breaks.

### Security

- A file dropped on a text field no longer inserts its absolute path: native
  fields leave drops to the page, and in WebView mode the bridge cancels
  WebKit's default for a file dropped on an unhandled field.

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
