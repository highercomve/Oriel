# Changelog

Notable changes in Oriel releases.

## [Unreleased]

### Added

- `oriel.lifecycle`: the app's lifecycle with one API on every platform
  (core, always on). `subscribe(handler)` (up to 16, called on the main
  thread in order) gets `background` / `foreground` (Android: the last
  Activity stopped / one started again; iOS: didEnterBackground /
  willEnterForeground), `memory_pressure` (`moderate` or `critical`:
  Android's onTrimMemory, iOS memory warnings, macOS's memory-pressure
  source, Windows' low-memory notification, Linux's GMemoryMonitor),
  `suspend_` / `resume_` (macOS NSWorkspace sleep and wake, Windows
  WM_POWERBROADCAST, logind PrepareForSleep) and `terminating` (quit,
  SIGTERM, iOS applicationWillTerminate, Windows WM_ENDSESSION). The page
  gets them with `oriel.lifecycle.on((e) => …)` as `{ type, level }`,
  queued until it listens; the TypeScript bindings declare
  `LifecycleEvent` and `LifecycleApi`.
- `oriel.chat`, `oriel.dictation` and `oriel.tts` unload their models on
  critical memory pressure by themselves; `unload_on` changes when
  (`.{ .background = true }`, or `.{ .memory_pressure = null }` for never).
- `window.oriel.features` in every page (and the native renderer), with
  the build's resolved flags in camelCase (`{ tray: false, fsWatch: true,
  ... }`), typed as `Features` in the generated `oriel.ts`.
- `zig build --verbose` prints one line listing the flags resolved to
  unavailable for the target.

### Changed

- Android: `background` / `foreground` come from OrielActivity's
  onStart/onStop (a new `NativeLib.onLifecycle` native, in the runtime
  synced into apps). The malloc purge on trim-memory is now a lifecycle
  subscriber, and also runs when the app goes to the background (it used
  to on TRIM_MEMORY_UI_HIDDEN). `oriel.android.onSystemEvent` still gets
  "trim-memory" and the Android-only events.
- The showcase frees its models through `unload_on` instead of
  `onSystemEvent` glue.
- Module flags are said once, for every target. An app's `.tray = true` in
  `b.dependency("oriel", ...)` means "where it exists": on a target without
  the module it resolves to off instead of failing the build (iOS) or
  building a stub (Android). Every module namespace has a comptime
  `available`: guard calls with `if (oriel.tray.available)`, and the code
  under it isn't built where the module is missing. A use outside the guard
  is a build error naming the module and the guard; so is one of a module
  the app left off. `-Dtray=true` on Oriel's own command line for a target
  without a tray is still a build error. See docs/modules.md,
  "Availability".
- **Breaking:** Android's stub modules are gone: `tray`, `menu` and `input`
  no longer build there with calls that fail with `error.Unsupported`. An
  Android build that calls them must guard the calls with
  `if (oriel.tray.available)` (or `oriel.menu`, `oriel.input`), and code
  that branched on `oriel.options.tray` can use `oriel.tray.available`.
  Apps no longer need per-target flags like `.tray = !is_android`.
- `-Dlayer_shell` is unavailable outside desktop Linux (it was ignored on
  Windows and macOS).

### Deprecated

- `oriel.ios.onSystemEvent`: now a lifecycle subscriber under the old
  names ("background", "foreground", "memory-warning"); use
  `oriel.lifecycle`.
- `App.Config.on_session_end`: still called on Windows at session end,
  after `terminating`; subscribe to `oriel.lifecycle` instead.


## [0.9.16] — 2026-10-11

Oriel 0.9.16 fixes what a code review against the NASA/JPL "Power of 10"
rules found: a way for `localStorage` to lose its data, use-after-free bugs
on window close and in Windows mDNS, pages that could hang their window,
replies reaching the wrong page, an unpinned download in the CLI, and
downgrades through `force`.

### Fixed

- Native renderer: `localStorage` could lose everything. A key or value
  with a lone surrogate (valid in JavaScript) was saved as invalid UTF-8,
  the next launch couldn't read the file and started empty, and the next
  save overwrote it. Keys and values are stored as valid UTF-8 now, the
  read limit allows for JSON escaping, and a file that fails to load is
  moved aside (`localStorage.json.corrupt-<time>`) instead of overwritten.
- Native renderer: closing a window from a frame hook or a promise job
  freed the page while it was still running; the close now waits until the
  page is idle, on every backend.
- Native renderer: a script that never returns (`while (true) {}`, or a
  promise chain that keeps requeuing itself) no longer hangs the window for
  good. A call into JavaScript is stopped after 10 seconds, promise jobs
  run at most 10,000 per turn (the rest on the next), and the JavaScript
  heap is limited to 1 GiB.
- Native renderer on Linux and Windows: above 256 MB of decoded images the
  image cache was emptied and every image decoded again each frame; it now
  evicts the least recently used images.
- Windows mDNS: stopping a browse while lookups were finishing could use
  freed memory (lookups are reference-counted now) and race on the found
  services; lookups, names and addresses per browse are capped. Names,
  addresses and TXT keys with a NUL byte are refused.
- Events and replies reached only the page that should get them: on Windows
  and Android, an asynchronous reply or event could reach the next page
  after a navigation, and on every platform events went to whatever page a
  window showed, bridge or not.
- Windows: a failed request-filter registration, or an early error while
  serving an asset, let `https://app.localhost` requests reach the network;
  window creation fails, or the request gets a 500. macOS and iOS fail the
  request when a security header (CSP, nosniff) can't be set.
- macOS and iOS: `nativePath` always failed (the `F_GETPATH` result was
  misread).
- IPC: requests over 32 MiB are refused, the async job queue is capped
  (1024; extra calls answer `WorkerPoolBusy`), a message that can't be
  decoded gets an `InvalidRequest` reply instead of never settling, and
  window sizes from the page must be 1..32767.
- Updates: a manifest older than the running version is never installed by
  `force`; `oriel update --version` checks the tag's form and that the
  signed manifest is that version. Plain-HTTP manifest URLs only work in
  tests. A raw payload's size is capped, the replaced binary keeps its
  mode, and on Windows the single-instance lock is released only once the
  new process has started.
- `oriel` CLI: the iOS `xtool` download is pinned to 1.21.0 and its SHA-256
  checked (it was GitHub's unpinned latest release, run with your Apple
  ID). `oriel wrap` escapes the title, user agent and URL in the code and
  HTML it writes, and allows only the exact origin unless
  `--allow-subdomains` is given. Signing keys' temporary folders are
  created private (0700) from the start.
- Android builds: a version part that isn't a number or is 100 or more,
  and app names with `" $ \ & < > '`, are build errors instead of a wrong
  version code or a broken project.

## [0.9.15] — 2026-10-11

Oriel 0.9.15 makes Android mDNS discovery reliable on phones older than
Android 14, which could miss devices on the network.

### Fixed

- Android mDNS browsing before Android 14: a resolve the system never
  answered blocked every service queued after it (one runs at a time), and
  a resolve that failed for any reason other than "busy" was never tried
  again, so the service stayed unlisted until browsing restarted. A
  resolve is now given up after 10 seconds, and failed ones are tried
  again after 1, 2, 4... seconds (up to 30) while the service is listed.
  Older phones could miss other devices on the network because of either.

## [0.9.14] — 2026-10-10

Oriel 0.9.14 fixes a crash: since 0.9.12, every app built with the native
renderer on Linux aborted as its window closed.

### Fixed

- Native renderer on Linux: closing a window no longer aborts the app
  (SIGABRT). The text layouts kept per node (0.9.12) were freed before the
  page, whose nodes then removed themselves from the freed map; a release
  build caught it as a misaligned pointer. Every `-Dnative_ui` app on
  Linux crashed as its window closed.

## [0.9.13] — 2026-10-10

Oriel 0.9.13 lets VoiceOver reach the share picker in the native renderer
on macOS, and fixes what testing 0.9.12 on a Mac found in the system
monitor example: idle processes can be found and terminated, empty CPU
chips are hidden, and idle macOS network ports are left out.

### Fixed

- Native renderer on macOS: a popover or sheet AppKit shows over the
  page (the share picker of `oriel.share.send`) is in the window's
  accessibility tree, so VoiceOver reaches it. The page view listed only
  the page's elements and left it out.
- System monitor example: the process filter reaches the sampler, so a
  match (by name, pid or, on macOS, user) is among the rows sent even
  when idle; filtering for `sleep` finds and can terminate it. Before,
  only the 256 busiest processes reached the page.
- System monitor example: the CPU header hides its frequency and
  temperature chips when there is no value (Apple Silicon), and macOS
  leaves out interfaces that never carried a byte (idle Thunderbolt and
  bridge ports); one that starts carrying traffic appears.
- System monitor example: the sampler tests print a sample taken half a
  second after the last, not a 0% CPU read 1.5 ms later.

## [0.9.12] — 2026-10-10

Oriel 0.9.12 keeps the native renderer's `localStorage` across runs, adds
macOS Services to share targets, and turns the system monitor example into
a btop-style monitor for Linux, Windows and macOS. Native renderer frames
on Linux are cheaper, and `JSON.parse` no longer depends on the locale.

### Added

- Share targets on macOS: `.share_target` also gives the `.app` an entry
  in the Services menu, titled with the share label (else the app's name),
  shown without the user enabling it. It sends the selection's files of the
  declared types and, when the types take text, plain text and URLs; the app
  receives them as one share with source `service`, its files readable
  through `oriel.share.file`, and comes forward.

### Changed

- Native renderer: `localStorage` lasts beyond the run, as in a WebView.
  One store per app, shared by its windows, saved as JSON in
  `~/.config/<app id>/data/localStorage.json` (`$XDG_CONFIG_HOME` when
  set; `~/Library/Application Support/<app id>/data` on macOS,
  `%APPDATA%\<app id>\data` on Windows). Writes are batched (saved
  300 ms after a change, and when a window closes), and a 5 MB quota throws
  `QuotaExceededError` as browsers do. It was an in-memory map before, gone
  at exit. On Android and iOS it still lasts the run.
- The system-monitor example grew into a btop-style monitor: per-core CPU
  with frequencies and temperature, load, memory and swap, disks with I/O
  rates, network, sensors, system information, process user, threads and
  command line, a responsive layout, and Settings to show or hide each
  part (kept in `localStorage`). It runs on Linux, Windows and macOS (a
  sampler per OS; the page hides what an OS doesn't report), and a CI
  workflow tests each sampler and builds the packages (.deb, .rpm,
  .AppImage, setup.exe, .dmg). It costs less than btop and the terminal
  drawing it: a sampler at ~1.6 ms a sample and a virtual process table.

### Fixed

- Native renderer: `JSON.parse` dropped the fraction of every number
  (`0.43` became `0`) under a locale whose decimal separator is a comma
  (`LC_NUMERIC=es_CL`, `de_DE`...): QuickJS read JSON numbers with
  `strtod`, which follows the locale GTK sets. It reads them with its own
  locale-independent `js_atod` now. Every command result reaching a page
  went through it.
- Windows builds with `-Dkokoro`: the build-time espeak-ng data compiler
  failed with `FileBusy` removing its staging directory, because the
  intonation compiler's log was left open.
- Native renderer on Linux: wheel scrolling no longer re-hovers a new
  element at every step. The compositor's motion after each step (the
  pointer still) hovered the row now under it, a restyle and a second
  redraw per step; `:hover` now waits until the scroll settles, as in
  browsers. The system-monitor example also drops its row hover
  transition, which kept the window redrawing every display frame while
  scrolling.
- Native renderer on Linux: cheaper frames. Each text keeps its Pango
  layout from frame to frame instead of being shaped again on every
  draw, and a box with rounded corners that clips its content clips it
  to a rectangle, with the rounded path only on what reaches into a
  corner (a path clip made Cairo composite everything under it through
  a mask). With the fix above, scrolling the system monitor's process
  table went from about 80% of a core to about 15%; a frame's paint
  takes about half as long.

## [0.9.11] — 2026-10-09

Oriel 0.9.11 adds `location.reload()` to the native renderer, makes live
tables much cheaper to update, and fixes the macOS and iOS builds of apps
with text to speech.

### Added

- Native renderer: `location.reload()` starts the page again in its window,
  with a new JavaScript runtime and DOM. It runs on a turn of its own, after
  the calling script returns; answers to the old page's commands and its
  pending timers are dropped instead of reaching the new page.

### Improved

- Native renderer: text changes in place more often. A text cell whose box
  clips its text (`overflow: hidden`), a native button elsewhere on the
  page, and canvas programs that change in the same frame no longer force
  the page's rows to be rebuilt. The system monitor example went from
  1,000–2,400 rebuilt nodes (20–45 ms) per sample to a few hundred text
  updates (2–3 ms), and from about 6% to 1–2.5% of one core.
- The system monitor example reuses its table rows and writes text only
  when it changed.

### Fixed

- The build-time espeak-ng data compiler builds on macOS and with Apple's
  SDK (it used stdio macros that translate-c turns into inline functions).
- iOS builds with `-Dkokoro`: espeak-ng gets its endian helpers on Apple
  targets, and miniaudio's playback compiles as Objective-C (AVFoundation).

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
