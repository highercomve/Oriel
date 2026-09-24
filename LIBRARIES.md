# Oriel — library investigation

Researched 2026-09-23 for **Zig 0.16.0**. Companion to [IDEA.md](./IDEA.md).
Driven by what ghostpen and ghostreel actually use.

## TL;DR

- **Same binding stack as Ghostty:** `zig-gobject` (GTK4/WebKit/GIO),
  `zig-objc` (macOS), `zig-wayland` (Wayland protocols). All three are ready for
  Zig 0.16, and Ghostty depends on all three in production.
- **Most app-level needs are already in Zig's standard library (`std`):** JSON,
  HTTP client, TLS, BLAKE3, `std.Io` async. Only SQLite, TOML, images and the
  local HTTP server need outside packages.
- **Decisions (2026-09-23):** use the original `ianprime0509/zig-gobject`
  (it ships WebKit-6.0 bindings; Ghostty's repo only packages the libraries
  Ghostty itself needs), don't use `webview/webview` at all, and write our own
  CLI parser.
- **Two findings that shape the design:**
  1. **A GTK4 process cannot use libayatana-appindicator.** That library is
     built on GTK3, and GTK3 and GTK4 cannot be loaded into the same process.
     We must implement the tray ourselves as StatusNotifierItem + DBusMenu over
     GDBus. Tauri avoids the problem by staying on GTK3 and WebKit2GTK-4.1.
  2. **oriel can beat Tauri on Wayland.** Ghostpen currently gives up global
     hotkeys and synthetic paste on Wayland. Both are reachable today through
     the GlobalShortcuts portal (available on this Hyprland box) plus Wayland's
     virtual-keyboard protocol, or libei.

## Core, built-in modules, plugins

Three tiers. Decision (2026-09-23): tray, updater, media-server, sql and
fs-watch are **built into the framework**, because most desktop apps need them.
They are still switched on per app in `build.zig`, so an app that doesn't use
`sql` doesn't link SQLite and binaries stay small.

**1. Core (always on):**
- GTK4 + WebKitGTK 6.0 (+ JavaScriptCore 6.0, Soup 3) + GIO, through zig-gobject
  (generated locally from system GIR files; see "Second-pass gaps" point 3)
- Zig's `std`: JSON (IPC), `std.Io`, `@embedFile` (assets)
- Our own CLI parser + `comptime` command bindings
- Free with GTK/GIO: single instance, file dialogs, notifications, open-URL

**2. Built-in modules (in the framework repo, maintained with the core, opt-in per app):**

| Module | Libraries | Notes |
|---|---|---|
| `tray` | GDBus (StatusNotifierItem + DBusMenu), zigimg for icon pixels | Hand-written SNI; ~500–800 lines on Linux |
| `updater` | `std.http`, `std.compress`, `std.tar`, Ed25519 (`std.crypto`) | Signed update manifests, same model as Tauri's updater |
| `media-server` | http.zig, or range handling inside the custom scheme | Streams large local files (video/audio) with HTTP range requests |
| `sql` | SQLite amalgamation (+ optional sqlite-vec) | Compiled from C in `build.zig`; zig-sqlite optional |
| `sqlite_vec` | sqlite-vec amalgamation (`v0.1.9`) | Opt-in (default OFF: `-Dsqlite_vec`). Requires `sql`. Vector search extension (`vec0`) |
| `llama` | llama.cpp (`b10809`) via Zig package manager | Opt-in (default OFF: `-Dllama`). Native C/C++ CPU inference backend linked against shared GGML |
| `whisper` | whisper.cpp (`v1.9.4`) via Zig package manager | Opt-in (default OFF: `-Dwhisper`). Native C/C++ speech-to-text inference linked against shared GGML |
| `fs-watch` | inotify (`std.os.linux`) / FSEvents / ReadDirectoryChangesW | Own implementation; nothing outside `std` on Linux |

**3. Plugins (app-specific, outside the core):**

| Plugin | Libraries | First user |
|---|---|---|
| `global-shortcut` | GlobalShortcuts portal (raw GDBus or libportal), libX11 | ghostpen |
| `input` (typing into other apps) | zig-wayland + virtual-keyboard XML + libxkbcommon, libei, XTest | ghostpen |
| `clipboard` (in the background) | zig-wayland + data-control XMLs; GdkClipboard | ghostpen |

## Zig packages (verified against GitHub)

| Package | Purpose | 0.16 status | Notes |
|---|---|---|---|
| **[ianprime0509/zig-gobject](https://github.com/ianprime0509/zig-gobject)** (chosen) | GIR binding generator + prebuilt bindings: GTK4, WebKit 6.0, JavaScriptCore 6.0, Soup 3, GIO, libportal (Xdp) | ✅ `minimum_zig_version = 0.16.0`; README: "tested on Zig 0.16"; release v0.3.2 (2026-07-19) | The prebuilt `bindings-gnome50.tar.zst` already contains `webkit6`, `javascriptcore6`, `soup3`, and its automated tests generate WebKit-6.0. **Maintenance:** 37 commits in the last 12 months, essentially one maintainer (Ian Johnson), 147★, 46 open issues, 1–2 releases a year following each Zig and GNOME release. Bus-factor risk is softened because Ghostty's GTK app depends on this generator. |
| [mitchellh/zig-objc](https://github.com/mitchellh/zig-objc) | Objective-C runtime (AppKit, WKWebView) | ✅ "Add Zig 0.16 compatibility" (2026-04) | Used by Ghostty. |
| [ifreund/zig-wayland](https://github.com/ifreund/zig-wayland) (canonical home is Codeberg) | libwayland bindings + protocol scanner | ✅ "Zig 0.16 bindings" | For the virtual-keyboard and data-control protocols. Used by Ghostty. |
| [marlersoft/zigwin32](https://github.com/marlersoft/zigwin32) | Win32 API bindings | ⚠️ min 0.14.0, active (2026-07) | Needs a test on 0.16. Alternative: hand-written `extern` declarations for the ~50 functions we need. |
| [karlseguin/http.zig](https://github.com/karlseguin/http.zig) | HTTP server | ✅ master = 0.16 ("experimental") | Only for ghostreel-style local media serving with HTTP range requests. Windows builds apply `tools/patch_httpz.zig` (Winsock shutdown errors it treats as `unreachable`; upstream candidate). |
| [vrischmann/zig-sqlite](https://github.com/vrischmann/zig-sqlite) | SQLite wrapper | ⚠️ master tracks Zig master; branch `update-zig-0.16.0` | Or compile the SQLite C amalgamation directly. sqlite-vec is also a C amalgamation. |
| [sam701/zig-toml](https://github.com/sam701/zig-toml) | TOML | ✅ branch `zig-0.16` | Config files. |
| [zigimg/zigimg](https://github.com/zigimg/zigimg) | PNG/JPEG decode and encode | ✅ `minimum_zig_version = 0.16.0` | Clipboard images, thumbnails. |
| [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) | SQLite vector search extension (`v0.1.9` amalgamation) | ✅ C99 amalgamation | Opt-in (`-Dsqlite_vec`). Static extension (`vec0`). License: MIT OR Apache-2.0. |
| [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | LLM inference engine (`b10809` tarball) | ✅ Built with Zig package manager + clang | Opt-in (`-Dllama`). CPU backend with shared GGML. License: MIT. |
| [ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Automatic speech recognition engine (`v1.9.4` tarball) | ✅ Built with Zig package manager + clang | Opt-in (`-Dwhisper`). CPU backend with shared GGML. License: MIT. |
| [Microsoft.Web.WebView2](https://www.nuget.org/packages/Microsoft.Web.WebView2) | Windows webview runtime (COM interfaces) | ✅ BSD-3-Clause | Hand-declared COM vtables matching `WebView2.h` in `src/platform/windows/webview2.zig`; loads `WebView2Loader.dll` from the exe's directory (the NSIS installer ships it) |

## Standard library coverage (no dependency needed)

| Need | Where in `std` | Replaces (Rust) |
|---|---|---|
| JSON (IPC, config) | `std.json` | serde_json |
| HTTP client + TLS 1.2/1.3 (Ollama/OpenAI calls, updater) | `std.http.Client` | reqwest |
| Async / concurrency | `std.Io` (threaded or evented) | tokio |
| BLAKE3, SHA-256 | `std.crypto.hash` | blake3 |
| Base64 | `std.base64` | base64 |
| Directory walking | `std.fs.Dir.walk` | walkdir |
| Build-time asset embedding | `@embedFile` + `build.zig` | tauri codegen |
| Command → TypeScript declarations | `comptime` + `@typeInfo` | tauri macros + specta |
| CLI parsing (the `oriel` tool) | own ~350-line `comptime` parser over `std.process.Args` | clap |

**CLI parser:** a small `comptime` framework (~350 lines). Subcommands are a `union`, options are `struct` fields,
a `run()` method dispatches, and help text is generated with `comptime`. It's
the same idea as oriel's command → TypeScript bindings, so the two can share
reflection helpers.

Not in `std`: **file watching** (write it ourselves: inotify on Linux via
`std.os.linux`, FSEvents on macOS, `ReadDirectoryChangesW` on Windows), XML
(small hand-written writer for FCP XML output), OS-specific integrations (below).

## Platform backends

### Linux (primary target, verified on this machine: Arch, Wayland/Hyprland)

| Feature | Library / API | Installed | Notes |
|---|---|---|---|
| Window + event loop | GTK4 | 4.22.5 | `GtkApplication` |
| Webview | WebKitGTK 6.0 | 2.52.6 | `webkit_web_context_register_uri_scheme` for `app://`; `WebKitUserContentManager` script-message handler for IPC |
| Single instance | GtkApplication unique ID (D-Bus) | built in | Also forwards `--trigger` arguments to the running app, like ghostpen does today |
| Tray | **StatusNotifierItem + com.canonical.dbusmenu over GDBus (GIO)** | GIO 2.88.3 | Hand-written (~500–800 lines). `libayatana-appindicator` 0.6.0 is installed but GTK3-only, so it can't be used in a GTK4 process |
| Global hotkeys (Wayland) | `org.freedesktop.portal.GlobalShortcuts` via libportal 0.11 (`globalshortcuts.h`) or raw GDBus | ✅ the portal is available here | Needs a portal backend (Hyprland, KDE and GNOME have one); the user confirms the bindings in a system prompt |
| Global hotkeys (X11) | `XGrabKey` (libX11) | x11 1.8.13 | |
| Input injection (wlroots/Hyprland) | `zwp_virtual_keyboard_v1` via zig-wayland | protocol XML not installed; vendor it from wlr-protocols | Same approach as `wtype` |
| Input injection (GNOME/KDE) | libei via the RemoteDesktop portal (liboeffis) | libei 1.6.0 | The RemoteDesktop portal isn't available on Hyprland here, so keep both paths |
| Input injection (X11) | XTest | xtst 1.2.5 | |
| Background clipboard (Wayland) | `ext-data-control-v1` via zig-wayland | protocol present | GTK's `GdkClipboard` only works while our window has focus, which ghostpen doesn't |
| Clipboard (focused / X11) | `GdkClipboard` | built in | |
| File dialogs | `GtkFileDialog` | built in | Uses the portal automatically |
| Notifications | `GNotification` (GIO) | built in | libnotify 0.8.8 isn't needed |
| Open URL / file | `GtkUriLauncher` / `g_app_info_launch_default_for_uri` | built in | |

### macOS (via zig-objc)

| Feature | API |
|---|---|
| Window / event loop | AppKit `NSApplication`, `NSWindow` |
| Webview | `WKWebView`, `WKURLSchemeHandler` (assets), `WKScriptMessageHandler` (IPC) |
| Tray | `NSStatusItem` + `NSMenu` |
| Global hotkeys | Carbon `RegisterEventHotKey` (still works, no special permission) |
| Input injection | `CGEventCreateKeyboardEvent` + `CGEventPost` (needs the Accessibility permission) |
| Clipboard | `NSPasteboard` |
| Dialogs / notifications | `NSOpenPanel` / `UNUserNotificationCenter` (needs a signed bundle) |
| Single instance | `NSRunningApplication` check + Apple Events / distributed notification |

Needs the macOS SDK to build, so no cross-compiling from Linux in practice.

### Windows (via zigwin32 or hand-written externs)

| Feature | API |
|---|---|
| Window / event loop | Win32 `CreateWindowExW`, message loop |
| Webview | **WebView2** (COM). Declare its interface tables (vtables) in Zig from `WebView2.h`; load via `WebView2Loader.dll` or reimplement the small loader to avoid shipping the DLL |
| Tray | `Shell_NotifyIconW` |
| Global hotkeys | `RegisterHotKey` |
| Input injection | `SendInput` |
| Clipboard | `OpenClipboard` / `GetClipboardData` (`CF_UNICODETEXT`, `CF_DIB`) |
| Dialogs | `IFileOpenDialog` (COM) |
| Notifications | Toasts need WinRT (hard); start with `Shell_NotifyIcon` balloon notifications |
| Single instance | Named mutex + `WM_COPYDATA` to forward arguments |

Needs the WebView2 SDK header for its interface definitions; the WebView2
runtime itself is preinstalled on Windows 10/11.

## App-specific heavy dependencies (ghostreel only)

| Rust crate | Zig path | Effort |
|---|---|---|
| whisper-rs | whisper.cpp C API; build via its CMake project or compile the sources in `build.zig` | Medium. CUDA/Vulkan builds are the hard part; linking a prebuilt `libwhisper` is simplest |
| llama-cpp-2 (+ mtmd) | llama.cpp C API (`llama.h`, `mtmd.h`) | Medium. Same GPU-build caveat |
| rusqlite + sqlite-vec | SQLite + sqlite-vec amalgamations | Low |
| notify | own inotify/FSEvents/RDCW wrapper | Medium |
| axum + tower-http (serves video with range requests) | http.zig, or range handling in the custom scheme handler | Low–medium |
| quick-xml (FCP XML export) | hand-written writer | Low |
| image (jpeg) | zigimg | Low |

## Packaging / tooling (external tools, driven from `build.zig` or a `oriel` CLI)

| Target | Tool |
|---|---|
| AppImage | `appimagetool` (+ `linuxdeploy` for GTK/WebKit libraries, the hard part) |
| deb / rpm | `nfpm` (single static binary) or `dpkg-deb` / `rpmbuild` |
| macOS .app / .dmg | Directory layout written by hand + `codesign`, `notarytool`, `hdiutil` |
| Windows installer | NSIS or WiX; `signtool` |
| Updater | `std.http.Client` + Ed25519 signature check via `std.crypto.sign.Ed25519` (same model as Tauri's updater) |
| Frontend JS API | Own tiny npm package (`invoke`, `listen`) + generated `.d.ts` |

## Recommendations

1. **Use zig-gobject rather than raw `@cImport`** for GTK/WebKit/GIO. It gives
   type-safe signals and GObject casting, and Ghostty has proven it in production.
2. **Keep platform code behind the shell interface** from IDEA.md (`Window`,
   `WebView`, `dispatchToMain`, `registerScheme`, `Tray`, `Hotkey`, `Clipboard`,
   `Input`), with one implementation per OS, plus separate Wayland and X11
   variants on Linux.
3. **Linux spike order:** GTK4 window + WebKit custom scheme + IPC → tray
   (SNI/DBusMenu) → GlobalShortcuts portal → virtual-keyboard paste →
   data-control clipboard. After step 5, ghostpen's "❌ on Wayland" rows are gone.
4. **Keep the dependency budget small:** zig-gobject, zig-wayland, zig-objc,
   zigwin32 (maybe), zigimg, and per-app SQLite/TOML/http.zig. Everything else
   comes from `std` or the OS.

## Second-pass gaps (2026-09-23)

Points 1, 2 and 4 only concern the ghostpen plugins (`input`,
`global-shortcut`, `clipboard`). Point 3 affects the core. Points 5–6
(updater archives, tray icons) belong to the built-in modules.

- **libxkbcommon** (installed: 1.13.2), through a plain C import. It was
  missing from the list: `zwp_virtual_keyboard_v1` requires us to send the
  compositor a keymap before we can type. It isn't GObject-based, so
  zig-gobject can't generate bindings for it.
- **libportal (`Xdp-1.0`) is not in the prebuilt GNOME 50 bundle**, because
  GNOME's SDK doesn't include libportal. Either generate its bindings locally
  from `/usr/share/gir-1.0/Xdp-1.0.gir`, or call the GlobalShortcuts portal
  with raw GDBus (no extra library).
- **Prebuilt bindings vs local generation:** `bindings-gnome50` was built
  against the GNOME 50 SDK. This machine has GTK 4.22 / WebKitGTK 2.52, so
  newer APIs would be missing from the prebuilt set. Prefer running the
  generator in `build.zig` against the system GIR files, and fall back to the
  prebuilt bundle for CI.
- **Wayland protocol XMLs to vendor:** `virtual-keyboard-unstable-v1.xml` and
  `wlr-data-control-unstable-v1.xml` (wlr-protocols; the latter is for
  compositors without `ext-data-control-v1`). `ext-data-control-v1` is already
  in `/usr/share/wayland-protocols`.
- **Updater archives:** `std.compress` (flate/gzip, zstd) + `std.tar` +
  Ed25519 from `std.crypto`. No extra dependency.
- **Tray icon pixels:** StatusNotifierItem wants ARGB32 pixmaps or an icon
  name. Decode PNGs with zigimg, which is already on the list.
- **Windows:** the `WebView2.h` header comes from the
  `Microsoft.Web.WebView2` NuGet package, downloaded at build time or
  vendored.
- **Optional, for end-to-end tests:** `WebKitWebDriver` (ships with
  WebKitGTK) to drive the webview in automated tests.

Coverage status: **the Linux MVP is fully mapped**, and every library above is
installed here. macOS and Windows are mapped at the API level only; nothing
has been built or verified on them yet.

## Open questions to verify during the spike

- Are the prebuilt `webkit6` bindings usable as-is for custom URI schemes and
  script-message handlers? Ghostty doesn't use WebKit, so that path has had
  less real-world use. If we hit broken GIR annotations, borrow the fixes from
  `ghostty-org/zig-gobject`'s `gir-fixes` or its generator fork
  `jcollie/zig-gobject` (5 small commits on top of upstream).
- GlobalShortcuts portal behavior on Hyprland: how are bindings confirmed, and
  are they kept across restarts?
- Can WebKitGTK custom-scheme responses serve large videos with range requests
  efficiently, or is a localhost http.zig server needed?
- zigwin32 on 0.16: works as-is, or do we hand-write externs?
