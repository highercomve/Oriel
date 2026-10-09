# System modules and plugins

[Back to Oriel](../README.md) · [Documentation](README.md)

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
- **Android:** no system-wide hotkeys exist, so shortcuts are in-app: they fire while one of
  the app's windows has focus, from a hardware keyboard (desktop windowing, ChromeOS, DeX,
  tablets), before the page sees the key. Each `description` is listed in the system's
  keyboard shortcuts helper (Meta+/). Keys: letters, digits, F1–F12, navigation and
  punctuation. Call `register` once the app runs (e.g. in `setup`).
- **Windows:** Uses Win32 `RegisterHotKey` / `WM_HOTKEY` routed through the hidden host window. Unregisters on `unregister` and `deinit`. Same trigger string syntax ("CTRL+ALT+G", etc.). Marshalling via `Shell.runOnMainThread`. Runtime untested on Windows.
- **macOS:** Carbon `RegisterEventHotKey` (no permission needed); callbacks on the main thread. Modifiers map literally: `ctrl` = Control, `alt` = Option, `shift`, `super`/`cmd`/`meta`/`win` = Command. Registration fails with `error.HotkeyAlreadyRegistered` when another app holds the combination.

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
- **macOS:** `CGEvent` keyboard events (text as Unicode strings, layout independent); `copy`/`paste` send ⌘C/⌘V. Needs the **Accessibility** permission (System Settings → Privacy & Security → Accessibility; for an unbundled binary, the app that started it): without it every call returns `error.AccessibilityNotGranted` instead of posting events macOS would drop.

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
- **macOS:** `NSPasteboard` on the main thread (workers marshal there): text, and images written as PNG + TIFF (TIFF converted to PNG on read).
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
- **macOS:** `NSOpenPanel` / `NSSavePanel`, run modally on the main thread (the save panel confirms overwrites).

#### Folders with lasting write access

For apps that save into a folder the user chose once (e.g. received files), `openFolder` returns a
`Folder` whose `id` is an opaque string: store it, and it keeps working after restarts.

```zig
const folder = try oriel.dialog.openFolder(gpa, .{ .title = "Save received files to" }) orelse return; // null: cancelled
defer folder.deinit(gpa);
try store.put("save_dir", folder.id);

// Later, in any run, with the stored id: copies the file in, never replacing one ("photo (1).jpg" on a clash).
const saved_as = try oriel.dialog.saveToFolder(gpa, io, id, tmp_path, "photo.jpg", null); // mime: null = from the extension
const label = try oriel.dialog.folderName(gpa, io, id); // error.FolderUnavailable: revoked or gone, ask again
oriel.dialog.forgetFolder(id); // let the access go
```

| Platform | Picker | `id` | Access |
|---|---|---|---|
| Linux | `GtkFileDialog.selectFolder` (the portal where there is one) | absolute path | the user's |
| Windows | `IFileOpenDialog` + `FOS_PICKFOLDERS` | absolute path | the user's. `saveToFolder` refuses names Win32 programs couldn't open or delete afterwards (device names such as `CON` or `nul.txt`, a trailing dot or space, `<>:"\|?*` and control characters) with `error.InvalidName`, creating nothing; name clashes are case-insensitive |
| macOS | `NSOpenPanel` choosing directories | absolute path | the user's (Oriel apps aren't sandboxed; a sandboxed app would need a security-scoped bookmark) |
| Android | `ACTION_OPEN_DOCUMENT_TREE` | SAF tree URI | `takePersistableUriPermission` (read + write); `forgetFolder` releases it. `saveToFolder` uses `DocumentsContract.createDocument`, so the provider picks the " (1)" name, and returns it |
| iOS | not written yet (`error.Unsupported`); planned: `UIDocumentPickerViewController` for `.folder`, id = a base64 security-scoped bookmark | | |

These are Zig-only, like `openFile`/`saveFile` (expose them to the page through your own commands). On
Android and iOS `openFolder` waits for an Activity/view controller: call it from an async command.

### Notifications (`oriel.notification`)

Desktop notifications via GIO `GNotification` (`GApplication.send_notification`) on Linux and `Shell_NotifyIconW` balloon tooltips on Windows:

```zig
try oriel.notification.notify(.{
    .title = "Processing Complete",
    .body = "Your notes have been exported successfully.",
});
```

Clicks and buttons: give the notification an `id` and `actions`, then handle
clicks in Zig with `onAction` or in the page with the `notification:action`
event. `action` is the button's id, or null when the notification itself was
clicked; `id` is the notification's id (`""` when it had none).

```zig
oriel.notification.onAction(struct {
    fn f(id: []const u8, action: ?[]const u8) void {
        std.log.info("notification {s}: {s}", .{ id, action orelse "clicked" });
    }
}.f);

try oriel.notification.notify(.{
    .id = "export-42",
    .title = "Export ready",
    .body = "notes.pdf was saved.",
    .actions = &.{ .{ .id = "open", .label = "Open" }, .{ .id = "show", .label = "Show in folder" } },
});
```

```js
listen("notification:action", ({ id, action }) => { /* action === null: the notification was clicked */ });
```

Handlers run on the main thread. A click that came before there was a handler, or before the page listened (a tap that launched the app), is delivered to the first handler set and to the page when it calls `listen("notification:action")`. Buttons show on
Linux, macOS (`.app` bundles), iOS and Android (at most 3). Windows balloons
report a click on the balloon but have no buttons; the unbundled macOS
`osascript` fallback reports nothing. On Linux a click on the notification
also presents the main window, as before.

- **Linux:** Uses GIO `GNotification`; clicks and buttons activate the `app.oriel-notification` action.
- **Windows:** Uses `Shell_NotifyIconW` with balloon notifications (`NOTIFYICON_VERSION_4`). Callbacks route via `Shell.WM_NOTIFY_CALLBACK` and remove the balloon on dismiss/timeout/shutdown; a click on the balloon (`NIN_BALLOONUSERCLICK`) is reported, buttons are not available. Runtime untested on Windows.
- **macOS:** `UNUserNotificationCenter` in an `.app` bundle (macOS asks for permission on the first notification); buttons are a `UNNotificationCategory` per distinct set. Notifications also show while the app is in front, and the delegate is set at launch so clicks on earlier notifications are reported. An unbundled executable has no bundle id, which UserNotifications requires, so it falls back to `osascript` ("display notification", shown as Script Editor), with no click reporting.
- **Android:** a tap opens the app and reports the click; a button reports its id without opening the app and dismisses the notification.

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

**Theme colour.** A page's `<meta name="theme-color">` (the first whose `media` matches) is reported to the window in both renderers and on every change; the window's caption takes it where the platform draws one (Android's caption on ChromeOS and desktop Android). Elsewhere it is ignored.

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
- **macOS:** the app's menus go into the main menu between the default App menu (Hide, Quit) and the default Edit / Window menus (kept unless the app defines menus with those names). `<Ctrl>` / `<Primary>` shortcuts become ⌘, `<Alt>` ⌥.

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
- **macOS:** `~/Library/Application Support/<app_id>` (config and data) and `~/Library/Caches/<app_id>`; temp file (O_EXCL, 0600) + fsync + rename + directory fsync.

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
- **macOS support:** files are opened relative to the root's fd and the kernel's path of the opened file (`F_GETPATH`) must lie below the root (macOS 15 accepts `O_RESOLVE_BENEATH` but doesn't enforce it); `refuse_all` adds `O_NOFOLLOW_ANY`. `app://app/media/` streams through the `WKURLSchemeHandler`: a worker reads 256 KiB chunks, one in flight, delivered on the main thread; `<audio>`/`<video>` from the TCP server seek normally.

### Logging (`oriel.log`)

Thread-safe routing of `std.log` to stderr and a log file, once the app sets `pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };` in its `main.zig`:

| OS | Log file |
| --- | --- |
| Linux | `$XDG_DATA_HOME/<app_id>/app.log` (`~/.local/share/<app_id>/app.log`) |
| Windows | `%LOCALAPPDATA%\<app_id>\app.log` |
| macOS | `~/Library/Logs/<app_id>/app.log` (also listed in Console.app) |

The file is appended to and never rotated. On macOS it matters most: an app started from Finder or the Dock has no terminal, so stderr goes nowhere. In debug/dev builds, WebKit console messages are forwarded directly to stdout.

### SQLite and vector search (`oriel.sql`, `oriel.sqlite_vec`)

Oriel provides embedded SQLite database support and opt-in vector search via the `sqlite-vec` extension (`vec0` virtual tables).

#### Enabling sqlite-vec

- **Command-line flag:** `oriel build -Dsqlite_vec` (requires `sql`, which defaults to enabled).
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

### Deep links (`oriel.deep_link`)

Handles custom URL schemes (e.g. `myapp://...`), delivering incoming links to cold-starting instances as well as already-running application instances.

#### 1. Configuration in `build.zig`

Enable the module and declare URL schemes in `build.zig`:

```zig
const dep = b.dependency("oriel", .{
    .target = target,
    .optimize = optimize,
    .deep_link = true, // opt-in (default: false)
});

_ = oriel.addApp(b, dep, .{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .frontend = .{ .dir = "frontend" },
    .package = .{
        .id = "com.example.MyApp",
        .url_schemes = &.{ "myapp", "myapp-action" },
    },
});
```

Or run `oriel deep-link add <scheme>` to configure this automatically.

#### 2. Native Zig API

```zig
const oriel = @import("oriel");
const app = @import("oriel_app");

// Register a callback to receive incoming deep link URLs on the main thread:
if (oriel.options.deep_link) {
    oriel.deep_link.onOpen(onDeepLink);
}

fn onDeepLink(url: []const u8) void {
    std.log.info("Received deep link URL: {s}", .{url});
}

// In main(), pass deep_link_schemes to config:
return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
    .id = "com.example.MyApp",
    .title = "My App",
    .assets = app.assets,
    .deep_link_schemes = app.url_schemes,
});
```

To query the URL that launched the application at startup (null if launched normally):
```zig
const launch_url = oriel.deep_link.current();
```

#### 3. Webview frontend JavaScript / TypeScript

Every incoming link is broadcast to open webview windows as a `deep-link` event:

```ts
import { listen } from "./oriel";

// Listen for deep link events
const unlisten = listen("deep-link", ({ url }) => {
    console.log("Deep link received:", url);
});

// Query launch URL
const launchUrl = await window.oriel.deepLink.current();
```

#### 4. Delivery & Single-Instance Architecture

- **Linux:** GApplication single-instance command-line handling (`G_APPLICATION_HANDLES_COMMAND_LINE`). When a second instance is launched with a URL, the URL is forwarded over D-Bus to the primary instance, which restores/presents its window and delivers the URL; the second instance exits 0. On cold start, the URL is preserved in `current()` and delivered after the window is ready. Desktop packaging creates a `.desktop` file with `Exec=... %u` and `MimeType=x-scheme-handler/<s>;`.
- **Windows:** Single-instance named mutex (`Local\OrielApp_<sanitized_id>`). When a secondary instance starts, it detects the mutex, locates the primary instance's hidden host window (`FindWindowW`), forwards the validated URL via Win32 `WM_COPYDATA` (magic `0x44454550`), restores/focuses the main window, and exits 0. On cold start, the URL is parsed from `GetCommandLineW()`. NSIS installer registers keys under `HKCU\Software\Classes\<s>` and cleans them up on uninstall.
- **macOS:** The `.app` bundle declares the schemes in Info.plist `CFBundleURLTypes` (written by `oriel build` and `oriel package`). Launch Services delivers a link as a `kAEGetURL` Apple Event: to the running instance if there is one (single instance comes from Launch Services), otherwise it launches the app and the launch URL is kept for `current()` and delivered once the window is ready. A URL in argv (an unbundled executable started as `app myapp://...`) is handled like on Linux and Windows.

#### 5. Security & Validation

All incoming URLs are validated before delivery:
- Scheme must match one of the app's declared schemes.
- Scheme syntax must conform to RFC 3986 §3.1 (`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`).
- Maximum length is 2048 bytes (longer URLs are rejected).
- URLs containing control characters (ASCII `< 0x20` or `0x7F`) are rejected.
- URLs must parse successfully with `std.Uri.parse`.

### Text to speech (`oriel.tts`, `oriel.kokoro`, `oriel.audio_play`)

Reads text aloud offline using Kokoro-82M neural voices:

```zig
oriel.tts.init(init.io, init.gpa, models_dir);           // once, at startup
try oriel.tts.download("kokoro-82m-q8_0");                // model
try oriel.tts.download("af_heart");                       // voice pack
const r = try oriel.tts.speak(gpa, markdown_text, .{});   // from an async command
oriel.tts.stop();                                         // stop from any thread
```

- **Features:** offline synthesis, SHA-256 verified downloads, automatic language detection (`lang = "auto"`), Markdown read as prose, streaming playback via `audio_play.Stream`, warm-up ahead of first utterance (`oriel.tts.warmUp`), and GPU acceleration (`-Dggml_cuda`, `-Dggml_vulkan`, `-Dggml_metal`).
- **Phoneme data:** bundled espeak-ng runtime data compiled at build time into every `.kokoro = true` app across all desktop and mobile platforms.
- Complete documentation: [Offline text to speech](tts.md).

### Network and mDNS (`oriel.network`, `oriel.network.mdns`)

Service registration and browsing (DNS-SD / mDNS on the local link) through the platform's own responder, without multicast sockets, multicast locks, or special entitlements:

```zig
// Register a local service
const reg = try oriel.network.mdns.register(.{
    .type = "_my-service._tcp",
    .name = "MyDevice",
    .port = 8080,
    .txt = &.{.{ .key = "version", .value = "1.0" }},
});
defer reg.unregister();

// Browse services on the local network
const browser = try oriel.network.mdns.browse("_my-service._tcp", onServiceEvent, null);
defer browser.stop();

fn onServiceEvent(ctx: ?*anyopaque, event: *const oriel.network.mdns.Event) void {
    switch (event.*) {
        .found => |found| std.log.info("found: {s} at {s}:{d}", .{ found.name, found.addresses[0], found.port }),
        .lost => |lost| std.log.info("lost: {s}", .{ lost.name }),
    }
}
```

- **Android:** Uses `NsdManager` (`OrielMdns.kt`).
- **Windows:** Uses dnsapi's `DnsServiceRegister`, `DnsServiceBrowse`, and `DnsServiceResolve` (Windows 10 1809+). TXT values must be valid UTF-8.
- Requires `.permissions = .{ .local_network = "Find local devices" }` in `build.zig`.

### System sharing (`oriel.share`)

Receive shared files and text from other applications, and trigger the native system share sheet:

```zig
// Listen for incoming shares (also emits "share:received" event to webview)
oriel.share.onReceive(onShareReceived);

// Open system share sheet
try oriel.share.send(.{ .title = "Report", .text = "Sharing content" }, null, null);
```

- **Supported platforms:** Windows (`DataTransferManager`, "Send to", "Open with"), macOS/iOS (`NSSharingServicePicker`, `UIActivityViewController`, `CFBundleDocumentTypes`), and Android share targets.
- Receiving requires declaring `.share_target` in `build.zig`.
