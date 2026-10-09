//! Android windows: one `android.webkit.WebView` per Oriel window, shown in
//! an Activity of its own (a task per window, resizable and multi-instance
//! in desktop windowing).
//!
//! The Kotlin runtime owns a registry of windows by id. A window's WebView is
//! created right away (with a `MutableContextWrapper`) and lives until the
//! window is destroyed: a hidden window keeps its page running, and the
//! page survives its Activity being recreated. `showWindow` starts (or brings
//! back) the window's Activity; `hideWindow` sends its task to the back.
//!
//! Every operation here touches Java, so it runs on the UI thread: called
//! from another thread, it is queued there (queries wait for the answer).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");
const runtime = @import("runtime.zig");
const ShellMod = @import("Shell.zig");
const handlers = @import("handlers.zig");
const bridge_mod = @import("bridge.zig");
const scheme_mod = @import("scheme.zig");
const permissions = @import("../../core/permissions.zig");
const build_opts = @import("build_options");
const build_target = @import("../../core/target.zig");
/// -Dnative_ui: pages drawn with native views instead of a WebView (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/android.zig") else struct {};

const log = std.log.scoped(.oriel);

pub const WindowHandle = struct {
    /// Unique per window for the process: also the Kotlin registry's key
    /// and the isolation key table's "view".
    id: u32,

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.id == other.id;
    }
};

pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

var next_id: std.atomic.Value(u32) = .init(1);

// Flags for OrielRuntime.createWindow (see OrielRuntime.kt).
const flag_visible: i32 = 1 << 0;
const flag_resizable: i32 = 1 << 1;
const flag_decorations: i32 = 1 << 2;
const flag_transparent: i32 = 1 << 3;
const flag_devtools: i32 = 1 << 4;
const flag_focus: i32 = 1 << 5;
const flag_main: i32 = 1 << 6;
const flag_media: i32 = 1 << 7;
const flag_native: i32 = 1 << 8;

// ---------------------------------------------------------------------------
// Operations (UI thread, forwarded from other threads)
// ---------------------------------------------------------------------------

const Op = union(enum) {
    show,
    hide,
    focus,
    close,
    title: [:0]u8,
    /// The page's theme-color (null: none), for the caption.
    theme: ?[4]u8,
    fullscreen: bool,
    maximized: bool,
    size: struct { w: c_int, h: c_int },
};

fn apply(handle: WindowHandle, op: Op) void {
    const id: i32 = @intCast(handle.id);
    switch (op) {
        .show => _ = runtime.call(.void, "showWindow", "(I)V", .{id}),
        .hide => _ = runtime.call(.void, "hideWindow", "(I)V", .{id}),
        .focus => _ = runtime.call(.void, "showWindow", "(I)V", .{id}),
        .close => if (App.getWindowByHandle(handle)) |w| closeNow(w),
        .title => |t| _ = runtime.call(.void, "setTitle", "(I[B)V", .{ id, @as([]const u8, t) }),
        .theme => |c| {
            // ARGB, alpha first as Android's Color ints; has: a colour at all.
            const argb: u32 = if (c) |v| (@as(u32, v[3]) << 24) | (@as(u32, v[0]) << 16) | (@as(u32, v[1]) << 8) | v[2] else 0;
            _ = runtime.call(.void, "setThemeColor", "(IZI)V", .{ id, c != null, @as(i32, @bitCast(argb)) });
        },
        .fullscreen => |on| _ = runtime.call(.void, "setFullscreen", "(IZ)V", .{ id, on }),
        .maximized => |on| _ = runtime.call(.void, "setMaximized", "(IZ)V", .{ id, on }),
        .size => |s| _ = runtime.call(.void, "setSize", "(III)V", .{ id, @as(i32, s.w), @as(i32, s.h) }),
    }
}

fn freeOp(op: Op) void {
    switch (op) {
        .title => |t| heap.gpa.free(t),
        else => {},
    }
}

fn perform(handle: WindowHandle, op: Op) void {
    if (ShellMod.isMainThread()) {
        defer freeOp(op);
        return apply(handle, op);
    }
    const Task = struct {
        handle: WindowHandle,
        op: Op,
        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer drop(self);
            apply(self.handle, self.op);
        }
        fn drop(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            freeOp(self.op);
            heap.gpa.destroy(self);
        }
    };
    const task = heap.gpa.create(Task) catch {
        freeOp(op);
        return;
    };
    task.* = .{ .handle = handle, .op = op };
    ShellMod.dispatchWithCleanup(&Task.run, task, &Task.drop);
}

/// A value from the UI thread; `fallback` when the app isn't running.
fn query(comptime T: type, handle: WindowHandle, comptime get: fn (WindowHandle) T, fallback: T) T {
    if (ShellMod.isMainThread()) return get(handle);
    const Ctx = struct {
        handle: WindowHandle,
        out: T,
        fn run(self: *@This()) void {
            self.out = get(self.handle);
        }
    };
    var ctx: Ctx = .{ .handle = handle, .out = fallback };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return fallback;
    return ctx.out;
}

pub fn showWindow(handle: WindowHandle) void {
    perform(handle, .show);
}

pub fn hideWindow(handle: WindowHandle) void {
    perform(handle, .hide);
}

pub fn toggleWindow(handle: WindowHandle) void {
    if (query(bool, handle, isShownNow, false)) hideWindow(handle) else showWindow(handle);
}

fn isShownNow(handle: WindowHandle) bool {
    return runtime.call(.boolean, "isWindowShown", "(I)Z", .{@as(i32, @intCast(handle.id))}) orelse false;
}

pub fn focusWindow(handle: WindowHandle) void {
    perform(handle, .focus);
}

pub fn closeWindow(handle: WindowHandle) void {
    perform(handle, .close);
}

/// Close later, from the task queue (e.g. from inside the page's own call).
pub fn postCloseWindow(handle: WindowHandle) void {
    const Task = struct {
        fn run(ctx: ?*anyopaque) void {
            const id: u32 = @intCast(@intFromPtr(ctx));
            if (App.getWindowByHandle(.{ .id = id })) |w| closeNow(w);
        }
    };
    ShellMod.dispatchToMainThread(&Task.run, @ptrFromInt(handle.id));
}

pub fn setWindowTitle(handle: WindowHandle, title: [:0]const u8) void {
    const copy = heap.gpa.dupeZ(u8, title) catch return;
    perform(handle, .{ .title = copy });
}

/// The page's `<meta name="theme-color">` (null: none): the window's task
/// colour, which ChromeOS paints its caption with (any thread).
pub fn setWindowThemeColor(handle: WindowHandle, color: ?[4]u8) void {
    perform(handle, .{ .theme = color });
}

pub fn setWindowFullscreen(handle: WindowHandle, fullscreen: bool) void {
    perform(handle, .{ .fullscreen = fullscreen });
}

fn isFullscreenNow(handle: WindowHandle) bool {
    return runtime.call(.boolean, "isFullscreen", "(I)Z", .{@as(i32, @intCast(handle.id))}) orelse false;
}

pub fn isWindowFullscreen(handle: WindowHandle) bool {
    return query(bool, handle, isFullscreenNow, false);
}

/// Android has no maximize request for an app's own window: the state is
/// kept (and reported), the window manager decides the bounds.
pub fn setWindowMaximized(handle: WindowHandle, maximized: bool) void {
    perform(handle, .{ .maximized = maximized });
}

fn isMaximizedNow(handle: WindowHandle) bool {
    return runtime.call(.boolean, "isMaximized", "(I)Z", .{@as(i32, @intCast(handle.id))}) orelse false;
}

pub fn isWindowMaximized(handle: WindowHandle) bool {
    return query(bool, handle, isMaximizedNow, false);
}

/// The size used for the window's launch bounds the next time its Activity
/// starts (a running Activity can't be resized by the app).
pub fn setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void {
    perform(handle, .{ .size = .{ .w = width, .h = height } });
}

fn sizeNow(handle: WindowHandle) WindowSize {
    const packed_size = runtime.call(.long, "getSize", "(I)J", .{@as(i32, @intCast(handle.id))}) orelse return .{ .width = 0, .height = 0 };
    return unpack(packed_size);
}

fn unpack(v: i64) WindowSize {
    const u: u64 = @bitCast(v);
    // Out of c_int range (a -1 sentinel from Kotlin, say): 0.
    return .{
        .width = std.math.cast(c_int, @as(u32, @truncate(u >> 32))) orelse 0,
        .height = std.math.cast(c_int, @as(u32, @truncate(u))) orelse 0,
    };
}

/// The page's size in CSS pixels (dp).
pub fn getWindowSize(handle: WindowHandle) WindowSize {
    return query(WindowSize, handle, sizeNow, .{ .width = 0, .height = 0 });
}

/// Windows are placed by the window manager on Android.
pub fn setWindowPlacement(handle: WindowHandle, placement: App.Placement) void {
    _ = handle;
    _ = placement;
}

pub fn setWindowClickThrough(handle: WindowHandle, enabled: bool) void {
    _ = handle;
    _ = enabled;
}

pub fn setWindowAlwaysOnTop(handle: WindowHandle, enabled: bool) void {
    _ = handle;
    _ = enabled;
}

fn workAreaNow(handle: WindowHandle) ?App.Rect {
    const packed_size = runtime.call(.long, "getWorkArea", "(I)J", .{@as(i32, @intCast(handle.id))}) orelse return null;
    if (packed_size == 0) return null;
    const s = unpack(packed_size);
    return .{ .x = 0, .y = 0, .width = s.width, .height = s.height };
}

/// The display's size in dp.
pub fn getWindowWorkArea(handle: WindowHandle) ?App.Rect {
    return query(?App.Rect, handle, workAreaNow, null);
}

/// The caption bar moves windows in desktop windowing; apps can't.
pub fn startWindowDrag(handle: WindowHandle) App.DragMode {
    _ = handle;
    return .unsupported;
}

pub fn openExternal(uri: [*:0]const u8) void {
    const url = std.mem.span(uri);
    if (ShellMod.isMainThread()) {
        _ = runtime.call(.void, "openExternal", "([B)V", .{@as([]const u8, url)});
        return;
    }
    const copy = heap.gpa.dupeZ(u8, url) catch return;
    const Task = struct {
        fn run(ctx: ?*anyopaque) void {
            const s: [*:0]u8 = @ptrCast(ctx.?);
            defer drop(ctx);
            _ = runtime.call(.void, "openExternal", "([B)V", .{@as([]const u8, std.mem.span(s))});
        }
        fn drop(ctx: ?*anyopaque) void {
            const s: [*:0]u8 = @ptrCast(ctx.?);
            heap.gpa.free(std.mem.span(s));
        }
    };
    ShellMod.dispatchWithCleanup(&Task.run, copy.ptr, &Task.drop);
}

// ---------------------------------------------------------------------------
// Lookup and teardown
// ---------------------------------------------------------------------------

pub fn getWindowById(id: u32) ?*App.Window {
    return App.getWindowByHandle(.{ .id = id });
}

fn teardown(handle: WindowHandle) void {
    isolation.forget(handle.id);
    if (comptime build_opts.native_ui) native.destroy(handle.id);
    _ = runtime.call(.void, "destroyWindow", "(I)V", .{@as(i32, @intCast(handle.id))});
}

/// Undo `createWindow` for a window that never made it into the window list.
pub fn destroyWindow(handle: WindowHandle) void {
    if (ShellMod.isMainThread()) teardown(handle);
}

var current_on_close_hide = false;

/// The close sequence: the Activity's close (caption X, swiped away),
/// `closeWindow` and JS. With hide-on-close the window only hides.
pub fn closeNow(win: *App.Window) void {
    if (win.options.hide_on_close or (std.mem.eql(u8, win.label, "main") and current_on_close_hide)) {
        _ = runtime.call(.void, "hideWindow", "(I)V", .{@as(i32, @intCast(win.handle.id))});
        return;
    }
    win.saveGeometry();
    App.emit("window:closed", .{ .label = win.label });

    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    for (App.windows_list.items, 0..) |w, i| {
        if (w == win) {
            _ = App.windows_list.swapRemove(i);
            break;
        }
    }
    const remaining = App.windows_list.items.len;
    App.windows_mutex.unlock();

    teardown(win.handle);
    freeWindow(win);
    if (remaining == 0) App.quit(0);
}

fn freeWindow(win: *App.Window) void {
    const gpa = heap.gpa;
    gpa.free(win.label);
    gpa.free(win.options.title);
    if (win.options.url) |u| gpa.free(u);
    gpa.destroy(win);
}

/// Shutdown (UI thread): every window still open, without events.
pub fn destroyAllWindows() void {
    while (true) {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        const win = App.windows_list.pop();
        App.windows_mutex.unlock();
        const w = win orelse break;
        teardown(w.handle);
        freeWindow(w);
    }
}

// ---------------------------------------------------------------------------
// Creation and the webview callbacks
// ---------------------------------------------------------------------------

/// WebMessageListener origin rules (newline-separated) for the pages that
/// get the bridge object: the app, the dev server and remote capability
/// origins. Every call is still checked against the page's token and origin.
fn originRules(comptime sec: security.Security, comptime local: security.Local) []const u8 {
    comptime {
        var rules: []const u8 = security.app_origin;
        if (local.dev_origin) |d| rules = rules ++ "\n" ++ d;
        for (sec.capabilities) |c| {
            var buf: [512]u8 = undefined;
            const o = security.origin(&buf, c.origin) orelse c.origin;
            rules = rules ++ "\n" ++ o;
        }
        return rules;
    }
}

pub fn WindowCreator(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime csp_z: ?[:0]const u8,
) type {
    const SchemeImpl = scheme_mod.Scheme(config, local, csp_z);
    const BridgeImpl = bridge_mod.Bridge(api, config, local);
    const rules = comptime originRules(config.security, local);
    const media = comptime (config.permissions.has(.microphone) or config.permissions.has(.camera));

    return struct {
        var window_open_counter = std.atomic.Value(u32).init(1);
        var dev_retries_left: u32 = 0;
        const dev_retry_interval_ms = 250;

        pub fn init() void {
            current_on_close_hide = config.on_close == .hide;
            if (config.dev) |dev| dev_retries_left = dev.timeout_ms / dev_retry_interval_ms;
            handlers.create_window = &createWindow;
            handlers.on_message = &BridgeImpl.onMessage;
            handlers.serve = &SchemeImpl.serve;
            handlers.navigation = &navigation;
            handlers.new_window = &newWindow;
            handlers.on_new_intent = &onNewIntent;
            handlers.load_failed = &loadFailed;
            handlers.allow_media = &allowMedia;
        }

        pub fn deinit() void {
            handlers.clear();
        }

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            if (!ShellMod.isMainThread()) return error.NotMainThread;
            const gpa = heap.gpa;
            const target_uri = try security.resolveWindowUrl(
                gpa,
                config.security,
                local,
                if (config.dev) |d| d.url else null,
                options.url,
                config.start,
            );
            defer gpa.free(target_uri);
            const script = try BridgeImpl.script(gpa, options.label);
            defer gpa.free(script);

            var flags: i32 = 0;
            if (options.visible) flags |= flag_visible;
            if (options.resizable) flags |= flag_resizable;
            if (options.decorations) flags |= flag_decorations;
            if (options.transparent) flags |= flag_transparent;
            if (config.devtools) flags |= flag_devtools;
            if (options.focus_on_show) flags |= flag_focus;
            if (std.mem.eql(u8, options.label, "main")) flags |= flag_main;
            if (media) flags |= flag_media;
            if (comptime build_opts.native_ui) flags |= flag_native;

            const id = next_id.fetchAdd(1, .monotonic);
            const ok = runtime.call(.boolean, "createWindow", "(I[B[B[BIIIII[B[B)Z", .{
                @as(i32, @intCast(id)),
                @as([]const u8, options.label),
                @as([]const u8, options.title),
                @as([]const u8, target_uri),
                @as(i32, options.width),
                @as(i32, options.height),
                @as(i32, options.min_width orelse 0),
                @as(i32, options.min_height orelse 0),
                flags,
                @as([]const u8, script),
                @as([]const u8, rules),
            }) orelse false;
            if (!ok) return error.CreateWindowFailed;
            if (comptime build_opts.native_ui) {
                _ = native.create(std.heap.smp_allocator, id, config.assets, build_target.platform_json, options.label, options.url orelse "index.html", BridgeImpl.nativeInvoke, win_inst) catch |err| {
                    log.err("native ui: cannot start the page ({s})", .{@errorName(err)});
                    _ = runtime.call(.void, "destroyWindow", "(I)V", .{@as(i32, @intCast(id))});
                    return err;
                };
            }
            return .{ .id = id };
        }

        /// A top-level navigation (link, form, script) of window `id`.
        fn navigation(id: u32, url: []const u8, user_gesture: bool) bool {
            _ = id;
            if (comptime config.security.isolation != null) {
                var buf: [512]u8 = undefined;
                if (security.origin(&buf, url)) |o| if (std.mem.eql(u8, o, isolation.origin)) return false; // never top-level
            }
            switch (security.navigation(config.security, local, url, user_gesture)) {
                .allow => return true,
                .open_external => {
                    const z = heap.gpa.dupeZ(u8, url) catch return false;
                    defer heap.gpa.free(z);
                    App.openExternal(z.ptr);
                    return false;
                },
                .block => {
                    log.warn("blocked navigation to {s}", .{url});
                    return false;
                },
            }
        }

        /// `window.open` and allowed `target="_blank"`: an Oriel window or
        /// the main view (`config.window_open`); never a WebView popup.
        fn newWindow(id: u32, url: []const u8, user_gesture: bool) void {
            _ = id;
            switch (security.navigation(config.security, local, url, user_gesture)) {
                .allow => {
                    var obuf: [512]u8 = undefined;
                    const o = security.origin(&obuf, url);
                    if (config.window_open == .new_window and o != null and local.contains(o.?)) {
                        const n = window_open_counter.fetchAdd(1, .monotonic);
                        var label_buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrintZ(&label_buf, "win-{d}", .{n}) catch return;
                        const url_z = heap.gpa.dupeZ(u8, url) catch return;
                        defer heap.gpa.free(url_z);
                        _ = App.openWindow(.{ .label = label, .url = url_z }) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    } else if (App.getWindow("main")) |mw| {
                        _ = runtime.call(.void, "loadUrl", "(I[B)V", .{ @as(i32, @intCast(mw.handle.id)), url });
                    }
                },
                .open_external => {
                    const z = heap.gpa.dupeZ(u8, url) catch return;
                    defer heap.gpa.free(z);
                    App.openExternal(z.ptr);
                },
                .block => log.warn("blocked new window to {s}", .{url}),
            }
        }

        fn onNewIntent(args: []const []const u8) void {
            const S = ShellMod.Shell(api, config);
            S.handleArgs(args, false);
        }

        /// Dev mode: the dev server (through `adb reverse`) may still be
        /// starting; retry its URL until `dev.timeout_ms` is used up.
        fn loadFailed(id: u32) void {
            if (config.dev == null or dev_retries_left == 0) return;
            dev_retries_left -= 1;
            _ = runtime.call(.void, "retryLoad", "(I[BI)V", .{ @as(i32, @intCast(id)), @as([]const u8, config.dev.?.url), @as(i32, dev_retry_interval_ms) });
        }

        /// getUserMedia: granted only when the app declares every requested
        /// device and the page is trusted (permissions.allowForPage); Kotlin
        /// then asks for the runtime permission if needed.
        fn allowMedia(id: u32, origin: []const u8, kinds: u32) bool {
            _ = id;
            if (kinds == 0) return false;
            var buf: [600]u8 = undefined;
            const page = std.fmt.bufPrint(&buf, "{s}/", .{origin}) catch return false;
            if (kinds & 1 != 0 and !permissions.allowForPage(.microphone, local, page)) return false;
            if (kinds & 2 != 0 and !permissions.allowForPage(.camera, local, page)) return false;
            return true;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
