//! Apple clipboard: the general pasteboard (NSPasteboard on macOS,
//! UIPasteboard on iOS), text and PNG images.
//!
//! Every call runs on the main thread (marshalled from workers with
//! `Shell.runOnMainThread`, like Windows), so pasteboard access is
//! serialized with the app's own copy/paste. macOS writes images as PNG and
//! TIFF (what most Mac apps paste) and reads PNG, else converts TIFF; iOS
//! reads PNG, else lets UIKit convert another format. Reading iOS's general
//! pasteboard shows its "pasted from" banner (and, from iOS 16, may ask the
//! user).

const std = @import("std");
const apple = @import("../../platform/apple/apple.zig");
const is_ios = @import("../../core/target.zig").is_ios;
const ShellMod = if (is_ios) @import("../../platform/ios/Shell.zig") else @import("../../platform/macos/Shell.zig");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

const Object = apple.Object;

pub const TextCallback = *const fn (result: anyerror![]const u8, user_data: ?*anyopaque) void;
pub const ImageCallback = *const fn (result: anyerror!?[]const u8, user_data: ?*anyopaque) void;

const type_text = "public.utf8-plain-text"; // NSPasteboardTypeString
const type_png = "public.png"; // NSPasteboardTypePNG

/// Autoreleased NSString for a pasteboard type.
fn typeName(comptime name: []const u8) !Object {
    const s = apple.nsString(name) orelse return error.OutOfMemory;
    return s.msgSend(Object, "autorelease", .{});
}

/// PNG bytes of an NSData (caller frees).
fn dupeData(data: Object, gpa: std.mem.Allocator) ![]u8 {
    const len = data.msgSend(c_ulong, "length", .{});
    const ptr = data.msgSend(?[*]const u8, "bytes", .{}) orelse return try gpa.dupe(u8, "");
    return try gpa.dupe(u8, ptr[0..len]);
}

const Pasteboard = if (is_ios) UIKit else AppKit;

/// NSPasteboard.
const AppKit = struct {
    const name = "NSPasteboard";
    const type_tiff = "public.tiff"; // NSPasteboardTypeTIFF
    const NSBitmapImageFileTypePNG: c_ulong = 4;

    fn general() Object {
        return apple.class(name).msgSend(Object, "generalPasteboard", .{});
    }

    /// Caller frees; "" when there is no text.
    fn readText(pb: Object, gpa: std.mem.Allocator) ![]u8 {
        const str = pb.msgSend(Object, "stringForType:", .{try typeName(type_text)});
        return gpa.dupe(u8, apple.utf8(str) orelse "");
    }

    /// PNG bytes (caller frees), or null when there is no image.
    fn readImage(pb: Object, gpa: std.mem.Allocator) !?[]u8 {
        var data = pb.msgSend(Object, "dataForType:", .{try typeName(type_png)});
        if (data.value == null) {
            const tiff = pb.msgSend(Object, "dataForType:", .{try typeName(type_tiff)});
            if (tiff.value == null) return null;
            const rep = apple.class("NSBitmapImageRep").msgSend(Object, "imageRepWithData:", .{tiff});
            if (rep.value == null) return error.InvalidImage;
            data = rep.msgSend(Object, "representationUsingType:properties:", .{ NSBitmapImageFileTypePNG, apple.class("NSDictionary").msgSend(Object, "dictionary", .{}) });
            if (data.value == null) return error.InvalidImage;
        }
        return try dupeData(data, gpa);
    }

    fn writeText(pb: Object, text: []const u8) !void {
        const str = apple.nsString(text) orelse return error.InvalidUtf8;
        defer str.release();
        _ = pb.msgSend(isize, "clearContents", .{});
        if (!apple.isTrue(pb.msgSend(apple.c.BOOL, "setString:forType:", .{ str, try typeName(type_text) }))) return error.ClipboardWriteFailed;
    }

    fn writeImage(pb: Object, png: []const u8) !void {
        const data = apple.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ png.ptr, @as(c_ulong, png.len) });
        const rep = apple.class("NSBitmapImageRep").msgSend(Object, "imageRepWithData:", .{data});
        if (rep.value == null) return error.InvalidImage; // not an image AppKit can read
        const tiff = rep.msgSend(Object, "TIFFRepresentation", .{});
        _ = pb.msgSend(isize, "clearContents", .{});
        if (!apple.isTrue(pb.msgSend(apple.c.BOOL, "setData:forType:", .{ data, try typeName(type_png) }))) return error.ClipboardWriteFailed;
        if (tiff.value != null) _ = pb.msgSend(apple.c.BOOL, "setData:forType:", .{ tiff, try typeName(type_tiff) });
    }

    /// Drop a pasteboard from `pasteboardWithUniqueName`.
    fn remove(pb: Object) void {
        pb.msgSend(void, "releaseGlobally", .{});
    }
};

/// UIPasteboard.
const UIKit = struct {
    const name = "UIPasteboard";

    extern fn UIImagePNGRepresentation(image: apple.id) apple.id;

    fn general() Object {
        return apple.class(name).msgSend(Object, "generalPasteboard", .{});
    }

    /// Caller frees; "" when there is no text.
    fn readText(pb: Object, gpa: std.mem.Allocator) ![]u8 {
        const str = pb.msgSend(Object, "string", .{});
        return gpa.dupe(u8, apple.utf8(str) orelse "");
    }

    /// PNG bytes (caller frees), or null when there is no image.
    fn readImage(pb: Object, gpa: std.mem.Allocator) !?[]u8 {
        var data = pb.msgSend(Object, "dataForPasteboardType:", .{try typeName(type_png)});
        if (data.value == null) {
            // Another format (JPEG, HEIC...): UIKit converts it.
            const image = pb.msgSend(Object, "image", .{});
            if (image.value == null) return null;
            data = .{ .value = UIImagePNGRepresentation(image.value) };
            if (data.value == null) return error.InvalidImage;
        }
        return try dupeData(data, gpa);
    }

    fn writeText(pb: Object, text: []const u8) !void {
        const str = apple.nsString(text) orelse return error.InvalidUtf8;
        defer str.release();
        pb.msgSend(void, "setString:", .{str});
    }

    fn writeImage(pb: Object, png: []const u8) !void {
        const data = apple.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ png.ptr, @as(c_ulong, png.len) });
        if (apple.class("UIImage").msgSend(Object, "imageWithData:", .{data}).value == null) return error.InvalidImage;
        pb.msgSend(void, "setData:forPasteboardType:", .{ data, try typeName(type_png) });
    }

    /// Drop a pasteboard from `pasteboardWithUniqueName`.
    fn remove(pb: Object) void {
        apple.class(name).msgSend(void, "removePasteboardWithName:", .{pb.msgSend(Object, "name", .{})});
    }
};

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
        const pb = Pasteboard.general();
        switch (self.op) {
            .read_text => self.out = Pasteboard.readText(pb, self.gpa) catch |e| return self.fail(e),
            .read_image => self.out = Pasteboard.readImage(pb, self.gpa) catch |e| return self.fail(e),
            .write_text => Pasteboard.writeText(pb, self.input) catch |e| return self.fail(e),
            .write_image => Pasteboard.writeImage(pb, self.input) catch |e| return self.fail(e),
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
    const pb = apple.class(Pasteboard.name).msgSend(Object, "pasteboardWithUniqueName", .{});
    if (pb.value == null) return .{ .module = "clipboard", .ok = false, .detail = "could not create a pasteboard" };
    defer Pasteboard.remove(pb);

    try Pasteboard.writeText(pb, "oriel clipboard check ✓");
    const text = try Pasteboard.readText(pb, gpa);
    defer gpa.free(text);
    try Pasteboard.writeImage(pb, ctx.icon_png);
    const png = try Pasteboard.readImage(pb, gpa) orelse "";
    defer if (png.len > 0) gpa.free(png);
    const ok = std.mem.eql(u8, text, "oriel clipboard check ✓") and std.mem.eql(u8, png, ctx.icon_png);
    return .{
        .module = "clipboard",
        .ok = ok,
        .detail = try std.fmt.allocPrint(gpa, Pasteboard.name ++ " (private): text round trip {s}, PNG {d} B round trip {s}", .{
            if (std.mem.eql(u8, text, "oriel clipboard check ✓")) "ok" else "FAILED",
            ctx.icon_png.len,
            if (std.mem.eql(u8, png, ctx.icon_png)) "ok" else "FAILED",
        }),
    };
}

test "text and PNG round trips on a private pasteboard" {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const gpa = std.testing.allocator;
    const pb = apple.class(Pasteboard.name).msgSend(Object, "pasteboardWithUniqueName", .{});
    defer Pasteboard.remove(pb);

    try Pasteboard.writeText(pb, "héllo");
    const text = try Pasteboard.readText(pb, gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("héllo", text);

    // A 1x1 PNG.
    const png = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82 };
    try Pasteboard.writeImage(pb, &png);
    const back = (try Pasteboard.readImage(pb, gpa)).?;
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, &png, back);

    try std.testing.expectError(error.InvalidImage, Pasteboard.writeImage(pb, "not a png"));
}
