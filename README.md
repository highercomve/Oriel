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
- **Batteries included, opt-in:** tray, updater, SQLite, file watching, dialogs, notifications, global shortcuts, clipboard, packaging (deb, rpm, AppImage).

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
| `src/core/` | `App.zig` (windows, webview, menu, `app://` assets, dev mode), `ipc.zig` (command dispatch + TypeScript generation), `log.zig` (file + stderr logging) |
| `src/modules/` | Built-in modules: `tray`, `menu`, `store`, `dialog`, `notification`, `updater`, `media_server`, `sql`, `fs_watch` |
| `src/plugins/` | App-specific plugins: `global_shortcut`, `input`, `clipboard` |
| `tools/embed_assets.zig` | Embeds a built frontend directory into the binary |
| `tools/dev_runner.zig` | Hot reload orchestrator: keeps dev server running while watching `src/` and restarting the Zig app |
| `cli/` | The `oriel` command-line tool (`init`, `doctor`, build wrappers) and its embedded app templates |
| `install.sh` | Installs the `oriel` CLI from GitHub Releases |
| `examples/react/` | **App:** React + Vite notes app (own package) |
| `examples/smoke/` | **App:** checks every module (own package) |
| `examples/ghostpen-lite/` | **App:** hotkey -> read clipboard -> rewrite -> paste pipeline (own package) |

## Working on Oriel itself

```sh
zig build check              # type-check (~1 s)
zig build test               # framework, tools and CLI unit tests
zig build cli                # the oriel CLI: zig-out/bin/oriel (static)
```

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
| `zig build dev` | Starts Vite and opens the app on `http://localhost:5173` with hot reload; closing the window stops Vite |
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
when the app is killed.

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

- `readText`/`readImage` on the main thread return `error.WouldBlockMainThread`.
- **Wayland:** background reads (no window focus needed) via `ext_data_control_v1` on a
  private Wayland connection. Writes go through `GdkClipboard`.
- **X11 / no data-control:** `GdkClipboard`; worker reads are handed to the main loop.
- When this process owns the selection (it offers a per-process marker MIME type), reads
  return the data we last wrote without a round-trip.

### Dialogs (`oriel.dialog`)

File picker dialogs using `GtkFileDialog`:

```zig
const file = try oriel.dialog.openFile(gpa, .{
    .title = "Select Document",
    .filters = &.{ .{ .name = "Text Files", .patterns = &.{ "*.txt", "*.md" } } },
});
```

### Notifications (`oriel.notification`)

Desktop notifications via GIO `GNotification` (`GApplication.send_notification`):

```zig
try oriel.notification.notify(.{
    .title = "Processing Complete",
    .body = "Your notes have been exported successfully.",
});
```

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

Native GTK4 `GMenuModel` application menu bar:

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

### Settings store (`oriel.store`)

Thread-safe JSON settings store with atomic writes, plus standard XDG directory helpers:

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

#### 6. Security notes

- **JS cannot choose URLs, keys, or paths**: The manifest URL, public key, and target path are configured strictly in native Zig code; frontend code cannot redirect downloads or bypass signature verification.
- **Private keys**: Never commit private keys to version control or bundle them into client applications. Use `keygen` with secure out-of-repo storage (`mode 0600`).
- **Transport**: Production manifest and payload URLs should always use HTTPS.

## Packaging

Oriel provides integrated packaging for Linux distributions and portable AppImages with an extensible format architecture. Apps configure packaging metadata in `build.zig` via `.package` inside `oriel.addApp`.

### Packaging metadata

Metadata is configured once in `build.zig` and shared across all target package formats:

```zig
.package = .{
    .id = "dev.oriel.ReactNotes",          // Reverse-DNS application ID (matches GTK app ID)
    .name = "Oriel React Notes",           // Display name (defaults to executable name)
    .summary = "Desktop notes app",        // Short comment / summary
    .description = "A desktop notes...",   // Multi-line description for package managers
    .publisher = "Acme Corp <dev@acme.com>", // Maintainer / Vendor / Publisher (set this; defaults to display name)
    .license = "MIT",                      // Optional SPDX license identifier (omitted if null)
    .homepage = "https://example.com",     // Optional project URL (omitted if null)
    .categories = "Utility;TextEditor;",   // Semicolon-delimited XDG desktop categories
    .version = "0.1.0",                    // Version string (defaults to "0.1.0")
    .icon = b.path("path/to/icon.png"),    // Optional PNG icon (defaults to Oriel brand icon)
    .formats = null,                       // Optional override list of formats (defaults to per-OS list)
    .extra_deb_depends = &.{},             // Extra deb runtime dependencies
    .extra_rpm_depends = &.{},             // Extra rpm runtime dependencies
},
```

> **Note on publisher**: Always set `.publisher` to your organization or maintainer contact info; if omitted, it defaults to the display name.

### Building packages

Running `zig build package` or format-specific package steps in an application directory builds production packages into `zig-out/package/`. All intermediate build files (`nfpm.yaml`, `AppDir`, SquashFS) are isolated in Zig's cache directory:

- **All formats for target OS**: `zig build package`
- **Debian package (`.deb`)**: `zig build package-deb` → `zig-out/package/<name>_<version>_<arch>.deb`
- **RPM package (`.rpm`)**: `zig build package-rpm` → `zig-out/package/<name>-<version>-1.<arch>.rpm`
- **AppImage (`.AppImage`)**: `zig build package-appimage` → `zig-out/package/<name>-<version>-<arch>.AppImage`

#### Requirements and tools

- **`nfpm`**: Used to generate `.deb` and `.rpm` packages. Looked up in `$PATH`, then `$HOME/go/bin/nfpm`.
- **`mksquashfs`**: Used to assemble AppImage SquashFS images.
- **`desktop-file-validate`**: Used to validate desktop entry files before packaging and installation.
- **AppImage Runtime**: Uses standard type-2 AppImage runtime (`runtime-<arch>`), automatically downloaded and cached in the local cache dir (overridable via `-Dappimage-runtime=<path>` or env `ORIEL_APPIMAGE_RUNTIME`). Verified for ELF header magic before use.

#### The AppImage caveat (system GTK4 & WebKitGTK 6.0)

The AppImage does not bundle GTK4 or WebKitGTK: it relies on the host's GTK4 and WebKitGTK 6.0 (install `gtk4` / `webkitgtk-6.0` or your distro's equivalent). WebKitGTK spawns helper processes (`WebKitWebProcess`, `WebKitNetworkProcess`) from fixed install paths and loads GPU, GStreamer and font stacks that must match the host, so relocating it into an AppImage needs patched paths and a much larger bundle; that is not done yet. The AppImage is therefore small (a few MB) and portable across distros that ship WebKitGTK 6.0, but not to systems without it.

#### Automatic dependency derivation

Runtime package dependencies for Debian and RPM packages are automatically derived from the Oriel features enabled in `build.zig`:
- Base: `libgtk-4-1` / `gtk4`, `libwebkitgtk-6.0-4` / `webkitgtk6.0`
- `global_shortcut`: `libx11-6` / `libX11`
- `input`: `libxkbcommon0` / `libxkbcommon`, `libxtst6` / `libXtst`
- `input` or `clipboard`: `libwayland-client0` / `libwayland-client`

### Adding formats

The packaging system is built around a pluggable `Format` enum and per-format dispatch in `build/package.zig`. To support new packaging formats (such as Windows `nsis` via `makensis` or `msi` via WiX):
1. Add the enum value to `Format` (e.g. `nsis`, `msi`).
2. Add a corresponding `fn addNsis(ctx: *const Context) *std.Build.Step` function.
3. Add a branch to the `switch (format)` dispatcher in `addFormat`.
4. Include the format in `defaultFormats(.windows)`.

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
| App menu bar | ✅ `GMenuModel` + `GtkApplication` actions with shortcuts |
| Settings store | ✅ XDG paths + atomic thread-safe JSON store (`oriel.store`) |
| Logging | ✅ file + stderr logging + WebKit console forwarding |
| Close to tray, show/hide, single instance | ✅ |
| Dev server + hot reload / production build | ✅ `zig build dev` (Vite + Zig file watcher & reload) / `zig build` (defaults to `ReleaseSafe`) |
| Dialogs (open/save file) | ✅ `GtkFileDialog` |
| System notifications | ✅ `GNotification` |
| Clipboard | ◐ read/write via `GdkClipboard`; background reads on Wayland via ext-data-control; background writes on Wayland not yet |
| Global shortcuts | ✅ `XGrabKey` (X11) + `GlobalShortcuts` portal (Wayland) |
| Input injection | ✅ `XTest` (X11) + virtual keyboard protocol (Wayland) |
| Updater | ✅ Ed25519-signed manifests, atomic download & replace, progress events, in-place restart |
| Bundling (AppImage/deb/rpm), signing | ◐ AppImage, deb, rpm via `zig build package`; signing not yet implemented |
| `create-tauri-app`, `tauri dev/build`, `tauri info` | ✅ `oriel init` (React, Vue, Svelte, vanilla), `oriel dev/build/run/package`, `oriel doctor` |
| macOS, Windows, mobile | ❌ |

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
