# Changelog

Notable changes in Oriel releases.

## [0.9.7] — 2026-10-08

Oriel 0.9.7 adds opt-in offline text-to-speech with Kokoro-82M and
built-in PCM playback.

### Added

- `oriel.kokoro`: typed C-ABI bindings for model initialization, voice loading,
  language selection, synthesis, error reporting and PCM cleanup.
- `oriel.audio_play`: mono float32 playback through miniaudio, with progress,
  natural-completion callbacks, stop/shutdown, and `finished()` polling.
- Enable TTS with `.kokoro = true` alongside `.llama = true` or `.whisper = true`.
  Kokoro shares Oriel's GGML build and adds espeak-ng phonemization and Highway
  SIMD. Apps supply model/voice GGUF files and compatible espeak-ng runtime data.
- `AppOptions.include_paths` forwards app-owned C include directories to desktop,
  iOS, Android and TypeScript-generation root modules.
- Repository and website guides for offline speech synthesis, asset setup,
  playback ownership, callback behavior and dependency notices.

### Fixed

- Playback teardown detaches sample state before joining the device thread,
  preventing stop/start deadlocks with audio callbacks.
- Lifecycle operations are serialized; stop and finished are safe before
  initialization, and stopped/completed audio buffers are filled with silence.
- Playback implementation and Zig declarations use the same vendored header,
  including whisper-only TTS builds and coexistence with llama's mtmd audio code.
- Optional TTS dependencies are downloaded lazily, keeping default builds lean.
- Invalid synthesis output is rejected before converting C sample counts/rates.
- macOS TTS builds use espeak-ng's upstream endian compatibility header.

### Validation and dependencies

- TTS-enabled tests exercise ABI defaults, PCM buffer completion, and repeated
  start/stop against miniaudio's silent null backend. Linux CPU synthesis is
  verified with the local Kokoro Q8_0 model and English voice pack.
- Release CI enables TTS tests on Linux and macOS in addition to the existing
  framework, CLI, Windows and iOS checks. GPU synthesis and physical audio-device
  behavior are not claimed as verified across every platform.
- The optional TTS stack includes espeak-ng (GPL-3.0-or-later). Oriel's framework
  remains MIT; upstream component license texts are included in `NOTICE` and
  `licenses/tts`. Model assets are supplied separately by apps.

## [0.9.6] — Not released

The macOS TTS build did not pass; v0.9.7 includes the portability fix.

## [0.9.5] — 2026-10-08

Oriel 0.9.5 fixes the validated concurrency, memory-lifetime and security
issues from `REVIEW.md`, and documents which reported findings were not
supported by the current code.

### Fixed

- File-handle tables synchronize access through reads and descriptor
  duplication, preventing release from recycling a descriptor in use.
- Worker-pool shutdown withdraws the pool, waits for borrowed references,
  drains accepted jobs, and rejects later submissions without leaking them.
- Async command errors retain their own text until the UI consumes the reply.
- Lazy window creation snapshots registered options before releasing the lock.
- Cross-window `emitTo` now checks the same modification permission as other
  window mutations. Smoke and Showcase explicitly opt into cross-window events.
- Isolation frames validate message origins and send replies only to explicit
  local origins; the Windows/Android bridge skips subframes.
- iOS Inbox cleanup only removes canonical files directly inside the app's own
  Inbox, using directory-relative deletion.
- Gzip update expansion is capped at 512 MiB in memory, on disk, and during
  macOS bundle verification/extraction. Expiring manifests reject invalid clocks.
- Windows media streams serialize Read and Seek and advance by actual bytes read.
- The local media server validates loopback Host headers on every route and
  scopes its ping response's CORS header to the configured app origin.
- Zig model downloads require HTTPS on initial URLs and redirects.
- Share-read and dev-server allocation failures release intermediate buffers;
  internal window and received-file cleanup consistently follows its allocator.

### Documentation and validation

- Added the website's **Wrap a web app** guide and navigation links.
- Validated every finding in `REVIEW.md`, correcting ownership, tar extraction,
  token exposure, command-line reader, and optional expiration claims.
- Added regression tests for concurrency, error lifetimes, window permissions,
  path guards, Host validation, HTTPS URLs, gzip limits, and isolation messages.

### Compatibility

- Cross-window events require
  `security.window_api.allow_modify_other_windows = true`.
- `App.getWorkerPool()` borrows must be paired with `App.releaseWorkerPool()`;
  `ThreadPool.post()` returns whether it accepted ownership of a task.
- Publishers must keep expanded gzip update payloads within the 512 MiB limit.

## [0.9.4] — 2026-10-08

Oriel 0.9.4 adds desktop wrappers for web apps, app-owned Android extensions,
and searchable documentation.

### Added

- `oriel wrap <url>` (alias `oriel pake`) scaffolds a desktop app for a website,
  with tray controls, close-to-tray behavior, automatic favicon fetching,
  optional Linux user-agent overrides, and AppImage packaging.
- App-owned Android extensions can handle Activity and WebView lifecycles,
  permissions, activity results, and file selection without editing generated
  runtime sources. Configure extension classes, Maven SDK dependencies, and
  repositories in the app's build configuration.
- Android app manifests can declare vendor native libraries with
  `uses-native-library` entries.
- Pagefind search on the documentation site, with keyboard navigation and
  indexed article content.

### Improved

- Android templates now use Android Gradle Plugin 8.13.2 and Kotlin 2.3.21,
  with the typed Kotlin JVM target configuration.
- Native-renderer documentation describes renderer capabilities independently
  of individual release versions.

### Fixed

- Linux disables WebKitGTK DMABUF rendering when the proprietary NVIDIA driver
  is detected, avoiding compositor-related high CPU usage. An explicit
  `WEBKIT_DISABLE_DMABUF_RENDERER` setting remains respected.

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
