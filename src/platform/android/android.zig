//! Android platform backend for Oriel: a Kotlin Activity per window hosting
//! android.webkit.WebView, driven from Zig over JNI (`liboriel.so`).
//!
//! - `entry.zig`: `NativeLib.start` runs the app's `main` on its own thread.
//! - `Shell.zig`: the UI thread's task queue (ALooper), `run`, `quit`.
//! - `window.zig`: windows (the Kotlin registry by id), the navigation policy.
//! - `bridge.zig`: `window.oriel` over a WebMessageListener, IPC checks.
//! - `scheme.zig`: the app's assets for `https://app.localhost`.
//! - `exports.zig`: the other `NativeLib` natives; `runtime.zig`: calls into
//!   `OrielRuntime`; `jni.zig`: the JNI bindings.
//!
//! The Kotlin side ships in the Gradle template (`oriel android init`).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const App = @import("../../core/App.zig");
const log = std.log.scoped(.oriel);

pub const window = @import("window.zig");
pub const ShellMod = @import("Shell.zig");
pub const bridge = @import("bridge.zig");
pub const scheme = @import("scheme.zig");
pub const runtime = @import("runtime.zig");
pub const jni = @import("jni.zig");
pub const paths = @import("paths.zig");
pub const entry = @import("entry.zig");

pub const WindowHandle = window.WindowHandle;
pub const WindowSize = window.WindowSize;
pub const Mutex = ShellMod.Mutex;

pub const showWindow = window.showWindow;
pub const hideWindow = window.hideWindow;
pub const toggleWindow = window.toggleWindow;
pub const closeWindow = window.closeWindow;
pub const postCloseWindow = window.postCloseWindow;
pub const focusWindow = window.focusWindow;
pub const destroyWindow = window.destroyWindow;
pub const setWindowTitle = window.setWindowTitle;
pub const setWindowFullscreen = window.setWindowFullscreen;
pub const isWindowFullscreen = window.isWindowFullscreen;
pub const setWindowMaximized = window.setWindowMaximized;
pub const isWindowMaximized = window.isWindowMaximized;
pub const setWindowSize = window.setWindowSize;
pub const getWindowSize = window.getWindowSize;
pub const setWindowPlacement = window.setWindowPlacement;
pub const setWindowClickThrough = window.setWindowClickThrough;
pub const setWindowAlwaysOnTop = window.setWindowAlwaysOnTop;
pub const getWindowWorkArea = window.getWindowWorkArea;
pub const startWindowDrag = window.startWindowDrag;
pub const openExternal = window.openExternal;
pub const dispatchWithCleanup = ShellMod.dispatchWithCleanup;

pub const evalJs = bridge.evalJs;
pub const evalJsByLabel = bridge.evalJsByLabel;
pub const emitEvent = bridge.emitEvent;
pub const quit = ShellMod.quit;
pub const setMenu = ShellMod.setMenu;
pub const createWindow = ShellMod.createWindow;

pub fn run(io: std.Io, comptime api: anytype, comptime config: anytype) u8 {
    const S = ShellMod.Shell(api, config);
    return S.run(io);
}

/// For the generated library root (`oriel.addApp`): export the app's
/// `NativeLib.start`.
pub const exportStart = entry.exportStart;
/// Panic handler that reaches logcat.
pub const panic = entry.panic;

/// A button on the foreground service's notification: tapping it sends the
/// system event "action" with `id`.
pub const Action = struct { id: []const u8, label: []const u8 };

/// Keep the app running in the background with an ongoing notification (a
/// foreground service of type `microphone`, which Android requires to keep
/// capturing audio while no window is in front), with `actions` as buttons.
/// While it runs, the headset button sends "media-button". `on = false`
/// stops it. Needs the microphone permission first. Any thread.
pub fn setForegroundService(on: bool, title: []const u8, text: []const u8, actions: []const Action) !void {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(heap.gpa);
    for (actions) |a| try lines.print(heap.gpa, "{s}\t{s}\n", .{ a.id, a.label });
    const Ctx = struct {
        on: bool,
        title: []const u8,
        text: []const u8,
        actions: []const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "setForegroundService", "(Z[B[B[B)Z", .{ self.on, self.title, self.text, self.actions }) orelse false;
        }
    };
    var ctx: Ctx = .{ .on = on, .title = title, .text = text, .actions = lines.items };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.ForegroundServiceFailed;
}

/// A system entry point that replaces a desktop hotkey or tray menu (see
/// OrielSystem.kt): "tile", "action" (data: the action's id),
/// "media-button" (data: the key code), "ime-mic", "ime-open" (data: the
/// field's input type), "ime-close"; and "trim-memory" (data: the
/// `ComponentCallbacks2` level, e.g. "20" UI hidden, "40" background), a
/// cue to drop caches or unload models. Called on the main thread; the page
/// also gets an `android:event` event with `{ name, data }`.
pub const SystemEventHandler = *const fn (name: []const u8, data: []const u8) void;

var system_event_handler: ?SystemEventHandler = null;

pub fn onSystemEvent(handler: ?SystemEventHandler) void {
    system_event_handler = handler;
}

fn nativeSystemEvent(env: *jni.Env, _: jni.jclass, name_arr: jni.jobject, data_arr: jni.jobject) callconv(.c) void {
    const gpa = heap.gpa;
    const name = (env.bytesAlloc(gpa, name_arr) catch return) orelse return;
    defer gpa.free(name);
    const data = (env.bytesAlloc(gpa, data_arr) catch return) orelse &.{};
    defer if (data.len > 0) gpa.free(data);
    if (std.mem.eql(u8, name, "trim-memory")) trimMemory(std.fmt.parseInt(i32, data, 10) catch 0);
    if (system_event_handler) |h| h(name, data);
    App.emit("android:event", .{ .name = name, .data = data });
}

comptime {
    @export(&nativeSystemEvent, .{ .name = "Java_dev_oriel_NativeLib_onSystemEvent" });
}

/// `ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW`: from here on (running low,
/// UI hidden, background...) bionic's allocator gives its cached free pages
/// back to the system. Oriel's own allocations use it (core/heap.zig), and
/// so does the app's `gpa`.
const trim_memory_running_low = 10;
/// <malloc.h>: purge the allocator's caches (API 28+).
const M_PURGE = -101;
extern "c" fn mallopt(option: c_int, value: c_int) c_int;

fn trimMemory(level: i32) void {
    if (level < trim_memory_running_low) return;
    _ = mallopt(M_PURGE, 0);
    log.info("trim-memory {d}: purged the malloc caches", .{level});
}

/// Open `client`'s connection to `uri`'s host with Android's resolver, so
/// that the next `client.request` to that host reuses it. Needed before
/// every HTTP request from Zig: std.Io resolves names itself from
/// /etc/resolv.conf, which Android doesn't have (apps resolve through
/// netd), so `std.http.Client` alone fails with error.NameServerFailure.
/// Here bionic's getaddrinfo finds the address and the connection is made
/// to it, with the host name still used for TLS (SNI, certificate) and as
/// the pool key. Redirects to another host need the same: handle them
/// yourself (`.redirect_behavior = .unhandled`) and call this for each.
pub fn preconnect(client: *std.http.Client, uri: std.Uri) !void {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = try uri.getHost(&host_buf);
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    // What `client.request` does before its first TLS connection: load the
    // CA certificates (bionic's /system/etc/security/cacerts) and the time.
    if (protocol == .tls and client.now == null) {
        const io = client.io;
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);
        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.CertificateBundleLoadFailure,
        };
        try client.ca_bundle_lock.lock(io);
        defer client.ca_bundle_lock.unlock(io);
        if (client.now == null) {
            client.now = now;
            std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
        }
    }
    var ip_buf: [48]u8 = undefined;
    const ip = try resolve(host.bytes, &ip_buf);
    const conn = try client.connectTcpOptions(.{
        .host = try .init(ip),
        .port = port,
        .protocol = protocol,
        .proxied_host = host,
        .proxied_port = port,
    });
    client.connection_pool.release(conn, client.io);
}

/// `name`'s first address as text (IPv4 first, else IPv6), via bionic.
fn resolve(name: []const u8, buf: *[48]u8) ![]const u8 {
    var name_buf: [std.Io.net.HostName.max_len + 1]u8 = undefined;
    if (name.len >= name_buf.len) return error.NameTooLong;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    const name_z: [*:0]const u8 = @ptrCast(&name_buf);
    for ([_]c_int{ std.posix.AF.INET, std.posix.AF.INET6 }) |family| {
        const hints: std.c.addrinfo = .{
            .flags = .{},
            .family = family,
            .socktype = std.posix.SOCK.STREAM,
            .protocol = 0,
            .addrlen = 0,
            .canonname = null,
            .addr = null,
            .next = null,
        };
        var res: ?*std.c.addrinfo = null;
        if (@intFromEnum(std.c.getaddrinfo(name_z, null, &hints, &res)) != 0) continue;
        const list = res orelse continue;
        defer std.c.freeaddrinfo(list);
        const sa = list.addr orelse continue;
        if (family == std.posix.AF.INET) {
            const a: *const [4]u8 = @ptrCast(&@as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(sa))).addr);
            return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] });
        }
        const a = @as(*const std.posix.sockaddr.in6, @ptrCast(@alignCast(sa))).addr;
        var w: std.Io.Writer = .fixed(buf);
        for (0..8) |i| try w.print("{s}{x}", .{ if (i == 0) "" else ":", @as(u16, a[2 * i]) << 8 | a[2 * i + 1] });
        return w.buffered();
    }
    log.warn("cannot resolve {s}", .{name});
    return error.UnknownHostName;
}

/// Type `text` into the focused field of whatever app the user is in,
/// through the Oriel keyboard (`.android = .{ .input_method = ... }` in
/// build.zig; the user picks it as their keyboard). error.NoKeyboard when it
/// isn't the active keyboard with a field focused. Any thread.
pub fn commitText(text: []const u8) !void {
    const Ctx = struct {
        text: []const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "commitText", "([B)Z", .{self.text}) orelse false;
        }
    };
    var ctx: Ctx = .{ .text = text };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.NoKeyboard;
}

/// Whether the Oriel keyboard is up with a field to type into. Any thread.
pub fn keyboardActive() bool {
    const Ctx = struct {
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "keyboardActive", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return false;
    return ctx.ok;
}

/// The Oriel keyboard's status line and main button label ("Listening…", "■").
pub fn setKeyboardStatus(status: []const u8, button: []const u8) void {
    const Ctx = struct {
        status: []const u8,
        button: []const u8,
        fn run(self: *@This()) void {
            _ = runtime.call(.void, "setKeyboardStatus", "([B[B)V", .{ self.status, self.button });
        }
    };
    var ctx: Ctx = .{ .status = status, .button = button };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

/// The Quick Settings tile's state and label ("" keeps the label).
pub fn setTile(active: bool, label: []const u8) void {
    const Ctx = struct {
        active: bool,
        label: []const u8,
        fn run(self: *@This()) void {
            _ = runtime.call(.void, "setTile", "(Z[B)V", .{ self.active, self.label });
        }
    };
    var ctx: Ctx = .{ .active = active, .label = label };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

comptime {
    // The JNI natives must be in every Android build.
    _ = @import("exports.zig");
}

test {
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(paths);
    _ = App;
}
