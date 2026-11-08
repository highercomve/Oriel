//! The settings store on macOS and iOS (the folder is
//! `oriel.paths.appConfig`, `~/Library/Application Support/<app_id>`).
//!
//! Files are replaced atomically (`posix.zig`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const posix = @import("posix.zig");

const c = std.c;

extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;
const _CS_DARWIN_USER_TEMP_DIR = 65537;

pub const Backend = struct {
    pub const Mutex = posix.Mutex;
    pub const readFile = posix.readFile;
    pub const writeFileAtomic = posix.writeFileAtomic;
    pub const configDir = common.configDir;
};

pub const Store = common.GenericStore(Backend);

fn userTempDir(buf: []u8) []const u8 {
    if (c.getenv("TMPDIR")) |t| {
        const dir = std.mem.trimEnd(u8, std.mem.span(t), "/");
        if (dir.len > 0 and !std.mem.eql(u8, dir, "/tmp") and !std.mem.eql(u8, dir, "/private/tmp")) return dir;
    }
    const n = confstr(_CS_DARWIN_USER_TEMP_DIR, buf.ptr, buf.len);
    if (n > 1 and n <= buf.len) {
        const dir = std.mem.trimEnd(u8, buf[0 .. n - 1], "/");
        if (dir.len > 0) return dir;
    }
    return "/tmp";
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_dir = userTempDir(&tmp_buf);
    const test_path = try std.fmt.allocPrintSentinel(gpa, "{s}/oriel_check_store.{d}.json", .{ tmp_dir, c.getpid() }, 0);
    defer gpa.free(test_path);
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
    const val = (try s.getString(gpa, "test_key")) orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    defer gpa.free(val);
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
    const name = (try reopened.getString(gpa, "name")).?;
    defer gpa.free(name);
    try std.testing.expectEqualStrings("oriel", name);
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
