//! The page's `oriel.video`: the built-in `video:play` and `video:close`
//! commands (src/core/ipc.zig's dispatchBuiltin, on the main thread).
//! `play({ url, title })` resolves once the player is shown; errors reject
//! with their names ("Unsupported", "InvalidUrl", "NoWindow", "Failed").
//! The page sends its window's label, so the player covers that window.

const std = @import("std");
const common = @import("common.zig");

pub const play_command = "video:play";
pub const close_command = "video:close";
pub const rect_command = "video:rect";
pub const fullscreen_command = "video:fullscreen";
pub const visible_command = "video:visible";

pub fn isCommand(cmd: []const u8) bool {
    inline for (.{ play_command, close_command, rect_command, fullscreen_command, visible_command }) |c| if (std.mem.eql(u8, cmd, c)) return true;
    return false;
}

pub const PlayArgs = struct {
    url: []const u8,
    title: []const u8 = "",
    /// Embedded: the page's rectangle for it.
    rect: ?common.Rect = null,
    /// The calling window's label (bridge_api.js sends it).
    label: ?[]const u8 = null,
};

/// A `video:play` call's arguments (error.InvalidArgs when they don't parse).
pub fn playArgs(arena: std.mem.Allocator, args: std.json.Value) error{ InvalidArgs, OutOfMemory }!PlayArgs {
    return std.json.parseFromValueLeaky(PlayArgs, arena, args, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArgs,
    };
}

/// `video:play` or `video:close` from the page; `video` is oriel's video
/// module (the caller has it only when the build does).
pub fn call(comptime video: type, arena: std.mem.Allocator, cmd: []const u8, args: std.json.Value) ![]u8 {
    if (std.mem.eql(u8, cmd, close_command)) {
        video.close();
        return arena.dupe(u8, "null");
    }
    if (std.mem.eql(u8, cmd, rect_command)) {
        const a = std.json.parseFromValueLeaky(struct { rect: common.Rect }, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidArgs;
        try video.setRect(a.rect);
        return arena.dupe(u8, "null");
    }
    if (std.mem.eql(u8, cmd, visible_command)) {
        const a = std.json.parseFromValueLeaky(struct { on: bool }, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidArgs;
        video.setVisible(a.on);
        return arena.dupe(u8, "null");
    }
    if (std.mem.eql(u8, cmd, fullscreen_command)) {
        const a = std.json.parseFromValueLeaky(struct { on: bool }, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidArgs;
        video.setFullscreen(a.on);
        return arena.dupe(u8, "null");
    }
    const a = try playArgs(arena, args);
    const App = @import("../../core/App.zig");
    // Main thread (builtins are): the window pointer is safe to use.
    const win: ?*App.Window = if (a.label) |l| App.getWindow(l) else null;
    try video.play(win, .{ .url = a.url, .title = a.title, .rect = a.rect });
    return arena.dupe(u8, "null");
}

test playArgs {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"url\":\"file:///a.mts\",\"title\":\"Beach\",\"label\":\"main\",\"x\":1}", .{});
    const p = try playArgs(a, v);
    try std.testing.expectEqualStrings("file:///a.mts", p.url);
    try std.testing.expectEqualStrings("Beach", p.title);
    try std.testing.expectEqualStrings("main", p.label.?);
    const bare = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"url\":\"http://127.0.0.1:1/t/a\"}", .{});
    const q = try playArgs(a, bare);
    try std.testing.expectEqualStrings("", q.title);
    try std.testing.expect(q.label == null);
    const embedded = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"url\":\"file:///a.mts\",\"rect\":{\"x\":0,\"y\":64.5,\"width\":412,\"height\":700}}", .{});
    const e = try playArgs(a, embedded);
    try std.testing.expectEqual(@as(f64, 64.5), e.rect.?.y);
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"title\":\"x\"}", .{});
    try std.testing.expectError(error.InvalidArgs, playArgs(a, missing));
    try std.testing.expectError(error.InvalidArgs, playArgs(a, .null));
}

test "playArgs: every allocation failure" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"url\":\"file:///a.mts\",\"title\":\"Beach\",\"label\":\"main\"}", .{});
    defer parsed.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn f(gpa: std.mem.Allocator, value: std.json.Value) !void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const p = try playArgs(arena.allocator(), value);
            try std.testing.expectEqualStrings("Beach", p.title);
        }
    }.f, .{parsed.value});
}

test isCommand {
    try std.testing.expect(isCommand("video:play"));
    try std.testing.expect(isCommand("video:close"));
    try std.testing.expect(isCommand("video:rect"));
    try std.testing.expect(isCommand("video:fullscreen"));
    try std.testing.expect(isCommand("video:visible"));
    try std.testing.expect(!isCommand("video:stop"));
}
