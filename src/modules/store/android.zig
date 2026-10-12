//! The settings store on Android: `<filesDir>/<app_id>`, e.g.
//! `/data/user/0/<package>/files/<app_id>` (`common.configDir`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const posix = @import("posix.zig");
const paths = @import("../../core/paths.zig");

pub const Backend = struct {
    pub const Mutex = posix.Mutex;
    pub const readFile = posix.readFile;
    pub const writeFileAtomic = posix.writeFileAtomic;
    pub const configDir = common.configDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const dir = try paths.appCache(gpa, .{ .name = "dev.oriel.Check" });
    defer gpa.free(dir);
    const test_path = try std.fmt.allocPrintSentinel(gpa, "{s}/check_store.json", .{dir}, 0);
    defer gpa.free(test_path);
    _ = std.c.unlink(test_path.ptr);
    defer _ = std.c.unlink(test_path.ptr);
    {
        var w = try Store.openPath(gpa, test_path);
        defer w.deinit();
        try w.set("test_key", "check_value");
    }
    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();
    const val = s.getString("test_key") orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    if (!std.mem.eql(u8, val, "check_value")) return .{ .module = "store", .ok = false, .detail = "stored key mismatch" };
    return .{ .module = "store", .ok = true, .detail = "JSON store roundtrip through disk ok" };
}
