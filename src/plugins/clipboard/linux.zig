//! System clipboard: text and PNG images.
//!
//! Threading model (GTK is single-threaded, and a blocking clipboard read on
//! the main thread can deadlock when we own the selection ourselves, because
//! serving it needs the main loop):
//!
//! - Main thread: `readTextAsync` / `readImageAsync` (GdkClipboard, callback
//!   on the main thread) and `writeText` / `writeImage`. Nothing here blocks
//!   or runs a nested main loop.
//! - Worker threads (async commands, `App.spawn`): the blocking `readText` /
//!   `readImage`. On Wayland they read in the background (without window
//!   focus) through the ext-data-control protocol on their own Wayland
//!   connection; otherwise they hand the GdkClipboard read to the main loop
//!   and wait for its callback. `writeText` / `writeImage` also work there.
//!
//! When this process owns the selection, reads return the data we last
//! wrote without a round-trip: every write also offers a per-process marker
//! MIME type, which data-control readers look for.

const std = @import("std");
const wayland = @import("wayland");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const Globals = @import("../wayland_globals.zig").Globals;
const oriel = @import("../../oriel.zig");

const ext = wayland.client.ext;
const log = std.log.scoped(.oriel);

/// How long a worker waits for the main thread (a GdkClipboard transfer
/// from another app, or the main loop not running at all).
const main_thread_timeout_ms = 5000;
/// How long a data-control read waits for the selection owner to send data.
const pipe_timeout_ms = 2000;

/// `G_TYPE_STRING` (a fundamental type: 16 << G_TYPE_FUNDAMENTAL_SHIFT).
const g_type_string: usize = 16 << 2;

/// The last data this process put on the clipboard. Written on the main
/// thread, read by workers; allocated with `smp_allocator`.
var last_mutex: glib.Mutex = std.mem.zeroes(glib.Mutex); // static GMutex needs no init
var last_text: ?[]u8 = null;
var last_image: ?[]u8 = null;

const Kind = enum { text, image };

/// Per-process marker MIME type offered next to our clipboard content.
fn markerMime(buf: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "application/x-oriel-owner-{d}", .{std.c.getpid()}) catch unreachable;
}

fn isWayland() bool {
    return std.c.getenv("WAYLAND_DISPLAY") != null;
}

/// Whether the caller runs the GLib main loop (the GTK main thread while
/// the app runs).
fn onMainThread() bool {
    return glib.MainContext.default().isOwner() != 0;
}

/// A copy (gpa) of what we last wrote as `kind`, or null.
fn ownCopy(gpa: std.mem.Allocator, kind: Kind) !?[]u8 {
    last_mutex.lock();
    defer last_mutex.unlock();
    const data = switch (kind) {
        .text => last_text,
        .image => last_image,
    } orelse return null;
    return try gpa.dupe(u8, data);
}

fn remember(kind: Kind, data: []const u8) !void {
    const copy = try std.heap.smp_allocator.dupe(u8, data);
    last_mutex.lock();
    defer last_mutex.unlock();
    // The clipboard holds one thing: forget the other kind.
    if (last_text) |t| std.heap.smp_allocator.free(t);
    if (last_image) |i| std.heap.smp_allocator.free(i);
    last_text = null;
    last_image = null;
    switch (kind) {
        .text => last_text = copy,
        .image => last_image = copy,
    }
}

// ---------------------------------------------------------------------------
// Main thread: GdkClipboard
// ---------------------------------------------------------------------------

fn gdkClipboard() !*gdk.Clipboard {
    const display = gdk.Display.getDefault() orelse return error.NoDisplay;
    return display.getClipboard();
}

/// Put `value` on the clipboard together with our marker MIME type.
fn setContent(value: *const gobject.Value) !void {
    const cb = try gdkClipboard();
    var marker_buf: [64]u8 = undefined;
    const bytes = glib.Bytes.new("1", 1);
    defer bytes.unref();
    // The union takes ownership of both providers.
    var providers = [_]*gdk.ContentProvider{
        gdk.ContentProvider.newForValue(value),
        gdk.ContentProvider.newForBytes(markerMime(&marker_buf), bytes),
    };
    const provider = gdk.ContentProvider.newUnion(&providers, providers.len);
    defer provider.unref();
    if (cb.setContent(provider) == 0) return error.ClipboardSetFailed;
}

fn writeTextMain(text: []const u8) !void {
    const text_z = try std.heap.smp_allocator.dupeZ(u8, text);
    defer std.heap.smp_allocator.free(text_z);
    // Remember first: a reader that sees our marker must find the new data.
    try remember(.text, text);
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(g_type_string);
    defer value.unset();
    value.setString(text_z);
    try setContent(&value);
}

fn writeImageMain(png_bytes: []const u8) !void {
    const bytes = glib.Bytes.new(png_bytes.ptr, png_bytes.len);
    defer bytes.unref();
    var err: ?*glib.Error = null;
    const texture = gdk.Texture.newFromBytes(bytes, &err) orelse {
        if (err) |e| {
            log.err("clipboard: decoding image: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return error.TextureNew;
    };
    defer texture.unref();
    try remember(.image, png_bytes);
    var value = std.mem.zeroes(gobject.Value);
    _ = value.init(gdk.Texture.getGObjectType());
    defer value.unset();
    value.setObject(texture.as(gobject.Object));
    try setContent(&value);
}

/// Result callbacks of the async reads; they run on the main thread and the
/// data is only valid during the call.
pub const TextCallback = *const fn (result: anyerror![]const u8, user_data: ?*anyopaque) void;
pub const ImageCallback = *const fn (result: anyerror!?[]const u8, user_data: ?*anyopaque) void;

/// Read the clipboard text without blocking. Call on the main thread;
/// `callback` runs later on the main thread (or right away on errors such
/// as `error.NoDisplay`). GdkClipboard reads our own content locally.
pub fn readTextAsync(callback: TextCallback, user_data: ?*anyopaque) void {
    const cb = gdkClipboard() catch |err| return callback(err, user_data);
    const Req = struct {
        callback: TextCallback,
        user_data: ?*anyopaque,

        fn onFinish(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            defer std.heap.smp_allocator.destroy(self);
            const clipboard: *gdk.Clipboard = @ptrCast(source.?);
            var err: ?*glib.Error = null;
            if (clipboard.readTextFinish(res, &err)) |s| {
                defer glib.free(s);
                return self.callback(std.mem.span(s), self.user_data);
            }
            if (err) |e| {
                log.warn("clipboard: reading text: {s}", .{e.f_message orelse "unknown error"});
                e.free();
            }
            self.callback(error.ClipboardReadFailed, self.user_data);
        }
    };
    const req = std.heap.smp_allocator.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    cb.readTextAsync(null, &Req.onFinish, req);
}

/// Read a clipboard image as PNG (null: no image) without blocking. Same
/// rules as `readTextAsync`.
pub fn readImageAsync(callback: ImageCallback, user_data: ?*anyopaque) void {
    const cb = gdkClipboard() catch |err| return callback(err, user_data);
    const Req = struct {
        callback: ImageCallback,
        user_data: ?*anyopaque,

        fn onFinish(source: ?*gobject.Object, res: *gio.AsyncResult, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            defer std.heap.smp_allocator.destroy(self);
            const clipboard: *gdk.Clipboard = @ptrCast(source.?);
            var err: ?*glib.Error = null;
            const texture = clipboard.readTextureFinish(res, &err) orelse {
                // No image on the clipboard is not an error.
                if (err) |e| e.free();
                return self.callback(null, self.user_data);
            };
            defer texture.unref();
            const png = texture.saveToPngBytes();
            defer png.unref();
            var size: usize = 0;
            const ptr = png.getData(&size) orelse return self.callback(error.ClipboardReadFailed, self.user_data);
            self.callback(@as([*]const u8, @ptrCast(ptr))[0..size], self.user_data);
        }
    };
    const req = std.heap.smp_allocator.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    cb.readTextureAsync(null, &Req.onFinish, req);
}

// ---------------------------------------------------------------------------
// Worker -> main thread hand-off
// ---------------------------------------------------------------------------

/// A clipboard operation a worker hands to the main loop. Reference counted
/// (worker + main side) so a worker that times out can leave while the main
/// side finishes later.
const MainCall = struct {
    refs: std.atomic.Value(u32) = .init(2),
    mutex: glib.Mutex = undefined,
    cond: glib.Cond = undefined,
    done: bool = false,
    op: Op,
    /// Input of writes; result of reads (smp_allocator).
    data: ?[]u8 = null,
    err: ?anyerror = null,

    const Op = enum { read_text, read_image, write_text, write_image };
    const gpa = std.heap.smp_allocator;

    fn release(self: *MainCall) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.data) |d| gpa.free(d);
        self.mutex.clear();
        self.cond.clear();
        gpa.destroy(self);
    }

    fn complete(self: *MainCall, data: ?[]u8, err: ?anyerror) void {
        self.mutex.lock();
        if (self.data) |d| gpa.free(d);
        self.data = data;
        self.err = err;
        self.done = true;
        self.cond.signal();
        self.mutex.unlock();
        self.release();
    }

    fn start(ptr: ?*anyopaque) callconv(.c) c_int {
        const self: *MainCall = @ptrCast(@alignCast(ptr));
        switch (self.op) {
            .write_text => self.complete(null, if (writeTextMain(self.data.?)) null else |e| e),
            .write_image => self.complete(null, if (writeImageMain(self.data.?)) null else |e| e),
            .read_text => readTextAsync(&onText, self),
            .read_image => readImageAsync(&onImage, self),
        }
        return 0; // one-shot
    }

    fn onText(result: anyerror![]const u8, ptr: ?*anyopaque) void {
        const self: *MainCall = @ptrCast(@alignCast(ptr));
        const text = result catch |e| return self.complete(null, e);
        const copy = gpa.dupe(u8, text) catch |e| return self.complete(null, e);
        self.complete(copy, null);
    }

    fn onImage(result: anyerror!?[]const u8, ptr: ?*anyopaque) void {
        const self: *MainCall = @ptrCast(@alignCast(ptr));
        const png = (result catch |e| return self.complete(null, e)) orelse return self.complete(null, null);
        const copy = gpa.dupe(u8, png) catch |e| return self.complete(null, e);
        self.complete(copy, null);
    }

    /// Run `op` on the main loop and wait for it. Returns the read data
    /// (caller's `out_gpa`), or null for writes / no image.
    fn run(out_gpa: std.mem.Allocator, op: Op, input: ?[]const u8) !?[]u8 {
        const self = try gpa.create(MainCall);
        self.* = .{ .op = op };
        // Heap GMutex/GCond need init (only static ones may stay zeroed).
        self.mutex.init();
        self.cond.init();
        if (input) |in| {
            self.data = gpa.dupe(u8, in) catch |e| {
                self.mutex.clear();
                self.cond.clear();
                gpa.destroy(self);
                return e;
            };
        }
        _ = glib.idleAdd(&start, self);

        self.mutex.lock();
        const deadline = glib.getMonotonicTime() + main_thread_timeout_ms * std.time.us_per_ms;
        while (!self.done) {
            if (self.cond.waitUntil(&self.mutex, deadline) == 0) break;
        }
        const done = self.done;
        const err = self.err;
        const data = self.data;
        if (done) self.data = null; // taken
        self.mutex.unlock();
        defer self.release();

        if (!done) return error.MainThreadTimeout;
        const owned = data orelse {
            if (err) |e| return e;
            return null;
        };
        defer gpa.free(owned);
        if (err) |e| return e;
        return try out_gpa.dupe(u8, owned);
    }
};

// ---------------------------------------------------------------------------
// Worker: Wayland data-control (background clipboard without focus)
// ---------------------------------------------------------------------------

const Offer = struct {
    offer: *ext.DataControlOfferV1,
    mimes: std.ArrayList([]u8) = .empty,

    fn onEvent(_: *ext.DataControlOfferV1, event: ext.DataControlOfferV1.Event, self: *Offer) void {
        switch (event) {
            .offer => |o| {
                const mime = std.heap.smp_allocator.dupe(u8, std.mem.span(o.mime_type)) catch return;
                self.mimes.append(std.heap.smp_allocator, mime) catch std.heap.smp_allocator.free(mime);
            },
        }
    }

    fn has(self: *const Offer, mime: []const u8) bool {
        for (self.mimes.items) |m| if (std.mem.eql(u8, m, mime)) return true;
        return false;
    }
};

const Device = struct {
    offers: std.ArrayList(*Offer) = .empty,
    selection: ?*Offer = null,

    fn onEvent(_: *ext.DataControlDeviceV1, event: ext.DataControlDeviceV1.Event, self: *Device) void {
        switch (event) {
            // The offer's MIME types follow right after this event: listen now.
            .data_offer => |d| {
                const o = std.heap.smp_allocator.create(Offer) catch {
                    d.id.destroy();
                    return;
                };
                o.* = .{ .offer = d.id };
                self.offers.append(std.heap.smp_allocator, o) catch {
                    std.heap.smp_allocator.destroy(o);
                    d.id.destroy();
                    return;
                };
                d.id.setListener(*Offer, Offer.onEvent, o);
            },
            .selection => |s| {
                self.selection = null;
                const id = s.id orelse return;
                for (self.offers.items) |o| {
                    if (o.offer == id) self.selection = o;
                }
            },
            .finished, .primary_selection => {},
        }
    }

    fn deinit(self: *Device) void {
        for (self.offers.items) |o| {
            o.offer.destroy();
            for (o.mimes.items) |m| std.heap.smp_allocator.free(m);
            o.mimes.deinit(std.heap.smp_allocator);
            std.heap.smp_allocator.destroy(o);
        }
        self.offers.deinit(std.heap.smp_allocator);
    }
};

const WaylandRead = union(enum) {
    /// No data-control protocol or no selection: use GdkClipboard.
    unavailable,
    /// This process owns the selection.
    own,
    /// No offered format matches.
    no_match,
    data: []u8,
};

/// Blocking read of the Wayland selection through ext-data-control, on a
/// private Wayland connection. Worker threads only: the selection owner may
/// be our own main loop.
fn readWayland(gpa: std.mem.Allocator, kind: Kind) !WaylandRead {
    var globals: Globals = undefined;
    globals.init(gpa) catch return .unavailable;
    defer globals.deinit();

    const manager = (try globals.bind(ext.DataControlManagerV1, 1)) orelse return .unavailable;
    defer manager.destroy();
    const seat = (try globals.bind(wayland.client.wl.Seat, 7)) orelse return .unavailable;
    defer seat.destroy();
    const dev = try manager.getDataDevice(seat);
    defer dev.destroy();

    var device: Device = .{};
    defer device.deinit();
    dev.setListener(*Device, Device.onEvent, &device);
    // The initial selection (data_offer, its MIME types, selection) is sent
    // right after the device is created.
    if (globals.display.roundtrip() != .SUCCESS) return error.WaylandRoundtrip;

    const selection = device.selection orelse return .unavailable;
    var marker_buf: [64]u8 = undefined;
    if (selection.has(markerMime(&marker_buf))) return .own;

    const preferred: []const []const u8 = switch (kind) {
        .text => &.{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT" },
        .image => &.{"image/png"},
    };
    const mime = for (preferred) |p| {
        if (selection.has(p)) break p;
    } else return .no_match;
    const mime_z = try gpa.dupeZ(u8, mime);
    defer gpa.free(mime_z);

    var fds: [2]c_int = undefined;
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true }) != 0) return error.Pipe;
    defer _ = std.c.close(fds[0]);
    selection.offer.receive(mime_z, fds[1]);
    _ = std.c.close(fds[1]);
    if (globals.display.flush() != .SUCCESS) return error.WaylandFlush;

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        var pfd = [_]std.c.pollfd{.{ .fd = fds[0], .events = std.c.POLL.IN, .revents = 0 }};
        const ready = std.c.poll(&pfd, 1, pipe_timeout_ms);
        if (ready == 0) return error.ClipboardTimeout;
        if (ready < 0) return error.Poll;
        const n = std.c.read(fds[0], &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try list.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return .{ .data = try list.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------
// Public blocking API (worker threads) and writes (any thread)
// ---------------------------------------------------------------------------

/// Read text from the system clipboard. Blocks, so call it from a worker
/// thread (async command, `App.spawn`); on the main thread it returns
/// `error.WouldBlockMainThread` (use `readTextAsync` there).
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    if (onMainThread()) return error.WouldBlockMainThread;
    if (isWayland()) switch (try readWayland(gpa, .text)) {
        .data => |d| return d,
        .own => return (try ownCopy(gpa, .text)) orelse try gpa.dupe(u8, ""),
        .no_match => return gpa.dupe(u8, ""),
        .unavailable => {},
    };
    return (try MainCall.run(gpa, .read_text, null)).?;
}

/// Read a PNG image from the system clipboard, or null if there is none.
/// Worker threads only, like `readText`.
pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    if (onMainThread()) return error.WouldBlockMainThread;
    if (isWayland()) switch (try readWayland(gpa, .image)) {
        .data => |d| return d,
        .own => return ownCopy(gpa, .image),
        .no_match => return null,
        .unavailable => {},
    };
    return MainCall.run(gpa, .read_image, null);
}

/// Write text to the system clipboard. From a worker thread this waits for
/// the main loop to do it.
pub fn writeText(text: []const u8) !void {
    if (onMainThread()) return writeTextMain(text);
    _ = try MainCall.run(std.heap.smp_allocator, .write_text, text);
}

/// Write a PNG image to the system clipboard. Any thread, like `writeText`.
pub fn writeImage(png_bytes: []const u8) !void {
    if (onMainThread()) return writeImageMain(png_bytes);
    _ = try MainCall.run(std.heap.smp_allocator, .write_image, png_bytes);
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var globals: Globals = undefined;
    const wayland_ok = if (globals.init(gpa)) |_| true else |_| false;
    defer if (wayland_ok) globals.deinit();

    var protocol: []const u8 = "none";
    if (wayland_ok) {
        if (try globals.bind(ext.DataControlManagerV1, 1)) |m| {
            protocol = "ext_data_control_manager_v1";
            m.destroy();
        } else if (try globals.bind(wayland.client.zwlr.DataControlManagerV1, 2)) |m| {
            // Detected, but background reads only use ext-data-control.
            protocol = "zwlr_data_control_manager_v1 (unused)";
            m.destroy();
        }
    }
    const background = std.mem.startsWith(u8, protocol, "ext_");
    // The app initializes GTK; the plugin only uses a display that exists.
    const gdk_ok = gdk.Display.getDefault() != null;

    return .{
        .module = "clipboard",
        .ok = background or gdk_ok,
        .detail = if (background)
            try std.fmt.allocPrint(gpa, "background clipboard via {s}", .{protocol})
        else if (gdk_ok)
            try std.fmt.allocPrint(gpa, "GdkClipboard on the app's display (Wayland data-control: {s})", .{protocol})
        else
            try std.fmt.allocPrint(gpa, "no clipboard backend available (no ext-data-control, no GDK display)", .{}),
    };
}

test "markerMime is per process" {
    var buf: [64]u8 = undefined;
    const m = markerMime(&buf);
    try std.testing.expect(std.mem.startsWith(u8, m, "application/x-oriel-owner-"));
    var pid_buf: [16]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, m, try std.fmt.bufPrint(&pid_buf, "-{d}", .{std.c.getpid()})));
}

test "remember keeps one kind" {
    const gpa = std.testing.allocator;
    try remember(.text, "hello");
    {
        const t = (try ownCopy(gpa, .text)).?;
        defer gpa.free(t);
        try std.testing.expectEqualStrings("hello", t);
        try std.testing.expect((try ownCopy(gpa, .image)) == null);
    }
    try remember(.image, "\x89PNG");
    try std.testing.expect((try ownCopy(gpa, .text)) == null);
    const i = (try ownCopy(gpa, .image)).?;
    defer gpa.free(i);
    try std.testing.expectEqualStrings("\x89PNG", i);
}

test "clipboard roundtrip from a worker under xvfb" {
    // Needs a display: only inside scripts/headless.sh (X11).
    if (std.c.getenv("ORIEL_HEADLESS_INNER") == null) return;
    // The test plays the app: it initializes GTK and runs the main loop.
    const gtk = @import("gtk");
    if (gtk.initCheck() == 0) return error.SkipZigTest;

    const W = struct {
        var result: ?anyerror![]u8 = null;
        var finished: std.atomic.Value(bool) = .init(false);
        fn run() void {
            result = if (writeText("oriel clipboard test 12345")) readText(std.testing.allocator) else |e| e;
            finished.store(true, .release);
            glib.MainContext.default().wakeup();
        }
    };
    const ctx = glib.MainContext.default();
    try std.testing.expect(ctx.acquire() != 0);
    defer ctx.release();
    try std.testing.expectError(error.WouldBlockMainThread, readText(std.testing.allocator));

    const thread = try std.Thread.spawn(.{}, W.run, .{});
    while (!W.finished.load(.acquire)) _ = ctx.iteration(1);
    thread.join();

    const text = try W.result.?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("oriel clipboard test 12345", text);
}
