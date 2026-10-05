# Building apps

[Back to Oriel](../README.md) · [Documentation](README.md)

## Building an app

An app is a normal Zig package that depends on Oriel through the Zig package
manager and calls `addApp`; `oriel init` sets this
up.

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

That provides the app developer workflow:

| Command | What it does |
|---|---|
| `oriel dev` | Starts Vite and opens the app on `http://localhost:5173` with hot reload; closing the window, Ctrl-C or a signal stops Vite and the app too |
| `oriel build` | `npm install` (if needed) → generate types → `npm run build` → embed `dist/` → compile production binary into `zig-out/bin/` |
| `oriel run` | Runs the production build |
| `oriel package` | Builds distribution packages into `zig-out/package/` (deb, rpm, AppImage on Linux; NSIS `setup.exe` on Windows) |
| `oriel types` | Regenerates `frontend/src/oriel.ts` from the Zig `Commands` |
| `oriel check` | Type-checks the app's Zig code without building binaries |

Every module and plugin is on by default. Pass `.<name> = false` to
`b.dependency("oriel", ...)` to leave one out: it is then neither compiled
nor linked.

### App icon

Oriel derives all platform icons from a single source PNG (1024×1024 recommended):

```zig
_ = oriel.addApp(b, dep, .{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .icon = b.path("icon.png"), // optional, defaults to Oriel brand icon
    ...
});
```

The embedded PNG bytes are accessible in `src/main.zig` via `app.icon_bytes` (`const app = @import("oriel_app");`) and passed to `oriel.main(..., .{ .icon = app.icon_bytes, ... })`.

At build time:
- **Windows**: The PNG is converted into a multi-resolution `.ico` (16, 24, 32, 48, 64, 256) and embedded directly into the executable via a Win32 resource (`RT_GROUP_ICON`). Windows Explorer, the taskbar, window title bar, Alt-Tab, Start-menu shortcuts, and the NSIS installer/uninstaller (`DisplayIcon`) use it automatically.
- **Linux**: Distribution packages (`.deb`, `.rpm`, `.AppImage`) install the icon into the hicolor icon theme (`/usr/share/icons/hicolor/<size>x<size>/apps/<id>.png`). The window icon name is set to the application ID. For unpackaged dev runs, `zig build desktop-entry` installs the icon into `$XDG_DATA_HOME/icons/hicolor/`.
- **macOS**: Converted into an Apple Icon Image (`icon.icns`) for `.app` bundles, and set dynamically on the Dock via `NSApp setApplicationIconImage:` for unbundled dev runs.

> **Using Oriel without the CLI**:
> To add Oriel to an existing Zig project manually, add the dependency with:
> ```sh
> zig fetch --save git+https://github.com/highercomve/Oriel
> ```
> This records Oriel's URL and hash in your `build.zig.zon`; `zig build` downloads it and its dependencies into Zig's global cache. Call `oriel.addApp()` in your `build.zig`. The build steps (`build`, `run`, `dev`, `package`, `types`, `check`) can then be invoked directly with `zig build <step>`.

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
// frontend: generated from the Zig structs (oriel types)
import { invoke, listen, openExternal } from "./oriel";
const msg = await invoke("greet", { name: "Ada" });   // msg: string
const off = listen("notes_changed", (notes) => …);    // notes: Note[]
await openExternal("https://ziglang.org");            // opens in default browser
```

Command errors reject the promise with the Zig error name.

### Error messages (`oriel.ipc.fail`)

A command that returns an error rejects the page's `invoke()` promise with the
error's name (`"EmptyName"`). To give the page a readable message instead:

```zig
pub fn fetch_models(_: std.mem.Allocator, args: struct { baseUrl: []const u8 }) ![]const []const u8 {
    return listModels(args.baseUrl) catch |err|
        oriel.ipc.fail("Could not reach {s} ({s})", .{ args.baseUrl, @errorName(err) });
}
```

### Platform (`platform`)

Every page gets the OS and CPU the app was built for, fixed per build:

```ts
import { platform } from "./oriel";   // or window.oriel.platform
platform.os;    // "linux" | "macos" | "windows" | "android" | "ios"
platform.arch;  // Zig's name: "x86_64", "aarch64", ...
const mod = platform.os === "macos" ? "⌘" : "Ctrl";   // shortcut labels
```

### System browser (`openExternal`)

To open links in the user's default browser instead of navigating the webview, use `openExternal(url)` (available as an export from `./oriel` and on `window.oriel.openExternal(url)`):
- On Linux, opens via the XDG desktop portal / `xdg-open`; on Windows, opens via `ShellExecuteW`; on macOS, via `NSWorkspace openURL:`.
- Only `http:`, `https:` and `mailto:` schemes are allowed by default (configurable in `Security.open_external_schemes`).
- Dangerous schemes (`file:`, `javascript:`, `data:`, `blob:`, `about:`) and control characters are always rejected.
- Gated by the capability model: remote origins must be granted the `open_external` command capability to call it.

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

### Windows from JavaScript (`oriel.window`)

JavaScript running in the webview can manage windows and open child windows via `oriel.window` (also exported from `frontend/src/oriel.ts`):

```ts
import { window } from "./oriel";

// Open a new child window
const child = await window.open({
  label: "child-win",
  url: "index.html?child=1",
  title: "Child Window",
  width: 600,
  height: 400,
  resizable: true,
});

// Window handle methods
await child.setTitle("New Title");
await child.setSize(800, 600);
await child.maximize();
await child.focus();
await child.emit("custom_event", { data: 123 });
await child.close();

// Query windows
const currentWin = window.current(); // WindowHandle for current window
const allWins = await window.all();  // WindowHandle[]
const win = await window.get("child-win");

// Targeted events
await window.emitTo("child-win", "ping", { data: 42 });

// Lifecycle events
import { listen } from "./oriel";
listen("window:created", (p) => console.log("Window created:", p.label));
listen("window:closed", (p) => console.log("Window closed:", p.label));
```

#### Window Security & Policy

Window creation and control are governed by `Config.security.window_api`:
- **Opt-in:** enabled by default for app-local origins (`app://app` and dev server). Remote origins are blocked by default unless granted by capability (`.window_api = true`) or `.allow_remote = true`.
- **URL validation:** only app-local URLs are allowed by default (`allow_remote_urls = false`). Dangerous schemes (`javascript:`, `file:`, `data:`) are rejected.
- **Label validation:** labels must be 1–64 characters containing only alphanumeric characters, underscores (`_`), and dashes (`-`).
- **Window modification:** windows can only modify and close themselves by default (`allow_modify_other_windows = false`).
- **Max window cap:** defaults to a maximum of 16 concurrent windows (`max_windows = 16`).

#### Config `window_open`

Configure the behavior of `window.open()` and links with `target="_blank"` navigating to allowed app-local URLs:

```zig
.window_open = .new_window, // .main_view (default: load in main view) or .new_window (open a new Oriel window)
```

## Security

Modeled on Tauri. Configure it with `Config.security`:

```zig
.security = .{
    .csp = oriel.security.default_csp,               // null disables it
    .allowed_origins = &.{"https://docs.example.com"}, // may be shown, no IPC
    .capabilities = &.{                                // remote origins with IPC
        .{ .origin = "https://*.example.com", .commands = &.{"greet", "open_external"} },
    },
    .external_links = .open_in_browser,                // or .deny
    .open_external_schemes = &.{ "http", "https", "mailto" }, // allowed schemes for openExternal
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

- **Hardening (opt-in):** `security.freeze_prototype = true` freezes
  `Object.prototype` before any page script runs (prototype pollution; code
  that assigns `Foo.prototype.toString = …` then throws in strict mode), and
  `security.headers` adds response headers to `app://` pages and media from
  an allowlist (COOP, COEP, CORP, Permissions-Policy, Access-Control-*, …).
  Mind the trade-offs: COOP `same-origin` breaks opener popups (OAuth), and
  COEP `require-corp` blocks cross-origin frames and subresources that don't
  opt in.

- **Inline code by hash:** the build hashes every inline `<script>` and
  `<style>` block of each HTML file (SHA-256) and adds the hashes to that
  page's CSP, so the app's own inline code runs without `'unsafe-inline'`
  while injected code doesn't. `security.strict_styles = true` also drops
  `'unsafe-inline'` from `style-src` (the app's `<style>` blocks keep working;
  `style="..."` attributes in the HTML and injected styles don't). A directive
  that still has `'unsafe-inline'` is left alone, since a hash would switch it
  off.

- **Isolation pattern (opt-in):** `.isolation = .{ .hook = b.path("isolation/hook.js") }`
  in `addApp`, and `.security = .{ .isolation = app.isolation }` in the
  config. Every call from the app's own pages (`app://` and the dev server),
  built-ins included, is first passed to the hook, which runs in a sandboxed
  frame the page can't reach and returns the call (or a modified one) or
  throws to reject it. The frame signs approved calls (HMAC-SHA256 with a key
  minted per frame load, never visible to the page, one-time sequence
  numbers), and Zig refuses anything unsigned or replayed. An XSS or a
  compromised dependency can then only call Zig through the hook. Remote
  capability origins are not covered: they keep the IPC token and their
  capabilities. Events from Zig to the page are unchanged. The hook is
  inlined into the frame's page, so it can't contain `</script` or `<!--`,
  and it has no network access. A custom `csp` must allow the isolation
  frame (`frame-src oriel.isolation.origin`; Oriel adds it to the default).

`examples/smoke` runs these checks inside the real webview (`--auto-quit`;
`-Disolation=false` builds it without the isolation hook).

### OS permissions (`oriel.permissions`)

Declare what the app needs once; Oriel writes it into the packages (macOS
`Info.plist` usage texts and entitlements), lets you check and request it, and
denies anything undeclared, including the webview's `getUserMedia`,
geolocation and notification requests:

```sh
oriel permission add microphone "Dictation turns your speech into text"
oriel permission add accessibility          # default reason text
oriel permission list
```

```zig
// build.zig (what `oriel permission add` writes)
.permissions = .{ .microphone = "Dictation turns your speech into text", .accessibility = "" },
// main.zig
.permissions = app.permissions,
```

```ts
import { permissions } from "./oriel";
if ((await permissions.request("microphone")) === "denied") await permissions.openSettings("microphone");
```

Kinds: `microphone`, `camera`, `screen_capture`, `accessibility`, `location`,
`notifications`, `system_audio`. Statuses: `granted`, `denied`, `prompt`,
`unknown`. See the [Permissions guide](https://highercomve.github.io/Oriel/docs/permissions/).

Platform declarations no kind covers go in each platform's options and are
merged with the generated ones, one entry per name or key (Linux packages
declare no permissions, so there is nothing for it):

```zig
.android = .{ .permissions = &.{.{ .name = "android.permission.BLUETOOTH", .max_sdk = 30 }},
              .features = &.{.{ .name = "android.hardware.bluetooth_le", .required = false }} },
.ios = .{ .usage_descriptions = &.{.{ .key = "NSMotionUsageDescription", .text = "Counts your steps" }} },
.macos = .{ .entitlements = &.{"com.apple.security.device.bluetooth"} },  // and .usage_descriptions
.windows = .{ .capabilities = &.{.{ .name = "proximity", .kind = .device }} },  // MSIX only
```

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
GNOME (AppIndicator extension), waybar, Quickshell and other hosts. macOS
uses an `NSStatusItem` in the menu bar (right-click or Control-click opens
the menu; the PNG is shown at 18 pt).
Left-clicking the icon toggles the window. `setMenu`, `setChecked`,
`setTooltip`, `setTitle` and `setIcon` update the tray at runtime. If the
tray host restarts, the icon registers again.

## Window and lifecycle

`oriel.App.showWindow()`, `hideWindow()`, `toggleWindow()`, `quit(code)` and
`openExternal(url)`. `on_close = .hide` keeps the app running when the window
is closed. Apps are single-instance: launching again brings the window back.
SIGINT and SIGTERM shut down cleanly. The dev server stops with the app, even
when the app is killed. Under `oriel dev`, stopping the process (Ctrl-C,
SIGTERM or SIGKILL, e.g. from a script) also stops everything: `dev_runner`
watches the process through a pidfd, `dev_runner` and the app get
`PR_SET_PDEATHSIG`, and `dev_runner` starts Vite and the app in their own
process groups and kills each whole group (SIGTERM, then SIGKILL after 0.5 s)
on exit.

### Routes and Single-Page Apps (SPA)

`WindowOptions.url` supports relative route paths such as `"/settings"`:
- In **development** (`config.dev`), the route resolves to the local dev server (e.g. `http://localhost:5173/settings`).
- In **production**, it resolves to the local embedded asset origin (`app://app/settings` on Linux and macOS, `https://app.localhost/settings` on Windows).
- Absolute URLs with schemes are checked against `allowed_origins` and `capabilities`, and dangerous schemes (`file:`, `javascript:`, `data:`, `blob:`, `about:`) are rejected.

**SPA Fallback caveat**:
With `config.spa_fallback = true` (default), deep links reload and serve `index.html` for client-side routers (such as React Router's `BrowserRouter`). However, paths whose last segment contains a dot (e.g. `/u/john.doe` or `/report.pdf`) are treated as asset files rather than routes and will return 404 if not found in embedded assets.
