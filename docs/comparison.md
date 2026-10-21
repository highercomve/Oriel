<!-- Generated from site/content/docs/comparison.smd by tools/docs/gen-md.mjs: edit that file. -->

# How Oriel compares

Oriel next to Electron and Tauri, and next to Vercel Labs' native (formerly zero-native), measured against what GhostPen needs.

Oriel builds desktop and mobile apps from Zig and a web UI, like Electron and
Tauri do from JavaScript and Rust. This page sets it next to those two, then
next to Vercel Labs' native, the other Zig framework.

## Electron and Tauri

All three keep the same model: a web frontend, a native backend, and calls
between them. What changes is what ships with the app and what's built in.

| | Electron | Tauri | Oriel |
|---|---|---|---|
| Backend | JavaScript on Node.js | Rust | Zig 0.16 |
| UI | Chromium, bundled with every app | The system webview | The system webview, or native views with no webview ([native renderer](native-renderer.md), compiled `.oriel` views) |
| App size | Chromium and Node.js in every app | Small: no browser bundled | A few MB: no browser bundled |
| UI ↔ backend | `ipcMain` / `ipcRenderer` through a preload script | `invoke` commands and events | Plain Zig structs; TypeScript generated at compile time ([commands](commands.md)) |
| Mobile | Desktop only | Android and iOS | Android and iOS from the same Zig and web code |
| Local AI and voice | Packages you add | Plugins or crates you add | Built in: llama.cpp, whisper.cpp, Kokoro text to speech, speaker diarization ([local AI](local-ai.md)) |
| Updates | `autoUpdater` or electron-updater | Updater plugin, signed | Ed25519-signed manifests, atomic replace ([updater](updater.md)) |
| Packages | Electron Forge or electron-builder | The Tauri bundler | `oriel package`: deb, rpm, AppImage, `.dmg`, `setup.exe`; APK, AAB and `.ipa` ([packaging](packaging.md)) |
| Toolchain | Node.js and npm | Rust and Cargo | Zig: a build cache in hundreds of MB, incremental rebuilds |

Oriel's security model follows Tauri's (per-origin command capabilities, a
strict CSP, navigation limits: [security](security.md)), and
its commands, events and windows map onto Tauri's one for one, which made
GhostPen's port from Tauri direct. Its README
[measures the two](https://github.com/highercomve/GhostPen#compared-with-the-rust-tauri-ghostpen).

## Vercel native

[Vercel Labs' native](https://github.com/vercel-labs/native) (formerly
zero-native) is the other Zig framework for desktop apps. Both use Zig 0.16
and target Linux, Windows and macOS, but they aim at different apps. This
page compares them on what [GhostPen](https://ghostpen.foreachdeveloper.com/)
needs: a React UI, and deep integration with the rest of the desktop. It
reflects native v0.10.1 (commit `6b05318`, September 2026). native is
pre-1.0 and moves fast, so check its
[platform support page](https://github.com/vercel-labs/native) for changes.

## Different starting points

- **native draws its own UI.** Views are `.native` markup with logic in
  TypeScript compiled to native code, or in Zig. Its engine draws every
  pixel, with no WebView and no JavaScript runtime in the binary. A WebView
  mode also exists (WebKitGTK, WKWebView, WebView2), and its `examples/react`
  runs a Vite + React app with `window.zero.invoke` / `window.zero.on`.
  Its mobile targets (iOS, Android) are experimental.
- **Oriel is WebView-first.** The UI is a web frontend (React, Vue, Svelte or
  vanilla) embedded at build time. The Zig side provides typed
  [commands and events](commands.md), and the
  [modules](modules.md) that reach outside the window:
  global shortcuts, input injection, clipboard, tray, audio capture,
  llama.cpp and whisper.cpp. The same app builds for
  [Android](android.md) and [iOS](ios.md).
  An experimental [native renderer](native-renderer.md)
  (`-Dnative_ui`) draws the same page with native views and no WebView.

## Feature by feature

| GhostPen needs | Oriel | native v0.10.1 |
|---|---|---|
| React + Vite UI in a WebView | ✅ | ✅ WebView mode (`window.zero.invoke`/`on`; events capped at 8 KiB) |
| Tray icon and menu | ✅ Linux, Windows, macOS | macOS and Windows; not on Linux ("until a status-notifier implementation is selected") |
| System-wide hotkeys | ✅ X11, Wayland portal, `RegisterHotKey`, macOS | ❌ shortcuts reach only the app's focused window |
| Send copy/paste to other apps | ✅ XTest, Wayland virtual keyboard, `SendInput`, `CGEventPost` | ❌ |
| Clipboard | ✅ text and images (PNG) | text, HTML, RTF; no images; on Wayland only while focused |
| Popup near the cursor, always on top | ✅ incl. Wayland layer-shell overlays | Linux never applies window positions; no always-on-top on Wayland; no layer-shell; Windows refuses transparent windows with a WebView |
| Microphone and system audio capture | ✅ Linux (PulseAudio/PipeWire), Windows, macOS | Windows and macOS; none on Linux |
| llama.cpp / whisper.cpp | ✅ built in, on CUDA, Vulkan or Metal | possible after `native eject` (plain Zig build code, written by the app) |
| Single instance, forwarding arguments | ✅ | ❌ |
| Settings, app directories, credentials | ✅ | ✅ (app dirs, libsecret/Keychain credentials) |
| Notifications | ✅ | ✅ (Windows: one balloon at a time) |
| Packages | deb, rpm, AppImage, NSIS `setup.exe`, `.app`/`.dmg`, WinGet manifests | `.app`/`.dmg`; Linux and Windows installers are "future work" |
| Self-update | ✅ Linux (AppImage), Windows, macOS; Ed25519 ([Updater](updater.md)) | macOS only |
| Code signing | macOS Developer ID or self-signed (`oriel signing`); Windows Authenticode with your own tools | macOS |
| Android and iOS | ✅ the same app, with phone modules (share, camera, system AI) | experimental |

## Measured: the same app in both

Both repositories ship a live system monitor (CPU and memory tiles with
sparklines, a sortable and filterable table of the top 128 processes,
SIGTERM with confirmation, a 2 s sampling cadence):
[native's](https://github.com/vercel-labs/native/tree/main/examples/system-monitor),
written in TypeScript and `.native` markup and drawn by native's own
renderer, and
[Oriel's](https://github.com/highercomve/Oriel/tree/main/examples/system-monitor),
a web page drawn by Oriel's native renderer (`-Dnative_ui`: QuickJS, the
native DOM, Yoga and GTK 4, no WebView) with a Zig sampler.

Both were built `ReleaseFast` (native from its repository at commit
`2bdd8eb8`, CLI 0.10.1; Oriel 0.9.11) and run one at a time on the same machine
(Arch Linux, kernel 6.18, Hyprland on Wayland, GTK 4.24, Ryzen 7 7800X3D,
RTX 4070, 787 processes running), each left to settle for 5 s and then
sampled every second for 60 s, twice each, alternating. Memory and CPU include every process
the app starts.

| | Oriel (`native_ui`) | native v0.10.1 |
|---|---|---|
| Memory, RSS (average) | 178–184 MB | 233 MB |
| Memory, PSS (average) | 108–121 MB | 154 MB |
| CPU (average, one core) | 1.1–2.5% | 5.6% |
| Threads | 22 | 14 |
| Executable, stripped | 4.2 MB | 7.0 MB |
| Shared libraries loaded | 113 (GTK 4) | 113 (GTK 4) |
| Processes started per sample | 0 (reads `/proc` in Zig) | 2 (`/bin/ps`, `/bin/cat`) |
| One sampling round | 6.0 ms | 18.9 ms |
| Table rows kept up to date | 256 | 128 |

What the numbers say:

- **Oriel uses less memory.** Both sit on GTK 4 and a GPU-backed renderer:
  the graphics driver's mappings alone were 52 MB of Oriel's resident
  memory and 75 MB of native's. Oriel used about 25% less in total (PSS,
  which splits shared pages fairly between processes).
- **Oriel uses less CPU, while updating twice as many rows.** Each sample
  changes the text of a few hundred table cells. Oriel's renderer updates
  that text in place in the native views (about 2–3 ms a sample) instead of
  rebuilding the rows, and its sampler starts no processes; native starts
  two per sample.
- **Sampling differs most.** Oriel's sampler reads `/proc` directly and
  takes about a third of the time of native's `ps` and `cat` round. The
  sampling round was timed on its own: the sampler compiled alone for Oriel,
  and the same two commands run from a shell for native. Starting them
  from a 250 MB process costs more than from a shell.
- **Same libraries.** Since Oriel 0.9.10 a `native_ui` app links no
  WebKitGTK: the same 113 libraries load as for native. Before, it linked
  WebKitGTK unused, which cost 14 MB of memory and 45 more libraries.

These are one machine and one app. GPU drivers, the compositor and the
number of processes all move the absolute numbers. Startup time and GPU
use were not measured.

## Where native is ahead

- Its own renderer is its main path, not an experimental option: UI
  written in TypeScript compiled to native code, with no JavaScript runtime
  in the binary.
- Tooling: an automation server with accessibility snapshots, recording and
  replaying sessions frame by frame, a deterministic reference renderer, hot
  reload that keeps state, and `native check` validation in milliseconds.
- macOS is its primary platform and the most complete.

## What a GhostPen port would take

GhostPen's windows and screens map directly onto native's WebView mode.
The parts that make it a system-wide tool don't: global hotkeys, pasting
back into other apps, image OCR from the clipboard, and captions and
dictation from Linux audio would all be written in the app itself. On
Wayland, the popup menu and the captions overlay would also need a fork of
native's GTK host, which can't position windows or use layer-shell. In
Oriel these are modules the app turns on in `build.zig`.

So the two frameworks suit different apps. native fits apps whose UI
lives in their own window, especially where a WebView isn't wanted. Oriel
fits apps that need a web UI plus the desktop around it: hotkeys, the
clipboard, other apps' input, audio, and local AI models.

## Other Zig and webview frameworks

- **Verve**, **Ziew**, **Electrobun** and the Zig webview bindings: useful
  references for pure-Zig or system-webview apps, though none covers Oriel's
  renderers, modules and platforms together.
- **libghostty and Ghostty**: the model for a Zig core with thin native
  platform shells, which Oriel follows.

## Related

- [Examples](examples.md#system-monitor): the system monitor measured above.
- [Native renderer](native-renderer.md): how Oriel draws a page without a WebView.
- [Modules](modules.md): every module and where it works.
