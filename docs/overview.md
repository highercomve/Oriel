# Background and framework comparisons

[Back to Oriel](../README.md) · [Documentation](README.md)

## Why "Oriel"?

An **oriel** is a bay window: a small window that juts out from a wall so you
can look outside. That is what the framework is: a native window, set into
the operating system, with the web platform showing through it.

The logo is that window seen from above. Its angled side walls read as `<`
and `>`, like code, around a lit amber pane, a nod to Zig's orange. The
project started as "ziguri"; it became Oriel before its first release.

## Compared with Tauri

| Tauri | Oriel (Linux) |
|---|---|
| Custom protocol for assets | ✅ `app://`, embedded at build time, SPA fallback |
| `invoke` / commands | ✅ plain Zig struct; TypeScript generated; sync & async worker pool |
| Events (`emit` / `listen`) | ✅ Zig → JS, type-checked on both sides; targeted (`window.emit`) & broadcast |
| Capabilities (command scopes) | ✅ per origin, per command, per window (`windows` list) |
| CSP, navigation limits, external links | ✅ |
| Isolation pattern | ✅ opt-in sandboxed frame hook with signed IPC calls (WebView) |
| Tray icon + menu | ✅ items, checkboxes, separators, submenus, runtime updates |
| Multiple windows | ✅ open/close, targeted events, geometry persistence, window options |
| App menu bar | ✅ Linux (`GMenuModel` + `GtkApplication` actions with shortcuts) + Windows (`HMENU` + `HACCEL`); runtime untested on Windows |
| Settings store | ✅ Linux (XDG paths + atomic thread-safe JSON store) + Windows (Known Folders + atomic JSON store); runtime untested on Windows |
| Logging | ✅ file + stderr logging + WebKit console forwarding |
| Close to tray, show/hide, single instance | ✅ |
| Dev server + hot reload / production build | ✅ `oriel dev` (Vite + Zig file watcher & reload) / `oriel build` (defaults to `ReleaseSafe`) |
| Dialogs (open/save file) | ✅ Linux (`GtkFileDialog`) + Windows (`IFileOpenDialog` / `IFileSaveDialog`); runtime untested on Windows |
| System notifications | ✅ Linux (`GNotification`) + Windows (`Shell_NotifyIconW` balloon); runtime untested on Windows |
| Clipboard | ✅ Linux (GdkClipboard + Wayland ext-data-control) + Windows (CF_UNICODETEXT / CF_DIB / PNG); runtime untested on Windows |
| Global shortcuts | ✅ Linux (X11 XGrabKey + Wayland portal) + Windows (`RegisterHotKey`); runtime untested on Windows |
| Input injection | ✅ Linux (X11 XTest + Wayland virtual-keyboard) + Windows (`SendInput`); runtime untested on Windows |
| Asset protocol for local files (streaming, ranges) | ✅ `media_server`: 127.0.0.1 server with ranges for `<video>`; `app://app/media/` for fetch |
| Updater | ✅ Ed25519-signed manifests, atomic download & replace, progress events, in-place restart |
| Bundling (AppImage/deb/rpm/app/dmg), signing | ◐ AppImage, deb, rpm, NSIS setup.exe, macOS .app/.dmg via `oriel package`; macOS Developer ID signing and notarization (`-Dmacos-sign-identity`, `-Dmacos-notarize-profile`) or a self-signed certificate (`oriel signing`); Authenticode not yet |
| `create-tauri-app`, `tauri dev/build`, `tauri info` | ✅ `oriel init` (React, Vue, Svelte, vanilla), `oriel dev/build/run/package`, `oriel doctor` |
| Windows | ◐ Win32 + WebView2 shell and every module/plugin (tray, sql, store, dialog, notification, menu, updater, media_server, fs_watch, global_shortcut, input, clipboard), NSIS `setup.exe`; cross-built from Linux, runtime untested on Windows |
| macOS | ◐ AppKit + WKWebView shell and every module/plugin (tray, menu, dialog, notification, store, clipboard, fs_watch, global_shortcut, input, updater, media_server, audio_capture incl. system audio), whisper/llama on Metal, deep links, `.app`/`.dmg` packaging |
| Mobile | ◐ Android (Kotlin Activity + WebView over JNI, one Activity per window, desktop mode): the shell and every module/plugin (tile, keyboard, notification actions, foreground service, input method, dialogs, notifications, clipboard, deep links, storage SAF), whisper/llama/dictation/chat with ARM dotprod/i8mm, Vulkan, OpenCL (Adreno) and Hexagon, verified on a Pixel; APK and AAB (`oriel android build`). iOS (UIKit + WKWebView from Zig, no Xcode project, Metal for whisper/llama): every module ported, verified in the simulator in CI; `.app`/`.ipa` via `oriel ios build` |

## Compared with Vercel native

[Vercel Labs' native](https://github.com/vercel-labs/native) (formerly
zero-native, v0.10.1) is the other Zig desktop framework. It draws its own UI
(TypeScript compiled to native code, or Zig) and also has a WebView mode. It
is ahead on no-WebView apps, experimental mobile targets and tooling
(automation, record and replay). But it has no system-wide hotkeys, no input
injection into other apps, no image clipboard, and no Linux tray or audio
capture. Its Linux host can't position windows, and it has no Wayland
layer-shell. For packaging it has only `.app`/`.dmg`, and self-update on
macOS only. Those are the parts GhostPen is built on: see
[Oriel and Vercel native](https://highercomve.github.io/Oriel/docs/comparison/)
for the feature table.
