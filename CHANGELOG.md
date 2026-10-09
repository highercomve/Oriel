# Changelog

Notable changes in Oriel releases.

## [0.9.10] — 2026-10-09

Oriel 0.9.10 makes `-Dnative_ui` apps on Linux free of WebKitGTK, and fixes
wide tables on the documentation site.

### Improved

- Linux apps built with `-Dnative_ui` no longer link or load WebKitGTK,
  JavaScriptCore or libsoup: every window is drawn by the native renderer.
  The system monitor example uses 14 MB less memory, loads 45 fewer shared
  libraries, and its stripped binary is 1.2 MB smaller.
- Their `.deb` and `.rpm` packages no longer depend on
  `libwebkitgtk-6.0-4` / `webkitgtk6.0`.
- The comparison with Vercel native now has measured numbers for the same
  system monitor app built with both frameworks.

### Fixed

- Documentation tables wider than the page column scroll sideways instead of
  spilling under the table of contents; the module overview fits again.

### Compatibility

- On Linux with `-Dnative_ui`, `media_scheme.setRoot` returns
  `error.NoWebView`: there is no WebView to serve media to. The HTTP media
  server is unaffected. WebView builds are unchanged.

## [0.9.9] — 2026-10-09

Oriel 0.9.9 adds `oriel.tts`: offline text to speech that works out of the
box, with Kokoro-82M voices, verified downloads, bundled phoneme data and
streaming playback on the CPU or the GPU. It also brings mDNS to Windows,
drag and drop to the iOS native renderer, and Windows fixes.

### Added

- `oriel.tts`: Kokoro-82M text to speech, the counterpart of `oriel.chat`
  and `oriel.dictation`. A catalog of models (`kokoro-82m-q8_0`, the
  default, and `kokoro-82m-f16`) and curated voices for English, Spanish,
  French, Portuguese, Italian, Japanese, Chinese and Hindi, downloaded from
  Hugging Face and checked against their SHA-256 (`download`, `delete`,
  `status`). `speak` reads Markdown as prose, guesses the language
  (`lang = "auto"`) and picks a voice for it, and streams playback in
  adaptive chunks: the first audio comes quickly and there are no gaps
  when synthesis is faster than real time. `stop` works from any thread;
  `warmUp` loads the model (and compiles GPU pipelines) ahead of the first
  utterance; `unloadIdle` frees it under memory pressure. Options cover
  model, voice, language, speed, Markdown, backend and threads; results
  report first-audio time, synthesis time, real-time factor and gaps.
  Events: "tts:download" and "tts:state".
- `audio_play.Stream`: streaming playback through a bounded ring, one device
  per utterance (`append`, `seal`, `finished`, `stop` from any thread,
  `playedSeconds`/`queuedSeconds`/`starvedSeconds`), next to the one-shot API.
- `model_download.fetchVerified`: downloads checked against a SHA-256; a
  mismatching file is deleted and `error.ChecksumMismatch` returned.
- espeak-ng's phoneme data is compiled at build time from the espeak-ng
  1.52.0 sources and shipped by `addApp` with every `.kokoro = true` app:
  next to the executable on Linux and Windows (and in their packages), in
  `Contents/Resources` on macOS, in the iOS `.app`, and in the Android APK's
  assets (extracted on first start). The `tts_languages` option picks the
  dictionaries (default `en,es,fr,pt,it,ja,cmn,hi`); `zig build
  espeak-data` writes the directory alone.
- Kokoro on the GPU with `-Dggml_cuda`, `-Dggml_vulkan` or `-Dggml_metal`,
  through ggml's backend registry, falling back to the CPU. Measured on an
  RTX 4070: first audio ~54 ms warm on CUDA, real-time factor ~0.02-0.03 on
  CUDA and Vulkan (Vulkan compiles its pipelines for 1-4 s on first use);
  8 threads of a Ryzen 7 7800X3D: ~0.36. Metal compiles in but hasn't been
  measured.
- Windows `oriel.network.mdns` backend on dnsapi's `DnsServiceRegister`,
  `DnsServiceBrowse` and `DnsServiceResolve` (Windows 10 1809+). TXT values
  must be UTF-8 text there.
- iOS native renderer: drag and drop into the page through
  `UIDropInteraction`: files (by data type), Photos images, text, and links
  (`text/uri-list` and `text/plain`), matching AppKit's.
- Showcase: a Speak tab (voices, models, speed, CPU/GPU, Markdown, live
  state, a result card with first audio, real-time factor and gaps), Read
  aloud on chat replies and notes, a warm-up on the tab's first visit, and
  the `--say` and `--tts-download` headless flags.

### Improved

- Phones run Kokoro on their fast cores only and shorten the first chunk to
  the measured speed. Low-end phones still synthesize slower than real
  time: a Snapdragon 732G (2 threads) reaches a real-time factor of ~2.75,
  with first audio after ~4 s and pauses between chunks.
- `oriel dev` rebuilds keep a Zig `--fork=<path>` option.
- Windows tray icons are decoded with zigimg instead of WIC, so creating and
  destroying trays no longer grows the process's kernel handles.

### Fixed

- Windows: closing a window or quitting while a native-renderer context menu
  or the tray menu is open no longer hangs; a native page that closes its
  own window from a control's handler is closed once that handler returns.
- Native-renderer sliders with huge ranges reach their min and max on
  Windows, and the page-side value no longer becomes `Infinity`.
- Windows `dialog.saveToFolder` refuses names Win32 programs can't open
  (device names such as `CON` or `nul.txt`, a trailing dot or space,
  `<>:"|?*`) with `error.InvalidName`.
- Android: `audio_play` builds with NDK 28 (nullability qualifiers in its
  headers).
- Windows: Kokoro links espeak-ng statically (`LIBESPEAK_NG_EXPORT`), so
  its API is no longer declared as imported from a DLL.

### Compatibility

- `KOKORO_ESPEAK_DATA_PATH` is now optional: apps no longer supply
  espeak-ng data. Set it only to use other data than the bundled copy.
- Android projects generated before this release need one line in
  `app/build.gradle.kts`, inside `android { }`:
  `sourceSets["main"].assets.srcDirs("../../zig-out/android-assets")`
  (the path from the app module to `zig-out`). The Kotlin runtime is
  updated by the build.
- Apps built with `.kokoro = true` now ship espeak-ng's data
  (GPL-3.0-or-later, about 2.9 MB with the default languages); see `NOTICE`.

## [0.9.8] — 2026-10-09

Oriel 0.9.8 is a memory-safety release. It fixes use-after-free, out-of-bounds,
overflow and leak defects across the native UI, platform layers, modules and
CLI tooling.

### Fixed

- Update manifests: base64 signatures, public keys and seeds must decode to
  exactly their expected size, closing a stack overflow reachable from an
  untrusted manifest before signature verification.
- Native DOM: mutation observer hooks no longer run page code in the middle of
  a store operation, so observers can no longer corrupt or free nodes still in
  use. `host.canvas` re-reads its buffer after page code can run, wrappers are
  re-validated after allocation, `:nth-child` arithmetic no longer overflows,
  and serialization and deep cloning no longer recurse per tree level.
- Native UI: repeating gradients with many stops no longer write past a stack
  buffer, focus and blur no longer run page code while fields are being
  synchronized (GTK, UIKit), page geometry and slider values are clamped before
  integer conversion, and uninitialized text layout offsets, error-path leaks,
  stale event pointers and unreleased accessibility elements are fixed.
- Win32: clipboard paste is bounded by the clipboard allocation, controls are
  no longer destroyed under an open context menu, and GDI, font-cache and event
  handle leaks are fixed.
- Android: native-page commands are queued instead of running inside the
  page's own JavaScript, so a command that closes its window can no longer free
  the running engine. Dropped-file descriptors and window sizes are handled
  safely.
- Linux: a rejected window URL no longer leaks a window with a dangling close
  handler, an empty second-instance command line no longer crashes the primary
  instance, and windows, queued replies and timers are released at shutdown.
- macOS and iOS: pending WebKit replies are answered before release at
  shutdown, and single-instance and scene teardown no longer reuse closed
  descriptors or freed windows. Windows `showWindow` no longer reads window
  state off the main thread.
- Modules and plugins: fixes for the macOS file watcher, the store keeping
  borrowed JSON values, Linux menu and tray leaks, tray D-Bus depth handling,
  clipboard image decoding, X11 shortcut re-entry, Windows share events and
  the Wayland keymap.
- AI and audio: empty SQL statements, WAV sample rates, prompt and download
  sizes, grammar sampling and empty prompts are validated; GPU loaders clear
  their function pointers when a library fails to load.
- CLI and tooling: `oriel wrap` no longer returns a name from freed memory,
  Android manifest sync no longer reads stale keys, confirmation prompts accept
  Enter, long deep-link schemes work, and network responses are size-bounded.

### Compatibility

- Unpadded or otherwise mis-sized base64 signatures and keys in update
  manifests are rejected with `error.InvalidPadding`.
- Native pages: layout stops at 512 levels of nesting, gradients use at most
  256 stops, and selectors are limited to 16 nested `:not`/`:is`/`:has` and 32
  compound parts (longer ones throw `SyntaxError`).
- Window URLs containing control characters are rejected when the window is
  opened. `App.getWindow` and `App.getWindowByHandle` are main-thread only.
- New errors: `error.SqliteEmptyStatement` (`oriel.sql`),
  `error.PromptTooLong`, `error.EmptyPrompt` and `error.SampleFailed` (chat),
  `error.DownloadTooLarge` (model downloads). WAV input below 4000 Hz is
  rejected.

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
issues from a security and memory-safety review, and documents which reported
findings were not supported by the current code.

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
- Validated every finding in the security and memory-safety review, correcting ownership, tar extraction,
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
