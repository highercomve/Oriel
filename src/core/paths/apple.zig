//! oriel.paths on macOS and iOS (Apple's File System Programming Guide):
//! `$HOME/Library/Application Support/<name>` for data and config (Apple
//! has no separate config folder), `$HOME/Library/Caches/<name>` for the
//! cache. On iOS `$HOME` is the app's container.

const std = @import("std");
const Kind = @import("kind.zig").Kind;
const makePath = @import("posix.zig").makePath;

/// `$HOME/Library/<folder for kind>/<name>`, created if missing. Caller frees.
pub fn appDir(gpa: std.mem.Allocator, kind: Kind, name: []const u8) ![]const u8 {
    const home = std.c.getenv("HOME") orelse return error.HomeNotSet;
    const rel = switch (kind) {
        .data, .config, .external => "Library/Application Support",
        .cache => "Library/Caches",
    };
    const path = try std.fs.path.join(gpa, &.{ std.mem.span(home), rel, name });
    errdefer gpa.free(path);
    try makePath(gpa, path);
    return path;
}

test "dirs live under ~/Library" {
    const gpa = std.testing.allocator;
    const cache = try appDir(gpa, .cache, "dev.oriel.Test");
    defer gpa.free(cache);
    try std.testing.expect(std.mem.endsWith(u8, cache, "/Library/Caches/dev.oriel.Test"));
    // Created by the call; remove what we made.
    const z = try gpa.dupeZ(u8, cache);
    defer gpa.free(z);
    _ = std.c.rmdir(z.ptr);
}
