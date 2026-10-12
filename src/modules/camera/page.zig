//! The page's `oriel.camera.capturePhoto({ source, maxSide, format,
//! quality })`: the built-in `camera:capture` command, always async (it
//! waits for the user on an IPC worker, src/core/ipc.zig). It resolves to
//! `{ dataUrl, width, height, mime }`; errors reject with their names
//! ("Cancelled", "Unsupported", "PermissionDenied", "TooLarge").

const std = @import("std");
const common = @import("common.zig");

pub const command = "camera:capture";

pub const Args = struct {
    source: common.Source = .library,
    maxSide: u32 = 1600,
    format: common.Format = .jpeg,
    quality: u8 = 85,
};

pub const Reply = struct {
    dataUrl: []const u8,
    width: u32,
    height: u32,
    mime: []const u8,
};

/// The capture options a page asked for (bad values are error.InvalidOptions).
pub fn options(arena: std.mem.Allocator, args: std.json.Value) !common.Options {
    const a = std.json.parseFromValueLeaky(Args, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidOptions;
    const o: common.Options = .{ .source = a.source, .max_side = a.maxSide, .format = a.format, .quality = a.quality };
    try common.validate(o);
    return o;
}

/// The reply's JSON for `photo` (error.TooLarge past `max_page_bytes`).
pub fn reply(arena: std.mem.Allocator, photo: common.Photo) ![]u8 {
    if (photo.bytes.len > common.max_page_bytes) return error.TooLarge;
    const r: Reply = .{
        .dataUrl = try common.dataUrl(arena, photo.mime, photo.bytes),
        .width = photo.width,
        .height = photo.height,
        .mime = photo.mime,
    };
    return std.json.Stringify.valueAlloc(arena, r, .{});
}

/// `camera:capture` from the page.
pub fn capture(io: std.Io, arena: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const camera = @import("../camera.zig");
    const photo = try camera.capturePhoto(io, arena, try options(arena, args));
    return reply(arena, photo);
}

test options {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"source\":\"camera\",\"maxSide\":800,\"quality\":70,\"extra\":1}", .{});
    const o = try options(a, parsed);
    try std.testing.expectEqual(common.Source.camera, o.source);
    try std.testing.expectEqual(@as(u32, 800), o.max_side);
    try std.testing.expectEqual(@as(u8, 70), o.quality);
    try std.testing.expectEqual(common.Format.jpeg, o.format);
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a, "{}", .{});
    try std.testing.expectEqual(@as(u32, 1600), (try options(a, empty)).max_side);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"maxSide\":0}", .{});
    try std.testing.expectError(error.InvalidOptions, options(a, bad));
    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"source\":\"scanner\"}", .{});
    try std.testing.expectError(error.InvalidOptions, options(a, wrong));
    const big = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"quality\":1000}", .{});
    try std.testing.expectError(error.InvalidOptions, options(a, big));
}

test reply {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bytes = [_]u8{ 1, 2, 3 };
    const json = try reply(a, .{ .bytes = &bytes, .width = 2, .height = 1, .mime = "image/jpeg" });
    try std.testing.expectEqualStrings("{\"dataUrl\":\"data:image/jpeg;base64,AQID\",\"width\":2,\"height\":1,\"mime\":\"image/jpeg\"}", json);
}
