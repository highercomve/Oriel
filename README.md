# ziguri

A Tauri-like desktop framework in Zig 0.16: a native window with the OS
webview, the frontend embedded in the binary, and typed JS ↔ Zig calls.
Linux (GTK4 + WebKitGTK 6.0) first. See [IDEA.md](IDEA.md) and
[LIBRARIES.md](LIBRARIES.md).

## Repository layout

The framework and the apps built with it are separate Zig packages:

| Path | What |
|---|---|
| `build.zig` | Framework build: the `ziguri` module, `embed_assets`, `dev_runner`, `addApp()` for apps, unit tests |
| `src/core/` | `App.zig` (windows, webview, menu, `app://` assets, dev mode), `ipc.zig` (command dispatch + TypeScript generation), `log.zig` (file + stderr logging) |
| `src/modules/` | Built-in modules: `tray`, `menu`, `store`, `dialog`, `notification`, `updater`, `media_server`, `sql`, `fs_watch` |
| `src/plugins/` | App-specific plugins: `global_shortcut`, `input`, `clipboard` |
| `tools/embed_assets.zig` | Embeds a built frontend directory into the binary |
| `tools/dev_runner.zig` | Hot reload orchestrator: keeps dev server running while watching `src/` and restarting the Zig app |
| `examples/react/` | **App:** React + Vite notes app (own package) |
| `examples/smoke/` | **App:** checks every module (own package) |
| `examples/ghostpen-lite/` | **App:** hotkey -> read clipboard -> rewrite -> paste pipeline (own package) |

## Setup

```sh
scripts/gen-bindings.sh      # once: GTK/WebKit bindings from /usr/share/gir-1.0
zig build test               # framework unit tests
```

`scripts/gen-bindings.sh` uses `zig` from `PATH` (or `$ZIG`) and needs `xsltproc`.

## Building an app

An app depends on ziguri and calls `addApp` (see `examples/react`):

```zig
// build.zig.zon
.dependencies = .{ .ziguri = .{ .path = "../.." } },

// build.zig
const ziguri = @import("ziguri");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("ziguri", .{ .target = target, .optimize = optimize, .tray = false });
    _ = ziguri.addApp(b, dep, .{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .frontend = .{ .dir = "frontend" }, // Vite defaults
    });
}
```

That gives the app these steps:

| Command | What it does |
|---|---|
| `zig build dev` | Starts Vite and opens the app on `http://localhost:5173` with hot reload; closing the window stops Vite |
| `zig build` | `npm install` (if needed) → generate types → `npm run build` → embed `dist/` → install the app |
| `zig build run` | Runs the production build |
| `zig build types` | Regenerates `frontend/src/ziguri.ts` from the Zig `Commands` |

Every module and plugin is on by default. Pass `.<name> = false` to
`b.dependency("ziguri", ...)` to leave one out: it is then neither compiled
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
const events = ziguri.App.events(Events);
// anywhere, any thread: events.emit(.notes_changed, notes);  (type-checked)

pub fn main(init: std.process.Init) !u8 {
    const app = @import("ziguri_app"); // build-time: embedded assets / dev settings
    return ziguri.main(init, .{ .commands = Commands, .events = Events }, .{
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
`ziguri.App.run(init.io, api, config)` directly instead of `ziguri.main`;
the `std.Io` is passed in explicitly (there is no global to set).

```ts
// frontend: generated from the Zig structs (zig build types)
import { invoke, listen } from "./ziguri";
const msg = await invoke("greet", { name: "Ada" });   // msg: string
const off = listen("notes_changed", (notes) => …);    // notes: Note[]
```

Command errors reject the promise with the Zig error name.

### Async commands

By default, commands run on the GTK main thread. To avoid freezing the UI during slow operations (I/O, database queries, network requests), declare `pub const async_commands = .{ "cmd1", ... };` in `Commands`. Async commands run on a worker thread pool, receive `std.Io` if requested, and their reply is returned on the main thread without blocking the UI. Each async invocation gets its own arena allocator, freed after the reply is sent. (Cancellation is currently out of scope).

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
    .csp = ziguri.security.default_csp,               // null disables it
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
- **Bridge:** `window.ziguri` is injected only on pages allowed to use IPC.
- **CSP:** every `app://` response carries a strict Content-Security-Policy
  (no inline scripts, no `eval`) plus `X-Content-Type-Options: nosniff`.
  Dev builds serve pages from the dev server, which sets no CSP.
- **WebView settings:** scripts can't open windows; no `file://`
  cross-access; devtools only in Debug builds.

`examples/smoke` runs these checks inside the real webview (`--auto-quit`).

## Tray

```zig
fn setup() !void {
    tray = try ziguri.tray.Tray.create(gpa, .{
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

`ziguri.App.showWindow()`, `hideWindow()`, `toggleWindow()`, `quit(code)` and
`openExternal(url)`. `on_close = .hide` keeps the app running when the window
is closed. Apps are single-instance: launching again brings the window back.
SIGINT and SIGTERM shut down cleanly. The dev server stops with the app, even
when the app is killed.

## Testing without a desktop

```sh
scripts/headless.sh ./zig-out/bin/ziguri-smoke --auto-quit      # Xvfb + private D-Bus
SHOT=shot.png scripts/headless.sh ./zig-out/bin/my-app            # screenshot after 4 s
```

## Plugins and system modules

### Global shortcuts (`ziguri.global_shortcut`)

Registers global system-wide key combinations that trigger callbacks even when the application is unfocused or minimized:

```zig
try ziguri.global_shortcut.register(gpa, .{
    .id = "rewrite_hotkey",
    .description = "GhostPen text rewrite hotkey",
    .trigger = "CTRL+ALT+G",
}, &onHotkey);
```

- **Wayland:** Uses `org.freedesktop.portal.GlobalShortcuts` via D-Bus session.
- **X11:** Uses `XGrabKey` with a GLib main loop watch on the X connection file descriptor.

### Input injection (`ziguri.input`)

Simulates keyboard input and clipboard shortcuts:

```zig
try ziguri.input.typeText("Hello from Zig!");
try ziguri.input.keyCombo("ctrl+v");
try ziguri.input.copy();
try ziguri.input.paste();
```

- **Wayland:** Uses `zwp_virtual_keyboard_v1` with memfd XKB keymap upload.
- **X11:** Uses XTest extension (`XTestFakeKeyEvent`).

### Clipboard (`ziguri.clipboard`)

Background and focused clipboard read/write for text and PNG images:

```zig
const text = try ziguri.clipboard.readText(gpa);
try ziguri.clipboard.writeText("New content");
```

- **Wayland:** Background clipboard via `ext_data_control_v1` (with `zwlr_data_control_v1` fallback).
- **X11 / Focused:** `GdkClipboard` (`setText`, `readTextAsync`, `setTexture`, `readTextureAsync`).

### Dialogs (`ziguri.dialog`)

File picker dialogs using `GtkFileDialog`:

```zig
const file = try ziguri.dialog.openFile(gpa, .{
    .title = "Select Document",
    .filters = &.{ .{ .name = "Text Files", .patterns = &.{ "*.txt", "*.md" } } },
});
```

### Notifications (`ziguri.notification`)

Desktop notifications via GIO `GNotification` (`GApplication.send_notification`):

```zig
try ziguri.notification.notify(.{
    .title = "Processing Complete",
    .body = "Your notes have been exported successfully.",
});
```

### Multiple windows and window options

Create and manage multiple windows at runtime with targeted or broadcast events:

```zig
const win = try ziguri.App.openWindow(.{
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
ziguri.App.emit("global_event", .{}); // broadcast to all windows

// Retrieve or close by label
if (ziguri.App.getWindow("settings")) |w| w.show();
ziguri.App.closeWindow("settings");
```

Per-window command scoping is supported via `.windows = &.{"main"}` in `Security.capabilities`.

### App menu bar (`ziguri.menu`)

Native GTK4 `GMenuModel` application menu bar:

```zig
const menu_items = [_]ziguri.menu.MenuItem{
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
    if (std.mem.eql(u8, id, "quit")) ziguri.App.quit(0);
}

try ziguri.App.setMenu(&menu_items, onMenuAction);
```

### Settings store (`ziguri.store`)

Thread-safe JSON settings store with atomic writes, plus standard XDG directory helpers:

```zig
const config_dir = try ziguri.store.configDir(gpa, "dev.ziguri.Notes");
const data_dir = try ziguri.store.dataDir(gpa, "dev.ziguri.Notes");
const cache_dir = try ziguri.store.cacheDir(gpa, "dev.ziguri.Notes");

var store = try ziguri.store.Store.open(gpa, "dev.ziguri.Notes", "settings");
defer store.deinit();

try store.set("theme", "dark");
try store.set("zoom", 1.25);
try store.save();

const theme = store.getString("theme");
```

### Logging (`ziguri.log`)

Automatic thread-safe routing of `std.log` to stderr and `$XDG_DATA_HOME/<app_id>/app.log`. In debug/dev builds, WebKit console messages are forwarded directly to stdout.

## Compared with Tauri

| Tauri | ziguri (Linux) |
|---|---|
| Custom protocol for assets | ✅ `app://`, embedded at build time, SPA fallback |
| `invoke` / commands | ✅ plain Zig struct; TypeScript generated; sync & async worker pool |
| Events (`emit` / `listen`) | ✅ Zig → JS, type-checked on both sides; targeted (`window.emit`) & broadcast |
| Capabilities (command scopes) | ✅ per origin, per command, per window (`windows` list) |
| CSP, navigation limits, external links | ✅ |
| Isolation pattern | ❌ |
| Tray icon + menu | ✅ items, checkboxes, separators, submenus, runtime updates |
| Multiple windows | ✅ open/close, targeted events, geometry persistence, window options |
| App menu bar | ✅ `GMenuModel` + `GtkApplication` actions with shortcuts |
| Settings store | ✅ XDG paths + atomic thread-safe JSON store (`ziguri.store`) |
| Logging | ✅ file + stderr logging + WebKit console forwarding |
| Close to tray, show/hide, single instance | ✅ |
| Dev server + hot reload / production build | ✅ `zig build dev` (Vite + Zig file watcher & reload) / `zig build` (defaults to `ReleaseSafe`) |
| Dialogs (open/save file) | ✅ `GtkFileDialog` |
| System notifications | ✅ `GNotification` |
| Clipboard (background & focused) | ✅ `GdkClipboard` (X11) + Data Control protocol (Wayland) |
| Global shortcuts | ✅ `XGrabKey` (X11) + `GlobalShortcuts` portal (Wayland) |
| Input injection | ✅ `XTest` (X11) + virtual keyboard protocol (Wayland) |
| Updater | ◐ signed manifests + unpacking; no download/install flow |
| Bundling (AppImage/deb/rpm), signing | ❌ |
| macOS, Windows, mobile | ❌ |

## Notes

- Executables link with LLVM + LLD: Zig 0.16's own linker rejects the
  `.sframe` sections in GCC 16 / recent glibc `crt1.o`.
- Dev builds use the app ID plus `.Dev`, so they can run next to the
  production app.
