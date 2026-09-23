# ziguri

A Tauri-like desktop framework in Zig 0.16: a native window with the OS
webview, the frontend embedded in the binary, and typed JS ↔ Zig calls.
Linux (GTK4 + WebKitGTK 6.0) first. See [IDEA.md](IDEA.md) and
[LIBRARIES.md](LIBRARIES.md).

## Repository layout

The framework and the apps built with it are separate Zig packages:

| Path | What |
|---|---|
| `build.zig` | Framework build: the `ziguri` module, the `embed_assets` tool, `addApp()` for apps, unit tests |
| `src/core/` | `App.zig` (window, webview, `app://` assets, dev mode), `ipc.zig` (command dispatch + TypeScript generation) |
| `src/modules/` | Built-in modules: `tray`, `updater`, `media_server`, `sql`, `fs_watch` |
| `src/plugins/` | App-specific plugins: `global_shortcut`, `input`, `clipboard` |
| `tools/embed_assets.zig` | Embeds a built frontend directory into the binary |
| `examples/react/` | **App:** React + Vite notes app (own package) |
| `examples/smoke/` | **App:** checks every module (own package) |

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

```ts
// frontend: generated from the Zig structs (zig build types)
import { invoke, listen } from "./ziguri";
const msg = await invoke("greet", { name: "Ada" });   // msg: string
const off = listen("notes_changed", (notes) => …);    // notes: Note[]
```

Command errors reject the promise with the Zig error name.

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

## Compared with Tauri

| Tauri | ziguri (Linux) |
|---|---|
| Custom protocol for assets | ✅ `app://`, embedded at build time, SPA fallback |
| `invoke` / commands | ✅ plain Zig struct; TypeScript generated |
| Events (`emit` / `listen`) | ✅ Zig → JS, type-checked on both sides |
| Capabilities (command scopes) | ✅ per origin, per command (no per-window scopes: there is one window) |
| CSP, navigation limits, external links | ✅ |
| Isolation pattern | ❌ |
| Tray icon + menu | ✅ items, checkboxes, separators, submenus, runtime updates |
| Close to tray, show/hide, single instance | ✅ |
| Dev server + hot reload / production build | ✅ `zig build dev` / `zig build` |
| Multiple windows, app menu bar | ❌ |
| Dialogs, notifications, clipboard, global shortcuts plugins | ❌ not exposed as APIs yet (smoke checks only) |
| Updater | ◐ signed manifests + unpacking; no download/install flow |
| Bundling (AppImage/deb/rpm), signing | ❌ |
| macOS, Windows, mobile | ❌ |

## Notes

- Executables link with LLVM + LLD: Zig 0.16's own linker rejects the
  `.sframe` sections in GCC 16 / recent glibc `crt1.o`.
- Dev builds use the app ID plus `.Dev`, so they can run next to the
  production app.
