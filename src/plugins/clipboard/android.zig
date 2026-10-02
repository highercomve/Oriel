//! Android clipboard (`ClipboardManager`), through the Kotlin runtime.
//!
//! Text is plain text. Images: reading takes the first image `Uri` of the
//! clip (re-encoded as PNG); writing shares the PNG through the runtime's
//! `FileProvider`. Android 10+ lets only the app in focus (or the default
//! input method) read the clipboard: reads from the background return "".
//! A read off the UI thread waits a moment for a window to get focus, so one
//! made as a window opens (GhostPen's menu reads the selection then) sees
//! the clipboard.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

pub const common = @import("common.zig");

pub const TextCallback = *const fn (result: anyerror![]const u8, user_data: ?*anyopaque) void;
pub const ImageCallback = *const fn (result: anyerror!?[]const u8, user_data: ?*anyopaque) void;

const Call = struct {
    op: enum { read_text, read_image, write_text, write_image, focused },
    gpa: std.mem.Allocator = heap.gpa,
    input: []const u8 = "",
    out: ?[]u8 = null,
    err: ?anyerror = null,

    /// UI thread.
    fn run(self: *Call) void {
        const e = runtime.mainEnv() orelse {
            self.err = error.AppNotRunning;
            return;
        };
        switch (self.op) {
            .focused => self.err = if (runtime.call(.boolean, "hasFocus", "()Z", .{}) orelse false) null else error.NotFocused,
            .read_text => {
                const arr = runtime.call(.object, "clipboardReadText", "()[B", .{}) orelse null;
                self.out = runtime.takeBytes(e, self.gpa, arr);
            },
            .read_image => {
                const arr = runtime.call(.object, "clipboardReadImage", "()[B", .{}) orelse null;
                self.out = runtime.takeBytes(e, self.gpa, arr);
            },
            .write_text => {
                if (!(runtime.call(.boolean, "clipboardWriteText", "([B)Z", .{self.input}) orelse false)) self.err = error.ClipboardWriteFailed;
            },
            .write_image => {
                if (!std.mem.startsWith(u8, self.input, "\x89PNG\r\n\x1a\n")) {
                    self.err = error.InvalidImage;
                    return;
                }
                if (!(runtime.call(.boolean, "clipboardWriteImage", "([B)Z", .{self.input}) orelse false)) self.err = error.ClipboardWriteFailed;
            },
        }
    }
};

fn dispatchSync(call: *Call) !void {
    try ShellMod.runOnMainThread(Call, call, Call.run);
    if (call.err) |e| return e;
}

/// Off the UI thread: wait (up to 1.5 s) for one of the app's windows to have
/// focus. The UI thread can't wait (focus arrives on it), so it reads now.
fn waitForFocus() void {
    if (ShellMod.isMainThread()) return;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var call: Call = .{ .op = .focused };
        ShellMod.runOnMainThread(Call, &call, Call.run) catch return;
        if (call.err == null) return;
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Caller frees.
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    waitForFocus();
    var call: Call = .{ .op = .read_text, .gpa = gpa };
    try dispatchSync(&call);
    return call.out orelse try gpa.dupe(u8, "");
}

/// PNG bytes (caller frees), or null when the clipboard holds no image.
pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    waitForFocus();
    var call: Call = .{ .op = .read_image, .gpa = gpa };
    try dispatchSync(&call);
    return call.out;
}

pub fn writeText(text: []const u8) !void {
    var call: Call = .{ .op = .write_text, .input = text };
    try dispatchSync(&call);
}

pub fn writeImage(png_bytes: []const u8) !void {
    var call: Call = .{ .op = .write_image, .input = png_bytes };
    try dispatchSync(&call);
}

/// Read on the UI thread and call back there (or at once with
/// error.AppNotRunning).
pub fn readTextAsync(callback: TextCallback, user_data: ?*anyopaque) void {
    const Req = struct {
        callback: TextCallback,
        user_data: ?*anyopaque,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer heap.gpa.destroy(self);
            var call: Call = .{ .op = .read_text };
            call.run();
            if (call.err) |e| return self.callback(e, self.user_data);
            defer if (call.out) |o| heap.gpa.free(o);
            self.callback(call.out orelse "", self.user_data);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer heap.gpa.destroy(self);
            self.callback(error.AppNotRunning, self.user_data);
        }
    };
    if (!ShellMod.isRunning()) return callback(error.AppNotRunning, user_data);
    const req = heap.gpa.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    ShellMod.dispatchWithCleanup(&Req.run, req, &Req.cleanup);
}

pub fn readImageAsync(callback: ImageCallback, user_data: ?*anyopaque) void {
    const Req = struct {
        callback: ImageCallback,
        user_data: ?*anyopaque,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer heap.gpa.destroy(self);
            var call: Call = .{ .op = .read_image };
            call.run();
            if (call.err) |e| return self.callback(e, self.user_data);
            defer if (call.out) |o| heap.gpa.free(o);
            self.callback(call.out, self.user_data);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer heap.gpa.destroy(self);
            self.callback(error.AppNotRunning, self.user_data);
        }
    };
    if (!ShellMod.isRunning()) return callback(error.AppNotRunning, user_data);
    const req = heap.gpa.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    ShellMod.dispatchWithCleanup(&Req.run, req, &Req.cleanup);
}

/// Text round trip (the user's clipboard is replaced: Android has no
/// private clipboards), and whether PNG writes are accepted.
pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    try writeText("oriel clipboard check ✓");
    const text = try readText(gpa);
    defer gpa.free(text);
    const text_ok = std.mem.eql(u8, text, "oriel clipboard check ✓");
    const image_ok = if (writeImage(ctx.icon_png)) true else |_| false;
    return .{
        .module = "clipboard",
        .ok = text_ok and image_ok,
        .detail = try std.fmt.allocPrint(gpa, "ClipboardManager: text round trip {s}, PNG write {s}", .{
            if (text_ok) "ok" else "FAILED",
            if (image_ok) "ok" else "FAILED",
        }),
    };
}
