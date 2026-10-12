//! Platform hooks in Zig (`oriel.hooks`): the app's own code sees each
//! window and web view Oriel creates, with its native handle, and can
//! configure it the platform's way (a WebKitGTK setting, an NSWindow
//! property, a WebView2 option) before the page loads.
//!
//! Desktop only (`available`): Linux, macOS and Windows. Android and iOS
//! hook their Activity, WebView and WKWebView natively instead (Kotlin
//! `.android.hooks`, Objective-C/Swift `.ios.hooks`; docs/platform-hooks.md);
//! there `subscribe` still succeeds, and no handler is ever called.
//!
//! | Hook | Linux | macOS | Windows |
//! |---|---|---|---|
//! | window_created / window_destroyed | GtkWindow* | NSWindow* | HWND |
//! | webview_created / webview_destroyed | WebKitWebView* | WKWebView* | ICoreWebView2* + ICoreWebView2Controller* |
//!
//! Order, per window: `window_created`, `webview_created` (after Oriel
//! installed its bridge, before the first navigation, before the window is
//! first shown), ..., `webview_destroyed`, `window_destroyed`. A native
//! renderer window (-Dnative_ui) has no web view: only the window hooks.

const std = @import("std");
const target = @import("target.zig");

const log = std.log.scoped(.hooks);

/// Whether this platform calls the hooks: desktop Linux, macOS, Windows.
pub const available = switch (target.os) {
    .linux, .macos, .windows => true,
    .android, .ios, .other => false,
};

/// A window's native handle. Valid from `window_created` until
/// `window_destroyed` returns; Oriel owns it (never destroy or release it).
pub const NativeWindow = union(enum) {
    /// `GtkWindow*` (a GtkApplicationWindow), Linux.
    gtk: *anyopaque,
    /// `NSWindow*`, macOS (main thread only, like every AppKit call).
    appkit: *anyopaque,
    /// `HWND`, Windows.
    win32: *anyopaque,
};

/// A web view's native handle. Valid from `webview_created` until
/// `webview_destroyed` returns; Oriel owns it (retain or AddRef it to keep
/// it longer, and never navigate it away from the app's page).
pub const NativeWebView = union(enum) {
    /// `WebKitWebView*` (WebKitGTK 6.0), Linux.
    webkitgtk: *anyopaque,
    /// `WKWebView*`, macOS.
    wkwebview: *anyopaque,
    /// WebView2, Windows.
    webview2: WebView2,

    pub const WebView2 = struct {
        /// `ICoreWebView2*`.
        core: *anyopaque,
        /// `ICoreWebView2Controller*` (bounds, visibility, zoom).
        controller: *anyopaque,
    };
};

pub const Window = struct {
    /// The window's label ("main", ...). Borrowed: valid during the call.
    label: []const u8,
    native: NativeWindow,
};

pub const WebView = struct {
    /// The label of the window that holds it. Borrowed: valid during the call.
    label: []const u8,
    native: NativeWebView,
};

/// What one subscriber wants to hear about; every field is optional.
/// Called on the main thread; a handler must not open or close windows.
pub const Handlers = struct {
    window_created: ?*const fn (window: Window) void = null,
    window_destroyed: ?*const fn (window: Window) void = null,
    webview_created: ?*const fn (webview: WebView) void = null,
    webview_destroyed: ?*const fn (webview: WebView) void = null,
};

pub const max_subscribers = 16;

var table: Table(max_subscribers) = .{};

/// Add `handlers` (any thread). Subscribe before `oriel.main` / `App.run`
/// to see the main window too (`App.Config.setup` runs after it opened);
/// windows that already exist are not replayed. Up to `max_subscribers`;
/// there is no unsubscribe.
pub fn subscribe(handlers: Handlers) error{TooManySubscribers}!void {
    return table.subscribe(handlers);
}

/// A platform backend (main thread): `window` exists and holds its web view
/// (`webview`, null for a native renderer window), bridge installed, first
/// navigation not started.
pub fn created(label: []const u8, window: NativeWindow, webview: ?NativeWebView) void {
    if (comptime !available) return;
    log.debug("window created: {s} ({s})", .{ label, @tagName(window) });
    table.dispatch(.window_created, .{ .label = label, .native = window });
    if (webview) |v| table.dispatch(.webview_created, .{ .label = label, .native = v });
}

/// A platform backend (main thread): `window` and its web view are about to
/// go (still alive).
pub fn destroyed(label: []const u8, window: NativeWindow, webview: ?NativeWebView) void {
    if (comptime !available) return;
    log.debug("window destroyed: {s}", .{label});
    if (webview) |v| table.dispatch(.webview_destroyed, .{ .label = label, .native = v });
    table.dispatch(.window_destroyed, .{ .label = label, .native = window });
}

pub const Kind = enum { window_created, window_destroyed, webview_created, webview_destroyed };

fn Arg(comptime kind: Kind) type {
    return switch (kind) {
        .window_created, .window_destroyed => Window,
        .webview_created, .webview_destroyed => WebView,
    };
}

/// The subscriber list: a fixed table filled in order. A slot is reserved
/// atomically, written, then published (`ready`), so any thread may
/// subscribe while the main thread dispatches.
pub fn Table(comptime capacity: usize) type {
    return struct {
        slots: [capacity]Handlers = @splat(.{}),
        ready: [capacity]std.atomic.Value(bool) = @splat(.init(false)),
        reserved: std.atomic.Value(usize) = .init(0),

        const Self = @This();

        pub fn subscribe(self: *Self, handlers: Handlers) error{TooManySubscribers}!void {
            const i = self.reserved.fetchAdd(1, .monotonic);
            if (i >= capacity) {
                _ = self.reserved.fetchSub(1, .monotonic);
                return error.TooManySubscribers;
            }
            self.slots[i] = handlers;
            self.ready[i].store(true, .release);
        }

        pub fn dispatch(self: *Self, comptime kind: Kind, arg: Arg(kind)) void {
            const n = @min(self.reserved.load(.acquire), capacity);
            // A slot reserved but not yet published is skipped: that
            // subscriber starts with the next event.
            for (self.slots[0..n], self.ready[0..n]) |*slot, *ready| {
                if (!ready.load(.acquire)) continue;
                if (@field(slot.*, @tagName(kind))) |h| h(arg);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Seen = struct {
    var buf: [64]u8 = undefined;
    var n: usize = 0;

    fn reset() void {
        n = 0;
    }
    fn mark(c: u8) void {
        buf[n] = c;
        n += 1;
    }
    fn got() []const u8 {
        return buf[0..n];
    }
    fn aWindow(w: Window) void {
        std.debug.assert(std.mem.eql(u8, w.label, "main"));
        mark('a');
    }
    fn aView(_: WebView) void {
        mark('A');
    }
    fn aWindowGone(_: Window) void {
        mark('x');
    }
    fn aViewGone(_: WebView) void {
        mark('X');
    }
    fn bWindow(_: Window) void {
        mark('b');
    }
    fn bView(_: WebView) void {
        mark('B');
    }
};

const fake_window: NativeWindow = .{ .gtk = @ptrFromInt(0x1000) };
const fake_view: NativeWebView = .{ .webkitgtk = @ptrFromInt(0x2000) };

test "Table: subscribers in registration order, only the hooks they set" {
    Seen.reset();
    var t: Table(4) = .{};
    t.dispatch(.window_created, .{ .label = "main", .native = fake_window }); // nobody yet
    try t.subscribe(.{ .window_created = Seen.aWindow, .webview_created = Seen.aView });
    try t.subscribe(.{ .window_created = Seen.bWindow });
    try t.subscribe(.{ .webview_created = Seen.bView });
    t.dispatch(.window_created, .{ .label = "main", .native = fake_window });
    t.dispatch(.webview_created, .{ .label = "main", .native = fake_view });
    t.dispatch(.window_destroyed, .{ .label = "main", .native = fake_window });
    try testing.expectEqualStrings("abAB", Seen.got());
}

test "Table: full at capacity, and stays usable" {
    Seen.reset();
    var t: Table(2) = .{};
    try t.subscribe(.{ .window_created = Seen.aWindow });
    try t.subscribe(.{ .window_created = Seen.bWindow });
    try testing.expectError(error.TooManySubscribers, t.subscribe(.{ .window_created = Seen.bWindow }));
    try testing.expectError(error.TooManySubscribers, t.subscribe(.{}));
    t.dispatch(.window_created, .{ .label = "main", .native = fake_window });
    try testing.expectEqualStrings("ab", Seen.got());
    try testing.expectEqual(@as(usize, 2), t.reserved.load(.monotonic));
}

test "Table: a reserved slot not yet published is skipped" {
    Seen.reset();
    var t: Table(2) = .{};
    try t.subscribe(.{ .window_created = Seen.aWindow });
    _ = t.reserved.fetchAdd(1, .monotonic); // another thread mid-subscribe
    t.slots[1] = .{ .window_created = Seen.bWindow };
    t.dispatch(.window_created, .{ .label = "main", .native = fake_window });
    try testing.expectEqualStrings("a", Seen.got());
    t.ready[1].store(true, .release);
    t.dispatch(.window_created, .{ .label = "main", .native = fake_window });
    try testing.expectEqualStrings("aab", Seen.got());
}

test "the global table holds 16" {
    var t: Table(max_subscribers) = .{};
    for (0..max_subscribers) |_| try t.subscribe(.{});
    try testing.expectError(error.TooManySubscribers, t.subscribe(.{}));
}

test "created and destroyed: window before web view, web view goes first" {
    if (comptime !available) return error.SkipZigTest;
    Seen.reset();
    const saved = table;
    defer table = saved;
    table = .{};
    try subscribe(.{
        .window_created = Seen.aWindow,
        .webview_created = Seen.aView,
        .window_destroyed = Seen.aWindowGone,
        .webview_destroyed = Seen.aViewGone,
    });
    created("main", fake_window, fake_view);
    destroyed("main", fake_window, fake_view);
    // A native renderer window: no web view hooks.
    created("main", fake_window, null);
    destroyed("main", fake_window, null);
    try testing.expectEqualStrings("aAXxax", Seen.got());
}

test available {
    try testing.expectEqual(target.os == .linux or target.os == .macos or target.os == .windows, available);
}
