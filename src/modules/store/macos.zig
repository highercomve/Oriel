//! The settings store on macOS and iOS (the folder is
//! `oriel.paths.appConfig`, `~/Library/Application Support/<app_id>`).
//!
//! Files are replaced atomically (`posix.zig`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const posix = @import("posix.zig");

const c = std.c;

pub const Backend = struct {
    pub const Mutex = posix.Mutex;
    pub const readFile = posix.readFile;
    pub const writeFileAtomic = posix.writeFileAtomic;
    pub const configDir = common.configDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var dir_buf: [64]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&dir_buf, "/tmp/oriel_check_store.{d}.json", .{c.getpid()});
    _ = c.unlink(test_path.ptr);
    defer _ = c.unlink(test_path.ptr);

    {
        var w = try Store.openPath(gpa, test_path);
        defer w.deinit();
        try w.set("test_key", "check_value");
    }
    // Reopen: the value must come back from disk.
    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();
    const val = s.getString("test_key") orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    if (!std.mem.eql(u8, val, "check_value")) return .{ .module = "store", .ok = false, .detail = "stored key mismatch" };

    return .{ .module = "store", .ok = true, .detail = "JSON store roundtrip through disk ok" };
}

test "Store persists across reopen, atomic writes leave no temp files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "settings.json" });
    defer gpa.free(path);

    var store = try Store.openPath(gpa, path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    store.deinit();

    var reopened = try Store.openPath(gpa, path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings("oriel", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    var it = tmp.dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp.") == null);
        files += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), files);
}
