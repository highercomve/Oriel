# Platform hooks

[Back to Oriel](../README.md) · [Documentation](README.md) · [Android platform hooks](android-extensions.md) · [App extensions](extensions.md)

A platform hook is the app's own code that the platform's own app, window
and web view events reach: a window or web view was created, an Activity
started, the page asked for a file chooser, the system opened a URL. A hook
reacts (configures the web view, keeps a reference, logs) or takes an event
over (returns "handled", and Oriel's default handling is skipped). Oriel
keeps its own clients, delegates and bridge; hooks sit next to them.

Platform hooks and [app extensions](extensions.md) are different tools:

| | Platform hooks | App extensions |
|---|---|---|
| Who calls | The platform (through Oriel), when its events happen | Your Zig code, by name (`oriel.extensions.get("name").call(...)`); the page through what Zig exposes |
| What for | React to or take over the app's, windows' and web views' own events | Your native code as a service: a camera SDK, an on-device model, a vendor API |
| Declared with | `.hooks` (per platform) | `AppOptions.extensions` |

One class may be both: an Android class can implement `OrielAndroidHooks`
and `OrielAppExtension`.

## Per platform

Hooks are declared with `.hooks` on every platform, in the platform's own
language:

| Platform | Language | Declared with | Interface |
|---|---|---|---|
| Android | Kotlin or Java | `.android.hooks` in `build.zig` (`.android.extensions` is its deprecated name) | `OrielAndroidHooks` (`OrielAndroidExtension`): Activity and WebView lifecycle, file chooser, activity and permission results ([details](android-extensions.md)) |
| iOS | Objective-C or Swift | `.ios.hooks` in `build.zig` | `@protocol OrielPlatformHooks` in `oriel_hooks.h` ([below](#ios-and-macos)) |
| macOS | Objective-C or Swift | `.macos.hooks` in `build.zig` | `@protocol OrielPlatformHooks` in `oriel_hooks.h` ([below](#ios-and-macos)) |
| Linux, Windows, macOS | Zig | `oriel.hooks.subscribe` at runtime | windows and web views with their native handles ([below](#zig-orielhooks)) |

macOS has both: Objective-C/Swift hooks for AppKit's app and window
callbacks, and the Zig hooks for code that already lives in Zig.

## Zig: `oriel.hooks`

The app's Zig code sees each window and web view Oriel creates, with its
native handle, and can configure it the platform's way (a WebKitGTK setting,
an NSWindow property, a WebView2 option) before the page loads. Linux, macOS
and Windows; `oriel.hooks.available` is false on Android and iOS, where
`subscribe` still succeeds and no handler is ever called (use the native
hooks there).

```zig
const oriel = @import("oriel");

pub fn main(init: std.process.Init) !u8 {
    // Before oriel.main, so the main window is seen too.
    if (oriel.hooks.available) try oriel.hooks.subscribe(.{
        .window_created = windowCreated,
        .webview_created = webViewCreated,
    });
    return oriel.main(init, api, config);
}

fn windowCreated(w: oriel.hooks.Window) void {
    std.log.info("window {s}: {s}", .{ w.label, @tagName(w.native) });
}

fn webViewCreated(v: oriel.hooks.WebView) void {
    switch (v.native) {
        // WebKitGTK's own API, through the handle.
        .webkitgtk => |view| if (comptime oriel.target.is_desktop_linux) {
            const settings = webkit_web_view_get_settings(view);
            webkit_settings_set_enable_smooth_scrolling(settings, 1);
        },
        .wkwebview, .webview2 => {},
    }
}

extern fn webkit_web_view_get_settings(view: *anyopaque) *anyopaque;
extern fn webkit_settings_set_enable_smooth_scrolling(settings: *anyopaque, enabled: c_int) void;
```

The showcase does this in `examples/showcase/src/platform_hooks.zig`.

### API

```zig
pub const available: bool; // Linux, macOS, Windows

pub const Handlers = struct {
    window_created: ?*const fn (window: Window) void = null,
    window_destroyed: ?*const fn (window: Window) void = null,
    webview_created: ?*const fn (webview: WebView) void = null,
    webview_destroyed: ?*const fn (webview: WebView) void = null,
};

pub const max_subscribers = 16;
pub fn subscribe(handlers: Handlers) error{TooManySubscribers}!void;

pub const Window = struct { label: []const u8, native: NativeWindow };
pub const WebView = struct { label: []const u8, native: NativeWebView };

pub const NativeWindow = union(enum) {
    gtk: *anyopaque, // GtkWindow* (a GtkApplicationWindow), Linux
    appkit: *anyopaque, // NSWindow*, macOS
    win32: *anyopaque, // HWND, Windows
};

pub const NativeWebView = union(enum) {
    webkitgtk: *anyopaque, // WebKitWebView* (WebKitGTK 6.0), Linux
    wkwebview: *anyopaque, // WKWebView*, macOS
    webview2: struct {
        core: *anyopaque, // ICoreWebView2*
        controller: *anyopaque, // ICoreWebView2Controller*
    },
};
```

- **Subscribing.** `subscribe` takes a struct of optional handlers; set the
  ones you need. Up to 16 subscriptions; there is no unsubscribe. It may be
  called from any thread. Subscribe before `oriel.main` (or `App.run`) to
  see the main window: `App.Config.setup` runs after it opened, and windows
  that already exist are not replayed.
- **Threads and order.** Handlers run on the main thread, in subscription
  order. Per window: `window_created`, then `webview_created`; at the end
  `webview_destroyed`, then `window_destroyed`. Return quickly, and don't
  open or close windows from a handler.
- **When.** The created hooks run once the window holds its web view and
  Oriel has installed its bridge (the `window.oriel` script, the asset
  scheme handler, navigation and permission policy), before the first
  navigation and before the window is first shown.
  The destroyed hooks run when Oriel destroys the window (closed, or the
  app quitting on Linux and macOS; on Windows, windows still open at quit go
  with the process, without the hooks), while both are still alive.
- **Lifetime.** `label` is borrowed: copy it to keep it. A native handle is
  valid from its created hook until its destroyed hook returns. Oriel owns
  it: don't destroy, close or release it (retain or `AddRef` it to keep an
  object longer, and drop that reference by the destroyed hook).
- **What to leave alone.** Oriel's handlers on the web view (WebKitGTK's
  `decide-policy` and `permission-request`, the WKWebView navigation and UI
  delegates, WebView2's event handlers), its user scripts and message
  handlers, and the page it loads. Settings, extra signal handlers, extra
  user scripts of your own and window properties are fine.
- **Native renderer windows** (`-Dnative_ui`) have no web view: only the
  window hooks run.

## Android

`.android.hooks` registers Kotlin or Java classes that implement
`OrielAndroidHooks` (a Kotlin `typealias` of `OrielAndroidExtension`, the
interface's name before Oriel 0.11, which Java classes implement):

```zig
.android = .{
    .sources = &.{b.path("src/android/MyHooks.kt")},
    .hooks = &.{"dev.example.MyHooks"},
},
```

```kotlin
class MyHooks : OrielAndroidHooks {
    override fun onWebViewCreated(view: WebView, windowLabel: String) {
        if (windowLabel == "main") view.settings.textZoom = 110
    }
}
```

The interface has Activity lifecycle callbacks, WebView created / attached /
detached / destroyed (after Oriel installs its clients and bridge, before
navigation), `onShowFileChooser` (return `true` to own the request), and
activity and permission results with a request-code range per class.
`.android.extensions`, the deprecated name, still works: its classes are
registered after the `.android.hooks` ones, and a class named in both is
registered once. [Android platform hooks](android-extensions.md) has the
details: registration, lifetimes, request codes, file choosers, Maven SDKs
and vendor libraries.

## iOS and macOS

<!-- apple-hooks: filled in from docs/platform-hooks-apple.md -->

Objective-C or Swift classes declared with `.ios.hooks` and `.macos.hooks`
adopt `@protocol OrielPlatformHooks` from `oriel_hooks.h`. Every method is
optional:

- `registered:`, once, with the hook's context.
- `webViewConfiguration:window:`, to adjust the `WKWebViewConfiguration`
  before the web view is made; `webViewCreated:window:` (bridge installed,
  before the first navigation) and `webViewDestroyed:window:`.
- Navigation policy and media capture: return `YES` to own the decision
  (and call the decision handler yourself); `NO` leaves it to Oriel.
- `openURL:` and `continueUserActivity:` (universal links, Handoff).
- Push notifications: the device token, and registration failures.
- iOS scene and app callbacks; macOS app and window callbacks.
