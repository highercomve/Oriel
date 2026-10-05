# Platform support

[Back to Oriel](../README.md) · [Documentation](README.md)

## Platforms

Oriel separates platform-neutral application and window logic (`src/core/App.zig`, `ipc.zig`, `security.zig`) from operating system shell implementations (`src/platform/`).

- **`src/platform/platform.zig`**: Compile-time platform selection and interface contract. Inspects `@import("builtin").os.tag` and validates via comptime assertions that the selected implementation exports all required types and functions.
- **`src/platform/linux/`**: Linux backend (GTK4 + WebKitGTK 6.0):
  - `Shell.zig`: `GtkApplication` lifecycle, signal handling (SIGTERM/SIGINT), event loop, application menubar, and thread-safe quit.
  - `window.zig`: `GtkApplicationWindow` and `WebKitWebView` instantiation, window sizing, fullscreen, maximization, and navigation policy.
  - `scheme.zig`: `app://` custom URI scheme handler serving embedded assets with CSP headers.
  - `bridge.zig`: WebKit script message handlers, JS IPC transport (`window.oriel.invoke` / `listen` / `emit`), and async command dispatch.
  - `dev_server.zig`: External dev server process management (`gio.SubprocessLauncher`, `PDEATHSIG`) and reload retries.
- **Windows** (`src/platform/windows/`): Win32 window + Microsoft Edge WebView2 implementation behind the same platform interface.
- **macOS** (`src/platform/macos/`): AppKit `NSWindow` + `WKWebView`, driven through the Objective-C runtime with [zig-objc](https://github.com/mitchellh/zig-objc), behind the same interface (see [macOS](#macos) below).

### Windows

Oriel builds Windows apps (`x86_64-windows` and `aarch64-windows`) two ways, both verified: natively on Windows, or cross-compiled from Linux. Both need `WebView2Loader.dll` and NSIS (`makensis`) for the installer.

The Oriel CLI downloads, verifies (SHA-512 against the NuGet registration catalog), and caches `WebView2Loader.dll` automatically on first build/package or during `oriel init`. You can also manage or prefetch it with `oriel webview2`.

```sh
# On Windows (PowerShell): Zig 0.16, Node.js for Vite templates, NSIS 3 (found in Program Files, no PATH needed)
oriel build
oriel package   # zig-out\package\<app>-<version>-setup.exe

# On Linux: cross-compile
oriel build -Dtarget=x86_64-windows
oriel package -Dtarget=x86_64-windows
```

The CLI automatically passes `-Dwebview2-loader=<cached dll>` when building for Windows. An explicit `-Dwebview2-loader=<path>` always overrides the cache. Automatic download can be disabled with `ORIEL_NO_WEBVIEW2_FETCH=1`.

#### Manual download

If you prefer to download the loader manually (e.g. in offline environments):
1. Download `microsoft.web.webview2.<version>.nupkg` from [NuGet](https://www.nuget.org/packages/Microsoft.Web.WebView2/) (a `.nupkg` is a ZIP archive).
2. Extract `runtimes/win-x64/native/WebView2Loader.dll` (or `win-arm64`).
3. Pass `-Dwebview2-loader=/path/to/WebView2Loader.dll`.

The installer is per-user (`%LOCALAPPDATA%\Programs\<name>`, no admin), adds Start Menu shortcuts and an uninstall entry, checks for the WebView2 runtime, and supports silent `setup.exe /S` / `Uninstall.exe /S`.

> [!NOTE]
> **Runtime Status**: verified on real Windows 11 (2026-09-24), both as a native Windows build (check, smoke checks, React app, `oriel package`, silent install / launch / uninstall) and with installers cross-built from Linux. The `examples/react` NSIS installer: installer, window + WebView2 with embedded assets, routes, sync and async IPC, SQLite (persisting across restarts), a second window via `oriel.window.open()`, `oriel.openExternal`, tray icon and menu. `examples/smoke` on the same PC: 37/38 checks ok (every module: tray, updater, media_server with byte ranges, sql, fs_watch, dialog, notification, store, menu, global_shortcut, input, clipboard incl. worker-thread r/w, window API, CSP, navigation, openExternal). The one failure, `nav iframe`, is the check, not the policy: the navigation is blocked, but WebView2 leaves a cross-origin error page in the frame. Module checks that only create the native object (dialog, hotkey, input) do not prove user-visible behaviour; the "runtime untested" notes in the table below refer to that.

#### Support Matrix

| Feature / Module | Status | Implementation Details |
|---|---|---|
| **Core Shell & Lifecycle** | ✅ Implemented | Win32 message loop (`GetMessageW`), `CreateWindowExW`, thread-safe main thread dispatch |
| **Window Operations** | ✅ Implemented | Size, maximize, fullscreen, show/hide/toggle, close, title; controller bounds follow `WM_SIZE`/`WM_DPICHANGED` (no per-monitor DPI manifest yet) |
| **Multi-Window & JS API** | ✅ Implemented | `oriel.window` JS API, `App.openWindow`, multi-window COM message dispatch, child window communication |
| **WebView Engine** | ✅ Implemented | Microsoft Edge WebView2 (Evergreen) via hand-declared COM vtables matching `WebView2.h` |
| **Embedded Assets** | ✅ Implemented | `https://app.localhost/*` intercept via `AddWebResourceRequestedFilter` + `SHCreateMemStream` |
| **JS ↔ Zig IPC** | ✅ Implemented | `window.chrome.webview.postMessage` + `add_WebMessageReceived`, sync and async worker commands |
| **System Tray (`tray`)** | ✅ Implemented | `Shell_NotifyIconW` + `TrackPopupMenu` context menu; icons decoded via `zigimg` |
| **Database (`sql`)** | ✅ Implemented | Embedded SQLite3 C amalgamation linked with Windows threading |
| **Vector Search (`sqlite_vec`)** | ✅ Implemented | Embedded `sqlite-vec` C amalgamation |
| **Packaging (`package-nsis`)** | ✅ Implemented | Per-user NSIS installer (`setup.exe`) generated via `makensis` with WebView2 bootstrapper detection |
| **Menu bar (`menu`)** | ✅ Implemented | Win32 menu bar (`CreateMenu`/`AppendMenuW`) + accelerator table; runtime untested on Windows |
| **Settings Store (`store`)** | ✅ Implemented | `%APPDATA%` / `%LOCALAPPDATA%` via `SHGetKnownFolderPath`, same JSON store; runtime untested on Windows |
| **File Dialogs (`dialog`)** | ✅ Implemented | COM `IFileOpenDialog` / `IFileSaveDialog`; runtime untested on Windows |
| **Notifications (`notification`)** | ✅ Implemented | `Shell_NotifyIconW` balloon (no WinRT toasts); runtime untested on Windows |
| **File Watching (`fs_watch`)** | ✅ Implemented | Win32 `ReadDirectoryChangesW` (overlapped I/O, non-blocking poll); runtime untested on Windows |
| **Media Server (`media_server`)** | ✅ Implemented | http.zig server + range streaming + `https://app.localhost/media/` via WebView2 `WebResourceRequested`; runtime untested on Windows |
| **Updater (`updater`)** | ✅ Implemented | Ed25519-signed manifests; rename-the-running-exe replace (`MoveFileExW`), `CreateProcessW` restart; runtime untested on Windows |
| **Global Shortcuts (`global_shortcut`)** | ✅ Implemented | Win32 `RegisterHotKey` / `WM_HOTKEY` routed via hidden host window; runtime untested on Windows |
| **Input Injection (`input`)** | ✅ Implemented | Win32 `SendInput` (UTF-16 Unicode down/up pairs, VK combo mapping); runtime untested on Windows |
| **Clipboard (`clipboard`)** | ✅ Implemented | Win32 `OpenClipboard` (CF_UNICODETEXT, CF_DIB, registered PNG via `zigimg`); runtime untested on Windows |
| **llama.cpp / whisper.cpp (`llama`, `whisper`)** | ✅ Builds | Same opt-in `-Dllama` / `-Dwhisper` CPU builds, cross-compiled (links; runtime untested on Windows) |

*Note*: Windows builds use the same defaults as Linux: every module and plugin is on unless disabled with `-D<name>=false`; `sqlite_vec`, `llama` and `whisper` are opt-in on both. Nothing in this table has been run on Windows yet: it cross-compiles, links and packages, and the platform-neutral logic (key and accelerator parsing, DIB conversion, path validation, notify-record parsing) is unit-tested on Linux.

#### Cross-Building for Windows

From any Oriel application directory (e.g. `examples/showcase`):

```sh
# Cross-compile production Windows binary (zig-out/bin/<app>.exe)
oriel build -Dtarget=x86_64-windows

# Build Windows NSIS installer (zig-out/package/<app>-<version>-setup.exe)
oriel package -Dtarget=x86_64-windows
```

The resulting `setup.exe` bundles the application executable, `WebView2Loader.dll`, Start Menu shortcuts, and an uninstaller, and automatically detects if the Microsoft Edge WebView2 runtime is present. At runtime, `WebView2Loader.dll` is loaded strictly from the application executable's directory to avoid DLL search-order hijacking, and user data is stored at `%LOCALAPPDATA%\<app_id>\WebView2`.

### macOS

The macOS shell builds and runs natively on the Mac (Apple Silicon and Intel; needs Xcode or the command-line tools for the SDK):

```sh
oriel build            # production build with embedded frontend
oriel dev              # run against Vite dev server with hot reload
```

- `src/platform/macos/`: `Shell.zig` (NSApplication run loop, main-thread tasks on the GCD main queue, default app/Edit/Window menu bar, SIGTERM/SIGINT → clean quit, Dock-icon click reopens a hidden main window), `window.zig` (windows, `WKNavigationDelegate` / `WKUIDelegate` navigation policy), `scheme.zig` (`app://` through a `WKURLSchemeHandler`, same headers and CSP as Linux), `bridge.zig` (the Linux bridge script over a `WKScriptMessageHandlerWithReply`: sync commands from the main loop, async ones on the worker pool), `dev_server.zig`.
- **Verified** on macOS 15.2 (arm64), 2026-09-25: IPC, async IPC, events, window API incl. child windows, CSP, navigation, openExternal, JS `alert`/`confirm`/`prompt` (NSAlert sheets); `examples/react` production (embedded) and dev (Vite) builds show the notes UI; `examples/smoke --auto-quit` passes every check.
- **Modules:** every module and plugin has a macOS backend (see each module's section): tray (`NSStatusItem`), menu (`NSMenu`), dialog (`NSOpenPanel`/`NSSavePanel`), notification (UserNotifications / osascript), store (`~/Library`), clipboard (`NSPasteboard`), fs_watch (FSEvents), global_shortcut (Carbon), input (CGEvent), updater (`.app` bundles), media_server, audio_capture (CoreAudio; system audio through a process tap), llama/whisper on Metal.
- **Permissions:** input injection needs Accessibility; audio capture needs the Microphone permission (or, for the "System audio" source, System Audio Recording). macOS grants these per app bundle: an unbundled binary is attributed to the app that started it (Terminal, an IDE), and some of those apps can't be granted them, so test these from an `.app`. **Accessibility and ad-hoc signing:** the grant is tied to the exact code signature, and after rebuilding an ad-hoc-signed `.app` macOS may keep matching the old build (tccd: "Failed to match existing code requirement"), even after removing and re-adding it. Test input injection from a Developer ID-signed bundle, or run the binary from a terminal that already has Accessibility. Microphone, system audio and notifications work with ad-hoc bundles.
- **Dev mode:** `oriel dev` works as on Linux: Vite hot reload, and the app is rebuilt and restarted when a `.zig` file changes (the watcher polls modification times). Running the `-dev` executable directly also works: it starts the dev server itself.
- **Bundles:** `oriel build` also writes `zig-out/<Name>.app`, and `oriel package` builds `.app` and `.dmg` (see [macOS bundles](packaging.md#macos-bundles-app-dmg)). Start the bundle with `open zig-out/<Name>.app` to get notifications through Notification Center, permission prompts under the app's name and deep links.
- **Not yet:** Developer ID signing and notarization; windows without decorations can't become key.
- `ORIEL_SNAPSHOT=/tmp/shot.png` saves the main window's page (WebKit's snapshot API) a second after it loaded: screen capture of other apps needs a Screen Recording grant on macOS.
