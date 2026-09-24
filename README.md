<p align="center"><img src="assets/brand/oriel-banner.png" alt="Oriel: desktop apps with Zig and the web" width="720"></p>

<p align="center">
  <a href="#license"><img alt="License: MIT OR Apache-2.0" src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-F7A41D?style=flat-square"></a>
  <img alt="Zig 0.16" src="https://img.shields.io/badge/zig-0.16-F7A41D?style=flat-square&logo=zig&logoColor=white">
  <img alt="Platform: Linux" src="https://img.shields.io/badge/platform-Linux%20(GTK4%20%2B%20WebKitGTK)-1B1F2A?style=flat-square">
  <img alt="Status: experimental" src="https://img.shields.io/badge/status-experimental-1B1F2A?style=flat-square">
</p>

# Oriel

**Desktop apps with Zig and the web.** Oriel is a Tauri-like framework in
Zig 0.16: a native window with the system webview, your frontend (React, Vite,
plain HTML…) embedded in a small binary, and typed JS ↔ Zig calls generated
from plain Zig structs. Linux (GTK4 + WebKitGTK 6.0) first.

- **Small:** a release app is a few MB; the build cache is hundreds of MB, not gigabytes.
- **Typed both ways:** `invoke` and `listen` in TypeScript are generated from your Zig `Commands` and `Events`.
- **Secure by default:** navigation limits, per-origin command capabilities, a strict CSP.
- **Batteries included, opt-in:** tray, updater, SQLite & sqlite-vec, llama.cpp & whisper.cpp, file watching, dialogs, notifications, global shortcuts, clipboard, packaging (deb, rpm, AppImage).

```sh
curl -fsSL https://raw.githubusercontent.com/highercomve/Oriel/main/install.sh | sh
oriel doctor              # checks Zig 0.16, GTK 4 / WebKitGTK 6.0, Node.js
oriel init my-app         # React + Vite (or --template vue|svelte|vanilla)
cd my-app && oriel dev    # hot reload; `oriel build` for the release binary
```

> **Status:** experimental. APIs will change; only Linux is supported so far.
> See [PLAN.md](PLAN.md) for the roadmap, [IDEA.md](IDEA.md) for the background
> and [LIBRARIES.md](LIBRARIES.md) for the dependencies.

## Examples

Each example is its own Zig package in [`examples/`](examples), built on Oriel
like any app would be.

<table>
  <tr>
    <td width="55%"><img src="assets/screenshots/react-notes.png" alt="React notes example: notes stored in SQLite on the Zig side, with a do-not-disturb badge set from the tray menu"></td>
    <td width="45%"><img src="assets/screenshots/ghostpen-lite.png" alt="GhostPen Lite example: global hotkey, clipboard pipeline and activity log"></td>
  </tr>
  <tr>
    <td><b><a href="examples/react">React notes</a></b>: React + Vite frontend, notes in SQLite on the Zig side, tray menu, typed events, async commands, <code>zig build dev</code> with hot reload, and deb/rpm/AppImage packages.</td>
    <td><b><a href="examples/ghostpen-lite">GhostPen Lite</a></b>: global hotkey → read clipboard → rewrite → paste back, with notifications and an activity log.</td>
  </tr>
  <tr>
    <td colspan="2"><img src="assets/screenshots/smoke.png" alt="Smoke test example: every module and security check passing inside the webview"></td>
  </tr>
  <tr>
    <td colspan="2"><b><a href="examples/smoke">Smoke test</a></b>: runs every module's check and the security checks (CSP, navigation, IPC) inside the real webview.</td>
  </tr>
</table>

## Repository layout

The framework and the apps built with it are separate Zig packages:

| Path | What |
|---|---|
| `build.zig` | Framework build: the `oriel` module, `embed_assets`, `dev_runner`, `addApp()` for apps, unit tests |
| `src/core/` | `App.zig` (platform-neutral windowing, IPC, events, asset lookup, dev mode), `ipc.zig` (command dispatch + TypeScript generation), `log.zig` (file + stderr logging) |
| `src/platform/` | Platform abstraction: `platform.zig` (OS selection & comptime check), `platform/linux/` (GTK4 + WebKitGTK 6.0 shell: `Shell.zig`, `window.zig`, `scheme.zig`, `bridge.zig`, `dev_server.zig`) |
| `src/modules/` | Built-in modules: `tray`, `menu`, `store`, `dialog`, `notification`, `updater`, `media_server`, `sql`, `sqlite_vec`, `llama`, `whisper`, `fs_watch` |
| `src/plugins/` | App-specific plugins: `global_shortcut`, `input`, `clipboard` |
| `tools/embed_assets.zig` | Embeds a built frontend directory into the binary |
| `tools/dev_runner.zig` | Hot reload orchestrator: keeps dev server running while watching `src/` and restarting the Zig app |
| `cli/` | The `oriel` command-line tool (`init`, `doctor`, build wrappers) and its embedded app templates |
| `install.sh` | Installs the `oriel` CLI from GitHub Releases |
| `examples/react/` | **App:** React + Vite notes app (own package) |
| `examples/smoke/` | **App:** checks every module (own package) |
| `examples/ghostpen-lite/` | **App:** hotkey -> read clipboard -> rewrite -> paste pipeline (own package) |

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

### Windows

Oriel supports cross-compiling and packaging for Windows (`x86_64-windows`) directly from Linux hosts using Zig and `makensis`.

> [!WARNING]
> **Runtime Status**: Code has been written against official Win32 and Microsoft Edge WebView2 specifications and cross-compiles/packages cleanly; however, **runtime execution is UNTESTED on real Windows hardware**.

#### Support Matrix

| Feature / Module | Status | Implementation Details |
|---|---|---|
| **Core Shell & Lifecycle** | ✅ Implemented | Win32 message loop (`GetMessageW`), `CreateWindowExW`, thread-safe main thread dispatch |
| **Window Operations** | ✅ Implemented | Size, maximize, fullscreen, show/hide/toggle, close, title; controller bounds follow `WM_SIZE`/`WM_DPICHANGED` (no per-monitor DPI manifest yet) |
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

From any Oriel application directory (e.g. `examples/react`):

```sh
# Cross-compile production Windows binary (zig-out/bin/<app>.exe)
zig build -Dtarget=x86_64-windows

# Build Windows NSIS installer (zig-out/package/<app>-<version>-setup.exe)
zig build package -Dtarget=x86_64-windows -Dwebview2-loader=/path/to/WebView2Loader.dll
```

The resulting `setup.exe` bundles the application executable, `WebView2Loader.dll`, Start Menu shortcuts, and an uninstaller, and automatically detects if the Microsoft Edge WebView2 runtime is present. At runtime, `WebView2Loader.dll` is loaded strictly from the application executable's directory to avoid DLL search-order hijacking, and user data is stored at `%LOCALAPPDATA%\<app_id>\WebView2`.

## Working on Oriel itself

```sh
zig build check              # type-check (~1 s)
zig build test               # framework, tools and CLI unit tests
zig build cli                # the oriel CLI: zig-out/bin/oriel (static)
```

Windows builds cross-compile from Linux and can be tested there under Wine
or Steam's Proton, headlessly: see [docs/windows-testing.md](docs/windows-testing.md)
(`scripts/wine.sh`).

Releases are cut by pushing a `v*` tag: `.github/workflows/release.yml`
runs the tests, builds the CLI for x86_64 and aarch64 Linux and attaches
the binaries and `SHA256SUMS` to the GitHub release (`install.sh`
verifies against them).

Dependencies, including prebuilt GTK/WebKit bindings (zig-gobject, GNOME 50),
come from the Zig package manager. To use bindings generated from your own
system's GIR files instead (newer GTK/WebKit APIs), run
`scripts/gen-bindings.sh` (needs `xsltproc`) and build with
`--fork=deps/gobject/bindings`.

## The `oriel` CLI

A single static binary (no GTK needed to run it) that scaffolds apps and
wraps their build steps, like `create-tauri-app` and `tauri dev/build`.

```sh
# Install to ~/.local/bin (or $ORIEL_INSTALL_DIR); pin with ORIEL_VERSION=v0.1.0.
curl -fsSL https://raw.githubusercontent.com/highercomve/Oriel/main/install.sh | sh
# Or from a checkout: zig build cli && cp zig-out/bin/oriel ~/.local/bin/
```

| Command | What it does |
|---|---|
| `oriel init <name>` | New app in `./<name>`: build.zig, build.zig.zon, `src/main.zig` with sample `Commands`/`Events`, the frontend, README. Then adds Oriel (`zig fetch --save`), runs `zig build --fetch` and `npm install`, so the first build works offline |
| `oriel doctor` | Checks Zig 0.16.x, pkg-config + GTK 4 / WebKitGTK 6.0 development files, Node.js + npm, packaging tools, tray host and GlobalShortcuts portal; prints the install command for your distro (pacman, apt, dnf, zypper); exits non-zero if something required is missing |
| `oriel dev` / `build` / `run` / `package` / `types` / `check` | `zig build <step>` (plain `zig build` for `build`) from the project root, found by walking up to `build.zig.zon`; extra arguments are passed on, e.g. `oriel build -Doptimize=ReleaseFast`, `oriel run -- --flag` |
| `oriel --version` | CLI version and the Oriel ref `init` pins |

`oriel init` options:

- `--template react|vue|svelte|vanilla`: React (default), Vue and Svelte are
  Vite projects with typed `invoke`/`listen`; vanilla is a static page with
  no build step and no Node.js.
- `--id com.example.App`: the application id (default `com.example.<Name>`).
- `--oriel-ref <tag|commit>`: the Oriel version to depend on (default: the
  one the CLI was built for).
- `--oriel-path <dir>`: depend on a local Oriel checkout (`.path`), for
  working on Oriel itself.
- `--no-install`: only record the dependency; skip `zig build --fetch` and
  `npm install`.

The CLI runs `zig` from PATH, or `$ORIEL_ZIG` if set (useful when the
default `zig` is not 0.16).

## Building an app

An app is a normal Zig package that depends on Oriel through the Zig package
manager and calls `addApp` (see `examples/react`); `oriel init` sets this
up. To do it by hand, add the dependency with:

```sh
zig fetch --save git+https://github.com/highercomve/Oriel
```

That records Oriel's URL and hash in your `build.zig.zon`; `zig build`
downloads it and its dependencies (GTK/WebKit bindings, zigimg, http.zig,
zig-wayland, SQLite) into Zig's global cache. Pin a commit or tag by appending
`#<ref>` to the URL. You need the system libraries installed: GTK 4 and
WebKitGTK 6.0 (development packages), plus Node.js for Vite frontends.

```zig
// build.zig
const std = @import("std");
const oriel = @import("oriel");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("oriel", .{ .target = target, .optimize = optimize, .tray = false });
    _ = oriel.addApp(b, dep, .{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .frontend = .{ .dir = "frontend" }, // Vite defaults
    });
}
```

The examples in this repository use `.path = "../.."` instead, so they build
against the working tree while developing Oriel itself.

That gives the app these steps:

| Command | What it does |
|---|---|
| `zig build dev` | Starts Vite and opens the app on `http://localhost:5173` with hot reload; closing the window, Ctrl-C or a SIGTERM/SIGKILL to the `zig` process stops Vite and the app too |
| `zig build` | `npm install` (if needed) → generate types → `npm run build` → embed `dist/` → install the app |
| `zig build run` | Runs the production build |
| `zig build types` | Regenerates `frontend/src/oriel.ts` from the Zig `Commands` |
| `zig build check` | Type-checks the app's Zig code without building binaries |

Every module and plugin is on by default. Pass `.<name> = false` to
`b.dependency("oriel", ...)` to leave one out: it is then neither compiled
nor linked.

## Commands and events

```zig
// src/main.zig
pub const Commands = struct {
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(gpa, "Hello, {s}!", .{args.name});
    }
};

/// Pushed from Zig to the page.
pub const Events = struct { notes_changed: []const Note };
const events = oriel.App.events(Events);
// anywhere, any thread: events.emit(.notes_changed, notes);  (type-checked)

pub fn main(init: std.process.Init) !u8 {
    const app = @import("oriel_app"); // build-time: embedded assets / dev settings
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "com.example.App",
        .title = "App",
        .assets = app.assets,
        .dev = app.dev,
        .setup = setup,     // runs once the window exists: create the tray, …
        .on_close = .hide,  // keep running in the tray
    });
}
```

Apps that parse their own arguments can call
`oriel.App.run(init.io, api, config)` directly instead of `oriel.main`;
the `std.Io` is passed in explicitly (there is no global to set).

```ts
// frontend: generated from the Zig structs (zig build types)
import { invoke, listen } from "./oriel";
const msg = await invoke("greet", { name: "Ada" });   // msg: string
const off = listen("notes_changed", (notes) => …);    // notes: Note[]
```

Command errors reject the promise with the Zig error name.

### Async commands

By default, commands run on the GTK main thread. To avoid freezing the UI during slow operations (I/O, database queries, network requests), declare `pub const async_commands = .{ "cmd1", ... };` in `Commands`. Async commands run on a worker thread pool, receive `std.Io` if requested, and their reply is returned on the main thread without blocking the UI. Each async invocation gets its own arena allocator, freed after the reply is sent. (Cancellation is currently out of scope).

Blocking work started outside a command (a hotkey or tray callback, which run on the main
thread) goes to the same pool with `try oriel.App.spawn(func, .{args...})`; an error it
returns is logged. `App.quit` and `App.emit` are safe from any thread.

```zig
pub const Commands = struct {
    pub const async_commands = .{ "export_notes" };

    pub fn export_notes(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
        // Runs on worker thread pool; UI remains unblocked
        ...
    }
};
```

## Security

Modeled on Tauri. Configure it with `Config.security`:

```zig
.security = .{
    .csp = oriel.security.default_csp,               // null disables it
    .allowed_origins = &.{"https://docs.example.com"}, // may be shown, no IPC
    .capabilities = &.{                                // remote origins with IPC
        .{ .origin = "https://*.example.com", .commands = &.{"greet"} },
    },
    .external_links = .open_in_browser,                // or .deny
},
```

- **Navigation:** the webview only shows `app://app` (plus the dev server in
  dev builds) and the origins listed above. Everything else is blocked,
  including iframes, redirects and popups. Links the user clicks to other
  http(s)/mailto/tel URLs open in the default app.
- **IPC scope:** the app's own pages may call every command. Remote origins
  may call only what a capability grants. Each call is checked against the
  exact origin of the page currently shown.
- **Bridge:** `window.oriel` is injected only on pages allowed to use IPC.
- **CSP:** every `app://` response carries a strict Content-Security-Policy
  (no inline scripts, no `eval`) plus `X-Content-Type-Options: nosniff`.
  Dev builds serve pages from the dev server, which sets no CSP.
- **WebView settings:** scripts can't open windows; no `file://`
  cross-access; devtools only in Debug builds.

`examples/smoke` runs these checks inside the real webview (`--auto-quit`).

## Tray

```zig
fn setup() !void {
    tray = try oriel.tray.Tray.create(gpa, .{
        .id = "com.example.App",
        .title = "My App",
        .icon = .{ .png = @embedFile("icon.png") }, // or .{ .name = "theme-icon" }
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show" } },
            .{ .check = .{ .id = "dnd", .label = "Do not disturb" } },
            .separator,
            .{ .submenu = .{ .label = "Help", .items = &.{ .{ .item = .{ .id = "about", .label = "About" } } } } },
            .{ .item = .{ .id = "quit", .label = "Quit" } },
        },
        .on_menu = onMenu, // fn (id: []const u8, checked: ?bool) void
    });
}
```

Linux uses StatusNotifierItem + DBusMenu over D-Bus, and works with KDE,
GNOME (AppIndicator extension), waybar, Quickshell and other hosts.
Left-clicking the icon toggles the window. `setMenu`, `setChecked`,
`setTooltip`, `setTitle` and `setIcon` update the tray at runtime. If the
tray host restarts, the icon registers again.

## Window and lifecycle

`oriel.App.showWindow()`, `hideWindow()`, `toggleWindow()`, `quit(code)` and
`openExternal(url)`. `on_close = .hide` keeps the app running when the window
is closed. Apps are single-instance: launching again brings the window back.
SIGINT and SIGTERM shut down cleanly. The dev server stops with the app, even
when the app is killed. Under `oriel dev` / `zig build dev`, stopping only the
`zig` process (SIGTERM or SIGKILL, e.g. from a script) also stops everything:
`dev_runner` watches the `zig` process through a pidfd (the build runner in
between survives a signal sent to `zig` alone), dev_runner and the app get
`PR_SET_PDEATHSIG`, and `dev_runner` starts Vite
and the app in their own process groups and kills each whole group (SIGTERM,
then SIGKILL after 0.5 s) on exit. `zig build test-dev-cleanup` checks this.

## Testing without a desktop

```sh
scripts/headless.sh ./zig-out/bin/oriel-smoke --auto-quit      # Xvfb + private D-Bus
SHOT=shot.png scripts/headless.sh ./zig-out/bin/my-app            # screenshot after 4 s
```

## Plugins and system modules

### Global shortcuts (`oriel.global_shortcut`)

Registers global system-wide key combinations that trigger callbacks even when the application is unfocused or minimized:

```zig
try oriel.global_shortcut.register(gpa, .{
    .id = "rewrite_hotkey",
    .description = "GhostPen text rewrite hotkey",
    .trigger = "CTRL+ALT+G",
}, &onHotkey);
```

- **Wayland:** `org.freedesktop.portal.GlobalShortcuts`: the plugin registers the app id
  with the portal (`org.freedesktop.host.portal.Registry`), creates a session, binds the
  shortcuts (`BindShortcuts`, with `description` and `preferred_trigger`; the compositor may
  ask the user to confirm or pick other keys) and dispatches the session's `Activated`
  signals. Call `register` on the main thread (e.g. in `setup`); bind failures are logged.
  **The app id (`Config.id`) needs an installed `<id>.desktop` file**
  (e.g. `~/.local/share/applications/com.example.App.desktop`): xdg-desktop-portal refuses
  GlobalShortcuts to host apps without one. There is no X11 fallback on Wayland (XGrabKey only
  fires while an XWayland window has focus); without the portal `register` returns
  `error.PortalUnavailable`.
- **X11:** Uses `XGrabKey` with a GLib main loop watch on the X connection file descriptor.
- **Windows:** Uses Win32 `RegisterHotKey` / `WM_HOTKEY` routed through the hidden host window. Unregisters on `unregister` and `deinit`. Same trigger string syntax ("CTRL+ALT+G", etc.). Marshalling via `Shell.runOnMainThread`. Runtime untested on Windows.

### Input injection (`oriel.input`)

Simulates keyboard input and clipboard shortcuts:

```zig
try oriel.input.typeText("Hello from Zig!");
try oriel.input.keyCombo("ctrl+v");
try oriel.input.copy();
try oriel.input.paste();
```

- **Wayland:** Uses `zwp_virtual_keyboard_v1` with memfd XKB keymap upload.
- **X11:** Uses XTest extension (`XTestFakeKeyEvent`).
- **Windows:** Uses Win32 `SendInput` (UTF-16 Unicode pairs for text, virtual key combos for shortcuts). Extended keys set `KEYEVENTF_EXTENDEDKEY`. Runtime untested on Windows.

### Clipboard (`oriel.clipboard`)

Background and focused clipboard read/write for text and PNG images. Reads may wait
for another app (or for our own main loop, when we own the selection), so the blocking
reads belong on a worker thread and the main thread gets a callback API:

```zig
// Worker thread: an async command, or App.spawn from a hotkey/tray callback.
const text = try oriel.clipboard.readText(gpa);   // readImage -> ?PNG bytes
try oriel.clipboard.writeText("New content");      // any thread; writeImage(png)

// Main thread: never blocks, callback runs on the main thread.
oriel.clipboard.readTextAsync(onText, null);        // readImageAsync
```

- `readText`/`readImage` on the main thread return `error.WouldBlockMainThread` on Linux.
- **Wayland:** background reads (no window focus needed) via `ext_data_control_v1` on a
  private Wayland connection. Writes go through `GdkClipboard`.
- **X11 / no data-control:** `GdkClipboard`; worker reads are handed to the main loop.
- **Windows:** Uses Win32 `OpenClipboard` with retry loop. Text uses `CF_UNICODETEXT`. Images use registered `PNG` format (with IEND trimming) and standard `CF_DIB` (bottom-up DIB via `zigimg`). Worker threads marshal calls to the main thread via `Shell.runOnMainThread`. Async reads use `Shell.dispatchWithCleanup`. Runtime untested on Windows.
- When this process owns the selection (it offers a per-process marker MIME type), reads
  return the data we last wrote without a round-trip.

### Dialogs (`oriel.dialog`)

File picker dialogs using `GtkFileDialog` on Linux and `IFileOpenDialog` / `IFileSaveDialog` on Windows:

```zig
const file = try oriel.dialog.openFile(gpa, .{
    .title = "Select Document",
    .filters = &.{ .{ .name = "Text Files", .patterns = &.{ "*.txt", "*.md" } } },
});
```

- **Linux:** Uses `GtkFileDialog`.
- **Windows:** Uses COM `IFileOpenDialog` / `IFileSaveDialog` (with `FOS_PICKFOLDERS` for folder pickers, `FOS_ALLOWMULTISELECT` for multiple files) marshaled to the main thread via `Shell.runOnMainThread`. Runtime untested on Windows.

### Notifications (`oriel.notification`)

Desktop notifications via GIO `GNotification` (`GApplication.send_notification`) on Linux and `Shell_NotifyIconW` balloon tooltips on Windows:

```zig
try oriel.notification.notify(.{
    .title = "Processing Complete",
    .body = "Your notes have been exported successfully.",
});
```

- **Linux:** Uses GIO `GNotification`.
- **Windows:** Uses `Shell_NotifyIconW` with balloon notifications (`NOTIFYICON_VERSION_4`). Callbacks route via `Shell.WM_NOTIFY_CALLBACK` and remove the balloon on dismiss/timeout/shutdown. Runtime untested on Windows.

### Multiple windows and window options

Create and manage multiple windows at runtime with targeted or broadcast events:

```zig
const win = try oriel.App.openWindow(.{
    .label = "settings",
    .title = "Settings",
    .url = "settings.html",
    .width = 600,
    .height = 400,
    .min_width = 400,
    .min_height = 300,
    .resizable = true,
    .decorations = true,
    .remember_geometry = true, // saves size/state across app runs
});

// Window controls
win.setTitle("Preferences");
win.setSize(700, 450);
win.emit("refresh", .{}); // targeted to this window
oriel.App.emit("global_event", .{}); // broadcast to all windows

// Retrieve or close by label
if (oriel.App.getWindow("settings")) |w| w.show();
oriel.App.closeWindow("settings");
```

Per-window command scoping is supported via `.windows = &.{"main"}` in `Security.capabilities`.

### App menu bar (`oriel.menu`)

Native application menu bar: `GMenuModel` on Linux, Win32 `HMENU` + `HACCEL` on Windows:

```zig
const menu_items = [_]oriel.menu.MenuItem{
    .{
        .submenu = .{
            .label = "File",
            .items = &.{
                .{ .item = .{ .id = "new", .label = "New Note", .shortcut = "<Control>n" } },
                .{ .separator = {} },
                .{ .item = .{ .id = "quit", .label = "Quit", .shortcut = "<Control>q" } },
            },
        },
    },
};

fn onMenuAction(id: []const u8, checked: ?bool) void {
    if (std.mem.eql(u8, id, "quit")) oriel.App.quit(0);
}

try oriel.App.setMenu(&menu_items, onMenuAction);
```

- **Linux:** Uses GTK4 `GMenuModel` + `GtkApplication` actions.
- **Windows:** Uses Win32 window menus (`CreateMenu`, `AppendMenuW`) and accelerator tables (`CreateAcceleratorTableW`). Commands and hotkeys marshal through `Shell.runOnMainThread`. Runtime untested on Windows.

### Settings store (`oriel.store`)

Thread-safe JSON settings store with atomic writes, plus standard directory helpers (XDG on Linux, Known Folders Roaming/Local AppData on Windows):

```zig
const config_dir = try oriel.store.configDir(gpa, "dev.oriel.Notes");
const data_dir = try oriel.store.dataDir(gpa, "dev.oriel.Notes");
const cache_dir = try oriel.store.cacheDir(gpa, "dev.oriel.Notes");

var store = try oriel.store.Store.open(gpa, "dev.oriel.Notes", "settings");
defer store.deinit();

try store.set("theme", "dark");
try store.set("zoom", 1.25);
try store.save();

const theme = store.getString("theme");
```

- **Linux:** XDG directory specifications with glib atomic file utilities.
- **Windows:** Win32 Known Folders (`FOLDERID_RoamingAppData`, `FOLDERID_LocalAppData`) with `SRWLOCK` and `CreateFileW` / `FlushFileBuffers` / `MoveFileExW` atomic file replacement. Runtime untested on Windows.

### Media server (`oriel.media_server`)

Streams large local video/audio to the webview with HTTP range requests
(RFC 9110 §14), so `<video>` can seek in multi-GB files without loading them.
Two transports share the same Range parser and path checks
(`src/modules/media/range.zig`, `src/modules/media/open.zig`):

```zig
var media: oriel.media_server.Server = undefined; // fixed address until stop()
try media.start(io, gpa, .{
    .root_dir = "/home/me/Videos", // `/<path>` maps to files below it
    .port = 17893,                 // 127.0.0.1 only
    .allowed_origin = "app://app", // Access-Control-Allow-Origin on file routes
    .symlink_policy = .inside_root, // or .refuse_all
});
defer media.stop();
// Optional: the same files at app://app/media/<path> (fetch/XHR/<img> only)
try oriel.media_server.scheme.setRoot("/home/me/Videos", .inside_root);
```

- **Ranges:** `bytes=a-b`, `bytes=a-`, `bytes=-n` → `206` with `Content-Range`;
  unsatisfiable → `416` with `Content-Range: bytes */size`; a malformed header
  is ignored (`200`, full body); for several ranges only the first is served
  (one `206`, allowed by the RFC). `HEAD` is supported. Files are streamed in
  64 KiB chunks with u64 offsets (files over 4 GiB work).
- **Paths:** percent-decoded; NUL, backslashes, absolute paths and `..`
  segments get `403`. Files are opened with `openat2(RESOLVE_BENEATH)` relative
  to the root's fd, so the kernel refuses anything that resolves outside the
  root at open time (no check-then-open race). Symlinks: `.inside_root`
  (default) follows links that stay inside the root; `.refuse_all` refuses
  every symlink. Missing files and directories get `404`.
- **TCP vs `app://`:** the TCP server works with every client, `<video>`
  included, but any local process can connect to the port and the page needs
  CORS (`media-src` in the default CSP allows `http://127.0.0.1:*`). The
  `app://app/media/` route needs no port and no CORS, and its handler runs on
  the main thread (the file is read by GIO on a worker thread), but WebKitGTK's
  GStreamer media player only accepts http(s)/blob/data/file URLs, so
  `<video src="app://...">` fails with `MEDIA_ERR_SRC_NOT_SUPPORTED`. Use the
  TCP URL for `<video>`/`<audio>`.
- **Windows support:** on Windows, the media root is opened safely beneath the root directory via `CreateFileW` with heap-allocated UTF-16 path conversions, intermediate symlink/reparse point traversal rejection (`GetFinalPathNameByHandleW` lexical path comparison under `SymlinkPolicy.refuse_all`), and non-blocking traversal checks. WebView2 intercepts `https://app.localhost/media/*` requests and serves ranged media streams via a custom read-only COM `IStream` (`FileWindowStream`) over a duplicated handle using `OVERLAPPED` reads (no shared file pointer, no 16 MiB truncation cap, RFC-compliant 200/206 status codes, and checked COM calls). Runtime untested on Windows.

### Logging (`oriel.log`)

Automatic thread-safe routing of `std.log` to stderr and `$XDG_DATA_HOME/<app_id>/app.log`. In debug/dev builds, WebKit console messages are forwarded directly to stdout.

### Updater (`oriel.updater`)

Built-in self-updater featuring Ed25519 signature verification, atomic file replacement, throttled download progress streaming, and in-place restart.

#### 1. Key generation

Generate a new Ed25519 keypair using the framework or app build step:

```sh
zig build keygen -- --name myapp --out-dir ~/.config/myapp/keys
```

- Private key written to `$XDG_CONFIG_HOME/oriel/keys/<name>.key` (default) with file mode `0600` (refuses to overwrite existing files without `--force`).
- Public key written to `<name>.pub` (standard base64) and printed to stdout.

#### 2. Signing release artifacts

Sign an update artifact (raw binary, AppImage, or `.gz` archive) and produce a manifest JSON:

```sh
zig build sign-update -- zig-out/bin/my-app \
  --app-id com.example.App \
  --version 1.2.0 \
  --url https://releases.example.com/my-app-1.2.0 \
  --key ~/.config/myapp/keys/myapp.key \
  --out manifest.json
```

**Signed manifest format (`oriel-update-v2`):**
```json
{
  "app_id": "com.example.App",
  "version": "1.2.0",
  "target": "x86_64-linux",
  "format": "raw",
  "size": 1048576,
  "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  "url": "https://releases.example.com/my-app-1.2.0",
  "signature": "base64-encoded-ed25519-signature"
}
```

The signature is computed over domain-separated canonical bytes:
`"oriel-update-v2\n" ++ app_id ++ "\n" ++ version ++ "\n" ++ target ++ "\n" ++ format ++ "\n" ++ size ++ "\n" ++ sha256 ++ "\n" ++ url ++ "\n"` (plus optional `expires\n`).

#### 3. Embedding public key in the app

Configure `update_public_key` in `build.zig`:

```zig
_ = oriel.addApp(b, dep, .{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .frontend = .{ .dir = "frontend" },
    .update_public_key = "base64-public-key-string",
});
```

The public key is exposed at compile time via `@import("oriel_app").update_public_key`.

#### 4. JS IPC and runtime API

In `src/main.zig`, register the comptime-configured updater commands:

```zig
const app = @import("oriel_app");

const Updater = oriel.updater.Commands(.{
    .app_id = "com.example.App",
    .manifest_url = "https://releases.example.com/manifest.json",
    .current_version = "1.0.0",
    .public_key_b64 = app.update_public_key orelse @panic("missing update key"),
});

pub const Commands = struct {
    pub const updater_check = Updater.updater_check;
    pub const updater_install = Updater.updater_install;
    pub const updater_restart = Updater.updater_restart;

    pub const async_commands = .{ "updater_check", "updater_install", "updater_restart" };
};
```

For typed `listen` in the generated TypeScript, declare the progress event in your `Events` struct:
`@"updater://progress": struct { downloaded: u64, total: ?u64 }`.

From frontend TypeScript / JavaScript:

```ts
import { invoke, listen } from "./oriel";

// 1. Check for update
const update = await invoke("updater_check");
if (update?.available) {
    console.log(`Update ${update.version} available!`);

    // Listen to download progress events (throttled to ~10/s)
    const unlisten = listen("updater://progress", ({ downloaded, total }) => {
        console.log(`Downloaded ${downloaded} of ${total} bytes`);
    });

    // 2. Download and atomically install update
    await invoke("updater_install");
    unlisten();

    // 3. Restart running application
    await invoke("updater_restart");
}
```

#### 5. AppImage behavior

When running inside an AppImage (`$APPIMAGE` environment variable is set), `oriel.updater` automatically targets the outer AppImage executable for replacement and re-exec, keeping desktop launcher integrations seamless.

#### 6. Windows behavior

On Windows, running executables cannot be directly overwritten. `oriel.updater` downloads and verifies payloads next to the executable as `<exe>.new`, renames the running binary to `<exe>.old` using `MoveFileExW` (`MOVEFILE_REPLACE_EXISTING`), and promotes `<exe>.new` to `<exe>` (with automatic rollback on failure). Stale `.old` files are cleaned up on subsequent startup (`updater.init`). Application restart is performed via `CreateProcessW` using the original command line (`GetCommandLineW`). Runtime untested on Windows.

#### 7. Security notes

- **JS cannot choose URLs, keys, or paths**: The manifest URL, public key, and target path are configured strictly in native Zig code; frontend code cannot redirect downloads or bypass signature verification.
- **Private keys**: Never commit private keys to version control or bundle them into client applications. Use `keygen` with secure out-of-repo storage (`mode 0600`).
- **Transport**: Production manifest and payload URLs should always use HTTPS.

### SQLite and vector search (`oriel.sql`, `oriel.sqlite_vec`)

Oriel provides embedded SQLite database support and opt-in vector search via the `sqlite-vec` extension (`vec0` virtual tables).

#### Enabling sqlite-vec

- **Command-line flag:** `-Dsqlite_vec` (requires `sql`, which defaults to enabled).
- **In an app's `build.zig`:** pass `.sqlite_vec = true` in `b.dependency("oriel", ...)`:
  ```zig
  const oriel_dep = b.dependency("oriel", .{
      .target = target,
      .optimize = optimize,
      .sqlite_vec = true,
  });
  ```
- **Build time:** Amalgamation C compilation adds negligible overhead (~1–2 seconds cold).
- **License:** Dual-licensed MIT OR Apache-2.0.

#### Usage

When `sqlite_vec` is enabled, the extension is registered automatically into every database connection opened with `oriel.sql.Db.open`:

```zig
const oriel = @import("oriel");

// Open SQLite in-memory or on disk
const db = try oriel.sql.Db.open("data.db");
defer db.close();

// Create a vector table with 4-dimensional embeddings
try db.exec("CREATE VIRTUAL TABLE items USING vec0(embedding float[4]);");

// Insert vector embeddings (using oriel.sqlite_vec.asBytes helper)
var insert_stmt = try db.prepare("INSERT INTO items(rowid, embedding) VALUES (?, ?);");
defer insert_stmt.finalize();
const vec = [_]f32{ 1.0, 0.0, 0.0, 0.0 };
try insert_stmt.bindInt(1, 42);
try insert_stmt.bindBlob(2, oriel.sqlite_vec.asBytes(&vec));
_ = try insert_stmt.step();

// KNN vector search query
var query_stmt = try db.prepare(
    "SELECT rowid, distance FROM items WHERE embedding MATCH ? ORDER BY distance LIMIT 5;"
);
defer query_stmt.finalize();
const query_vec = [_]f32{ 0.9, 0.1, 0.0, 0.0 };
try query_stmt.bindBlob(1, oriel.sqlite_vec.asBytes(&query_vec));

while (try query_stmt.step()) {
    const id = query_stmt.int(0);
    const dist = query_stmt.float(1);
    std.log.info("Match id={d}, distance={d}", .{ id, dist });
}
```

### Local AI inference (`oriel.llama` and `oriel.whisper`)

Oriel provides opt-in native C/C++ inference bindings for [llama.cpp](https://github.com/ggml-org/llama.cpp) (text LLMs) and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (speech recognition).

#### Enabling llama and whisper

- **Command-line flags:** `-Dllama` for llama.cpp, `-Dwhisper` for whisper.cpp, or both `-Dllama -Dwhisper`.
- **In an app's `build.zig`:** pass `.llama = true` and/or `.whisper = true` in `b.dependency("oriel", ...)`:
  ```zig
  const oriel_dep = b.dependency("oriel", .{
      .target = target,
      .optimize = optimize,
      .llama = true,
      .whisper = true,
  });
  ```
- **Licenses:** MIT (both llama.cpp and whisper.cpp).

#### Shared GGML architecture

Both `llama.cpp` and `whisper.cpp` vendor GGML internally. To eliminate duplicate symbol collisions and ODR violations when both modules are enabled simultaneously, Oriel compiles a single unified instance of `ggml` and `ggml-cpu` (`build/ggml.zig`) and compiles both `llama` and `whisper` source files against that common instance.

#### Build times

- **sqlite-vec:** one C file, a second or two.
- **llama.cpp + whisper.cpp:** about 45 s cold (`zig build test -Dllama -Dwhisper`
  with an empty cache, 16 threads); cached rebuilds don't recompile them.
- **Default build overhead:** When omitted, nothing is downloaded, compiled or linked.

#### CPU architecture flags & distributable builds

`ggml-cpu` compiles architecture-optimized SIMD routines (e.g. AVX, AVX2, FMA, F16C on x86_64, NEON/ARMv8 on aarch64).
- By default, Zig targets the host machine CPU, compiling with full host CPU instructions.
- **For distributable release builds** (e.g. creating deb, rpm, or AppImage packages for distribution to end-user machines), specify a baseline CPU target to avoid illegal instruction crashes (`SIGILL`) on older hardware:
  ```sh
  zig build -Doptimize=ReleaseSafe -Dcpu=x86_64_v2 -Dllama -Dwhisper
  ```
  Or `-Dcpu=baseline` for maximum portability across 64-bit systems.

#### GPU backends (CUDA & Vulkan)

- **CUDA (Linux):** `-Dggml_cuda` (plus `-Dwhisper` and/or `-Dllama`) builds
  ggml's CUDA backend with `nvcc` into `libggml-cuda.so`; `addApp` installs it
  next to the executable. At runtime call `oriel.ggml_gpu.load(io)` before
  loading a model: it loads the backend from the executable's directory only
  and returns the number of GPUs (0 = CPU fallback, the app still works
  without an NVIDIA GPU or the library).
  - Needs the CUDA toolkit: `-Dcuda_path` (default `$CUDA_PATH` or
    `/opt/cuda`), `-Dcuda_arch` (nvcc `-arch`, default `native` = the GPUs
    of the build machine; use e.g. `all-major` for distribution).
  - First build compiles ~140 CUDA files (~3–4 min on 16 cores), cached after.
  - Why a separate library: nvcc's host code uses GCC's libstdc++ while Zig
    builds C++ against libc++; the ggml backend interface between them is
    plain C. The executable is linked with `rdynamic` so the library
    resolves ggml's symbols from it.
  - Measured (examples/ghostpen-lite, RTX 4070, 11 s clip, incl. model load):
    small 3.2 s on CPU → 0.8 s on CUDA; large-v3-turbo q8 1.1 s on CUDA.
- **Vulkan:** not supported yet (`-Dggml_vulkan` stops the build).

#### Multimodal (`mtmd`) status

- `libmtmd` (llama.cpp `tools/mtmd`: image/audio input for vision and audio
  models) is **not built yet**. It is buildable the same way (C++ sources plus
  header-only vendored `stb_image`, `miniaudio`, `subprocess.h`), but upstream
  marks the API experimental ("subject to many BREAKING CHANGES", `mtmd.h`)
  and no Oriel app uses it yet. `-Dllama_mtmd` fails with a build error until
  it is added.

#### Runtime API

##### llama.cpp (`oriel.llama`)

```zig
const oriel = @import("oriel");

// Optional: silence internal ggml/llama stderr logging
oriel.llama.silenceLogs();

// Initialize backend
oriel.llama.initBackend();
defer oriel.llama.deinitBackend();

// Inspect system CPU features detected by backend
const sys_info = try oriel.llama.systemInfo(gpa); // owned copy
defer gpa.free(sys_info);
std.log.info("Llama system info: {s}", .{sys_info});

// Load GGUF model with default params
const params = oriel.llama.modelDefaultParams();
const model = oriel.llama.loadModel("path/to/model.gguf", params) catch |err| {
    std.log.err("Failed to load model: {s}", .{@errorName(err)});
    return err;
};
defer model.deinit();
```

##### whisper.cpp (`oriel.whisper`)

```zig
const oriel = @import("oriel");

// Optional: silence internal ggml/whisper stderr logging
oriel.whisper.silenceLogs();

// Inspect whisper backend info
const sys_info = try oriel.whisper.systemInfo(gpa); // owned copy
defer gpa.free(sys_info);
std.log.info("Whisper system info: {s}", .{sys_info});

// Load GGML speech model with default context params
const params = oriel.whisper.contextDefaultParams();
const ctx = oriel.whisper.loadModel("path/to/whisper-base.bin", params) catch |err| {
    std.log.err("Failed to load whisper context: {s}", .{@errorName(err)});
    return err;
};
defer ctx.deinit();
```

## Packaging

Oriel provides integrated packaging for Linux distributions, portable AppImages, and Windows installer executables (`setup.exe`) with an extensible format architecture. Apps configure packaging metadata in `build.zig` via `.package` inside `oriel.addApp`.

### Packaging metadata

Metadata is configured once in `build.zig` and shared across all target package formats:

```zig
.package = .{
    .id = "dev.oriel.ReactNotes",          // Reverse-DNS application ID (matches desktop entry / registry uninstall key)
    .name = "Oriel React Notes",           // Display name (defaults to executable name)
    .summary = "Desktop notes app",        // Short comment / summary
    .description = "A desktop notes...",   // Multi-line description for package managers
    .publisher = "Acme Corp <dev@acme.com>", // Maintainer / Vendor / Publisher (set this; defaults to display name)
    .license = "MIT",                      // Optional SPDX license identifier (omitted if null)
    .homepage = "https://example.com",     // Optional project URL (omitted if null)
    .categories = "Utility;TextEditor;",   // Semicolon-delimited XDG desktop categories
    .version = "0.1.0",                    // Version string (defaults to "0.1.0")
    .icon = b.path("path/to/icon.png"),    // Optional PNG icon (defaults to Oriel brand icon; converted to .ico for Windows)
    .formats = null,                       // Optional override list of formats (defaults to per-OS list)
    .extra_deb_depends = &.{},             // Extra deb runtime dependencies
    .extra_rpm_depends = &.{},             // Extra rpm runtime dependencies
    .webview2_loader = null,               // Optional path to WebView2Loader.dll for Windows (or via -Dwebview2-loader)
},
```

> **Note on publisher**: Always set `.publisher` to your organization or maintainer contact info; if omitted, it defaults to the display name.

### Building packages

Running `zig build package` or format-specific package steps in an application directory builds production packages into `zig-out/package/`. All intermediate build files (`nfpm.yaml`, `AppDir`, SquashFS, `installer.nsi`) are isolated in Zig's cache directory:

- **All formats for target OS**: `zig build package` (defaults to `.deb`, `.rpm`, `.AppImage` on Linux; `.nsis` on Windows)
- **Debian package (`.deb`)**: `zig build package-deb` → `zig-out/package/<name>_<version>_<arch>.deb`
- **RPM package (`.rpm`)**: `zig build package-rpm` → `zig-out/package/<name>-<version>-1.<arch>.rpm`
- **AppImage (`.AppImage`)**: `zig build package-appimage` → `zig-out/package/<name>-<version>-<arch>.AppImage`
- **Windows Installer (`setup.exe`)**: `zig build package-nsis` (or `zig build package -Dtarget=x86_64-windows`) → `zig-out/package/<name>-<version>-setup.exe`

#### Requirements and tools

- **`makensis` (NSIS v3+)**: Used to compile the Windows installer executable (`setup.exe`). Looked up in `$PATH`, `/usr/bin/makensis`, and `/usr/local/bin/makensis` (the `nsis` package on Arch, Debian and Ubuntu). Cross-builds Windows installers directly from Linux hosts.
- **`nfpm`**: Used to generate `.deb` and `.rpm` packages. Looked up in `$PATH`, then `$HOME/go/bin/nfpm`.
- **`mksquashfs`**: Used to assemble AppImage SquashFS images.
- **`desktop-file-validate`**: Used to validate desktop entry files before packaging and installation.
- **AppImage Runtime**: Uses standard type-2 AppImage runtime (`runtime-<arch>`), automatically downloaded and cached in the local cache dir (overridable via `-Dappimage-runtime=<path>` or env `ORIEL_APPIMAGE_RUNTIME`). Verified for ELF header magic before use.

#### Windows NSIS installer details

The generated NSIS installer provides:
- **Per-user installation**: Installed to `$LOCALAPPDATA\Programs\<name>` without requiring administrator elevation (`RequestExecutionLevel user`).
- **Start Menu integration**: Shortcuts for launching the application and the uninstaller under `$SMPROGRAMS\<name>`.
- **Uninstaller**: Full uninstaller at `$INSTDIR\Uninstall.exe` registered in Windows Add/Remove Programs (`Software\Microsoft\Windows\CurrentVersion\Uninstall\<id>` under `HKCU`).
- **Multi-resolution ICO**: Automatically converts your PNG application icon into a multi-resolution Windows `.ico` (16, 32, 48, 64, 128, 256 px).
- **WebView2 Runtime Detection**: Checks the Windows Registry (HKCU and HKLM in both 64-bit and 32-bit views) for the Evergreen WebView2 Runtime (`{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}`). If missing, prompts the user to download and run the Microsoft Evergreen Bootstrapper (`https://go.microsoft.com/fwlink/p/?LinkId=2124703`) or opens the download page.
- **`WebView2Loader.dll`**: Required next to the executable on Windows. Specify it via `.webview2_loader` in `build.zig` or via CLI option `-Dwebview2-loader=<path>` (e.g. from the `Microsoft.Web.WebView2` NuGet package runtimes). Oriel loads it exclusively from the application's executable directory to prevent DLL search-order hijacking. User data is isolated per application in `%LOCALAPPDATA%\<app_id>\WebView2`.
- *Note*: Packaging a Windows application requires the target app executable to be compiled for Windows (which requires the Windows shell in `src/platform/windows`).

#### The AppImage caveat (system GTK4 & WebKitGTK 6.0)

The AppImage does not bundle GTK4 or WebKitGTK: it relies on the host's GTK4 and WebKitGTK 6.0 (install `gtk4` / `webkitgtk-6.0` or your distro's equivalent). WebKitGTK spawns helper processes (`WebKitWebProcess`, `WebKitNetworkProcess`) from fixed install paths and loads GPU, GStreamer and font stacks that must match the host, so relocating it into an AppImage needs patched paths and a much larger bundle; that is not done yet. The AppImage is therefore small (a few MB) and portable across distros that ship WebKitGTK 6.0, but not to systems without it.

#### Automatic dependency derivation

Runtime package dependencies for Debian and RPM packages are automatically derived from the Oriel features enabled in `build.zig`:
- Base: `libgtk-4-1` / `gtk4`, `libwebkitgtk-6.0-4` / `webkitgtk6.0`
- `global_shortcut`: `libx11-6` / `libX11`
- `input`: `libxkbcommon0` / `libxkbcommon`, `libxtst6` / `libXtst`
- `input` or `clipboard`: `libwayland-client0` / `libwayland-client`

### Adding formats

The packaging system is built around a pluggable `Format` enum and per-format dispatch in `build/package.zig`. To support additional packaging formats (such as Windows `msi` via WiX):
1. Add the enum value to `Format` (e.g. `msi`).
2. Add a corresponding `fn addMsi(ctx: *const Context) *std.Build.Step` function.
3. Add a branch to the `switch (format)` dispatcher in `addFormat`.
4. Include the format in `defaultFormats(os_tag)`.

When an unsupported OS target is packaged (or no formats are configured), `zig build package` fails gracefully at build time with a clear message (`"no package formats for <os> yet"`) via `b.addFail`.

### Development desktop entry (`zig build desktop-entry`)

Running `zig build desktop-entry` installs desktop integration files for local development into `$XDG_DATA_HOME` (`~/.local/share` fallback):

- **Desktop Entry**: `$XDG_DATA_HOME/applications/<id>.desktop` (validated with `desktop-file-validate`)
- **Icons**: `$XDG_DATA_HOME/icons/hicolor/<size>x<size>/apps/<id>.png` (sizes: 16, 32, 48, 64, 128, 256, 512)

#### Why install a development desktop entry?

1. **Wayland Global Shortcuts**: The `org.freedesktop.portal.GlobalShortcuts` portal requires an installed desktop entry matching the application ID to register system-wide hotkeys.
2. **Dev vs. Prod Isolation**: When a dev executable exists, the entry ID is suffixed with `.Dev` (e.g. `dev.oriel.ReactNotes.Dev`), `Name` is suffixed with `(Dev)`, and `Exec` points to the absolute path of the local dev binary in `zig-out/bin/`, preventing collisions with installed production applications.

## Compared with Tauri

| Tauri | Oriel (Linux) |
|---|---|
| Custom protocol for assets | ✅ `app://`, embedded at build time, SPA fallback |
| `invoke` / commands | ✅ plain Zig struct; TypeScript generated; sync & async worker pool |
| Events (`emit` / `listen`) | ✅ Zig → JS, type-checked on both sides; targeted (`window.emit`) & broadcast |
| Capabilities (command scopes) | ✅ per origin, per command, per window (`windows` list) |
| CSP, navigation limits, external links | ✅ |
| Isolation pattern | ❌ |
| Tray icon + menu | ✅ items, checkboxes, separators, submenus, runtime updates |
| Multiple windows | ✅ open/close, targeted events, geometry persistence, window options |
| App menu bar | ✅ Linux (`GMenuModel` + `GtkApplication` actions with shortcuts) + Windows (`HMENU` + `HACCEL`); runtime untested on Windows |
| Settings store | ✅ Linux (XDG paths + atomic thread-safe JSON store) + Windows (Known Folders + atomic JSON store); runtime untested on Windows |
| Logging | ✅ file + stderr logging + WebKit console forwarding |
| Close to tray, show/hide, single instance | ✅ |
| Dev server + hot reload / production build | ✅ `zig build dev` (Vite + Zig file watcher & reload) / `zig build` (defaults to `ReleaseSafe`) |
| Dialogs (open/save file) | ✅ Linux (`GtkFileDialog`) + Windows (`IFileOpenDialog` / `IFileSaveDialog`); runtime untested on Windows |
| System notifications | ✅ Linux (`GNotification`) + Windows (`Shell_NotifyIconW` balloon); runtime untested on Windows |
| Clipboard | ✅ Linux (GdkClipboard + Wayland ext-data-control) + Windows (CF_UNICODETEXT / CF_DIB / PNG); runtime untested on Windows |
| Global shortcuts | ✅ Linux (X11 XGrabKey + Wayland portal) + Windows (`RegisterHotKey`); runtime untested on Windows |
| Input injection | ✅ Linux (X11 XTest + Wayland virtual-keyboard) + Windows (`SendInput`); runtime untested on Windows |
| Asset protocol for local files (streaming, ranges) | ✅ `media_server`: 127.0.0.1 server with ranges for `<video>`; `app://app/media/` for fetch |
| Updater | ✅ Ed25519-signed manifests, atomic download & replace, progress events, in-place restart |
| Bundling (AppImage/deb/rpm), signing | ◐ AppImage, deb, rpm via `zig build package`; signing not yet implemented |
| `create-tauri-app`, `tauri dev/build`, `tauri info` | ✅ `oriel init` (React, Vue, Svelte, vanilla), `oriel dev/build/run/package`, `oriel doctor` |
| Windows | ◐ Win32 + WebView2 shell and every module/plugin (tray, sql, store, dialog, notification, menu, updater, media_server, fs_watch, global_shortcut, input, clipboard), NSIS `setup.exe`; cross-built from Linux, runtime untested on Windows |
| macOS, mobile | ❌ |

## Notes

- Executables link with LLVM + LLD: Zig 0.16's own linker rejects the
  `.sframe` sections in GCC 16 / recent glibc `crt1.o`.
- Dev builds use the app ID plus `.Dev`, so they can run next to the
  production app.

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.
