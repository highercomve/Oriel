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
const internal = @import("../../core/internal.zig");
const notification_common = @import("../../modules/notification/common.zig");
const lifecycle = @import("../../core/lifecycle/backend.zig");
const log = std.log.scoped(.oriel);

pub const window = @import("window.zig");
pub const ShellMod = @import("Shell.zig");
pub const bridge = @import("bridge.zig");
pub const scheme = @import("scheme.zig");
pub const runtime = @import("runtime.zig");
pub const jni = @import("jni.zig");
pub const entry = @import("entry.zig");
pub const AsyncRequest = @import("async_request.zig").AsyncRequest;

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
pub const setWindowThemeColor = window.setWindowThemeColor;
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

/// Keep the app running with no window in front (a sync engine, a server
/// for the user's other devices): a foreground service of type
/// `specialUse` with an ongoing notification, `actions` as its buttons
/// (system event "action"). Needs `.android.keep_running` in build.zig.
/// Android 13+ shows the notification only with the notifications
/// permission; the service runs either way. Start it while the app is in
/// front (Android refuses from the background). `on = false` stops it.
/// Any thread.
pub fn setKeepRunning(on: bool, title: []const u8, text: []const u8, actions: []const Action) !void {
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
            self.ok = runtime.call(.boolean, "setKeepRunning", "(Z[B[B[B)Z", .{ self.on, self.title, self.text, self.actions }) orelse false;
        }
    };
    var ctx: Ctx = .{ .on = on, .title = title, .text = text, .actions = lines.items };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.KeepRunningFailed;
}

/// Whether battery optimization leaves the app alone. While it doesn't,
/// Android (and stricter vendors: Xiaomi, Huawei, Samsung) may still stop
/// a background app; `openAppSettings` is where the user changes it.
pub fn batteryUnrestricted() bool {
    const Ctx = struct {
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "batteryUnrestricted", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return false;
    return ctx.ok;
}

/// The app's page in the system settings: battery usage, and on some
/// phones (MIUI) autostart. False if it couldn't open.
pub fn openAppSettings() bool {
    const Ctx = struct {
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "openAppSettings", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return false;
    return ctx.ok;
}

/// A system entry point that replaces a desktop hotkey or tray menu (see
/// OrielSystem.kt): "tile", "action" (data: the action's id),
/// "media-button" (data: the key code), "ime-mic", "ime-open" (data: the
/// field's input type), "ime-close". Called on the main thread; the page
/// also gets an `android:event` event with `{ name, data }`. Memory
/// pressure is `oriel.lifecycle`'s, as on every platform.
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
    if (std.mem.eql(u8, name, "trim-memory")) {
        const level = std.fmt.parseInt(i32, data, 10) catch 0;
        if (lifecycle.fromAndroidTrim(level)) |event| lifecycle.dispatch(event);
        return;
    }
    if (std.mem.eql(u8, name, "notification")) {
        // oriel.notification: a tap or a button (OrielRuntime.notify).
        const t = notification_common.unpackTarget(data);
        notification_common.dispatch(t.id, t.action);
        return;
    }
    if (std.mem.eql(u8, name, "ble-advertise")) {
        // oriel.bluetooth: an advertisement started, failed or stopped
        // (OrielBluetooth's AdvertiseCallback). Off, the module isn't built.
        if (@import("build_options").bluetooth) @import("../../modules/bluetooth/android.zig").onSystemEvent(data);
        return;
    }
    if (std.mem.eql(u8, name, "video")) {
        // oriel.video: the player closed, ended or failed (OrielVideo).
        if (@import("build_options").video) @import("../../modules/video/android.zig").onSystemEvent(data);
        return;
    }
    if (system_event_handler) |h| h(name, data);
    internal.emit("android:event", .{ .name = name, .data = data });
}

/// OrielRuntime's started-Activity count (main thread): 0 background, 1
/// foreground.
fn nativeLifecycle(_: *jni.Env, _: jni.jclass, event: jni.jint) callconv(.c) void {
    lifecycle.dispatch(if (event == 0) .background else .foreground);
}

comptime {
    @export(&nativeSystemEvent, .{ .name = "Java_dev_oriel_NativeLib_onSystemEvent" });
    @export(&nativeLifecycle, .{ .name = "Java_dev_oriel_NativeLib_onLifecycle" });
}

/// <malloc.h>: purge the allocator's caches (API 28+).
const M_PURGE = -101;
extern "c" fn mallopt(option: c_int, value: c_int) c_int;

var purge_subscribed = std.atomic.Value(bool).init(false);

/// Shell.run: from now on, memory pressure and the background make bionic's
/// allocator give its cached free pages back to the system (after the
/// modules that subscribed earlier freed their models). Oriel's own
/// allocations use it (core/heap.zig), and so does the app's `gpa`.
pub fn subscribeMallocPurge() void {
    if (purge_subscribed.swap(true, .monotonic)) return;
    lifecycle.subscribe(&purgeMalloc) catch log.warn("lifecycle: no room for the malloc purge", .{});
}

fn purgeMalloc(event: lifecycle.Event) void {
    switch (event) {
        .memory_pressure, .background => {
            _ = mallopt(M_PURGE, 0);
            log.info("{s}: purged the malloc caches", .{event.name()});
        },
        else => {},
    }
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
    // OrielCall's natives (oriel.extensions).
    _ = @import("extensions.zig");
}

test {
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(@import("paths.zig"));
    _ = App;
}
