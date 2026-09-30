//! iOS clipboard: UIPasteboard (general pasteboard), text and PNG images.
//!
//! Every call runs on the main thread (marshalled from workers with
//! `Shell.runOnMainThread`, as on macOS). Reading the general pasteboard
//! shows iOS's "pasted from" banner (and, from iOS 16, may ask the user).

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const ShellMod = @import("../../platform/ios/Shell.zig");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

const Object = apple.Object;

pub const TextCallback = *const fn (result: anyerror![]const u8, user_data: ?*anyopaque) void;
pub const ImageCallback = *const fn (result: anyerror!?[]const u8, user_data: ?*anyopaque) void;

const type_text = "public.utf8-plain-text";
const type_png = "public.png";

extern fn UIImagePNGRepresentation(image: apple.id) apple.id;

fn general() Object {
    return apple.class("UIPasteboard").msgSend(Object, "generalPasteboard", .{});
}

/// Autoreleased NSString for a pasteboard type.
fn typeName(comptime name: []const u8) !Object {
    const s = apple.nsString(name) orelse return error.OutOfMemory;
    return s.msgSend(Object, "autorelease", .{});
}

/// Caller frees; "" when there is no text.
fn readTextFrom(pb: Object, gpa: std.mem.Allocator) ![]u8 {
    const str = pb.msgSend(Object, "string", .{});
    return gpa.dupe(u8, apple.utf8(str) orelse "");
}

/// PNG bytes (caller frees), or null when there is no image.
fn readImageFrom(pb: Object, gpa: std.mem.Allocator) !?[]u8 {
    var data = pb.msgSend(Object, "dataForPasteboardType:", .{try typeName(type_png)});
    if (data.value == null) {
        // Another format (JPEG, HEIC...): UIKit converts it.
        const image = pb.msgSend(Object, "image", .{});
        if (image.value == null) return null;
        data = .{ .value = UIImagePNGRepresentation(image.value) };
        if (data.value == null) return error.InvalidImage;
    }
    const len = data.msgSend(c_ulong, "length", .{});
    const ptr = data.msgSend(?[*]const u8, "bytes", .{}) orelse return try gpa.dupe(u8, "");
    return try gpa.dupe(u8, ptr[0..len]);
}

fn writeTextTo(pb: Object, text: []const u8) !void {
    const str = apple.nsString(text) orelse return error.InvalidUtf8;
    defer str.release();
    pb.msgSend(void, "setString:", .{str});
}

fn writeImageTo(pb: Object, png: []const u8) !void {
    const data = apple.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ png.ptr, @as(c_ulong, png.len) });
    if (apple.class("UIImage").msgSend(Object, "imageWithData:", .{data}).value == null) return error.InvalidImage;
    pb.msgSend(void, "setData:forPasteboardType:", .{ data, try typeName(type_png) });
}

// --- Marshalling --------------------------------------------------------------------

const Call = struct {
    op: enum { read_text, read_image, write_text, write_image },
    gpa: std.mem.Allocator = std.heap.smp_allocator,
    input: []const u8 = "",
    out: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *Call) void {
        const pool = apple.objc.AutoreleasePool.init();
        defer pool.deinit();
        const pb = general();
        switch (self.op) {
            .read_text => self.out = readTextFrom(pb, self.gpa) catch |e| return self.fail(e),
            .read_image => self.out = readImageFrom(pb, self.gpa) catch |e| return self.fail(e),
            .write_text => writeTextTo(pb, self.input) catch |e| return self.fail(e),
            .write_image => writeImageTo(pb, self.input) catch |e| return self.fail(e),
        }
    }

    fn fail(self: *Call, e: anyerror) void {
        self.err = e;
    }
};

fn dispatchSync(call: *Call) !void {
    try ShellMod.runOnMainThread(Call, call, Call.run);
    if (call.err) |e| return e;
}

/// Caller frees.
pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    var call: Call = .{ .op = .read_text, .gpa = gpa };
    try dispatchSync(&call);
    return call.out orelse try gpa.dupe(u8, "");
}

/// PNG bytes (caller frees), or null when the clipboard holds no image.
pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
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

/// Read on the main thread and call back there (or at once with
/// error.AppNotRunning).
pub fn readTextAsync(callback: TextCallback, user_data: ?*anyopaque) void {
    const Req = struct {
        callback: TextCallback,
        user_data: ?*anyopaque,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(self);
            var call: Call = .{ .op = .read_text };
            call.run();
            if (call.err) |e| return self.callback(e, self.user_data);
            const text = call.out orelse "";
            defer if (call.out) |o| std.heap.smp_allocator.free(o);
            self.callback(text, self.user_data);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(self);
            self.callback(error.AppNotRunning, self.user_data);
        }
    };
    if (!ShellMod.isRunning()) return callback(error.AppNotRunning, user_data);
    const req = std.heap.smp_allocator.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    ShellMod.dispatchWithCleanup(&Req.run, req, &Req.cleanup);
}

pub fn readImageAsync(callback: ImageCallback, user_data: ?*anyopaque) void {
    const Req = struct {
        callback: ImageCallback,
        user_data: ?*anyopaque,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(self);
            var call: Call = .{ .op = .read_image };
            call.run();
            if (call.err) |e| return self.callback(e, self.user_data);
            defer if (call.out) |o| std.heap.smp_allocator.free(o);
            self.callback(call.out, self.user_data);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(self);
            self.callback(error.AppNotRunning, self.user_data);
        }
    };
    if (!ShellMod.isRunning()) return callback(error.AppNotRunning, user_data);
    const req = std.heap.smp_allocator.create(Req) catch |err| return callback(err, user_data);
    req.* = .{ .callback = callback, .user_data = user_data };
    ShellMod.dispatchWithCleanup(&Req.run, req, &Req.cleanup);
}

/// Text and PNG round trips on a private pasteboard: the user's clipboard
/// is left alone.
pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const pb = apple.class("UIPasteboard").msgSend(Object, "pasteboardWithUniqueName", .{});
    if (pb.value == null) return .{ .module = "clipboard", .ok = false, .detail = "could not create a pasteboard" };
    defer apple.class("UIPasteboard").msgSend(void, "removePasteboardWithName:", .{pb.msgSend(Object, "name", .{})});

    try writeTextTo(pb, "oriel clipboard check ✓");
    const text = try readTextFrom(pb, gpa);
    defer gpa.free(text);
    try writeImageTo(pb, ctx.icon_png);
    const png = try readImageFrom(pb, gpa) orelse "";
    defer if (png.len > 0) gpa.free(png);
    const ok = std.mem.eql(u8, text, "oriel clipboard check ✓") and std.mem.eql(u8, png, ctx.icon_png);
    return .{
        .module = "clipboard",
        .ok = ok,
        .detail = try std.fmt.allocPrint(gpa, "UIPasteboard (private): text round trip {s}, PNG {d} B round trip {s}", .{
            if (std.mem.eql(u8, text, "oriel clipboard check ✓")) "ok" else "FAILED",
            ctx.icon_png.len,
            if (std.mem.eql(u8, png, ctx.icon_png)) "ok" else "FAILED",
        }),
    };
}
