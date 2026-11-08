//! The settings store on Linux: GLib file I/O and mutex (the folder is
//! `oriel.paths.appConfig`, `$XDG_CONFIG_HOME/<app_id>`).

const std = @import("std");
const glib = @import("glib");
const common = @import("common.zig");

const LinuxMutex = struct {
    inner: glib.Mutex = undefined,

    pub fn init(self: *LinuxMutex) void {
        self.inner.init();
    }

    pub fn deinit(self: *LinuxMutex) void {
        self.inner.clear();
    }

    pub fn lock(self: *LinuxMutex) void {
        self.inner.lock();
    }

    pub fn unlock(self: *LinuxMutex) void {
        self.inner.unlock();
    }
};

fn linuxReadFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    var file_bytes: [*]u8 = undefined;
    var file_len: usize = 0;
    var err: ?*glib.Error = null;

    if (glib.fileGetContents(path, &file_bytes, &file_len, &err) != 0) {
        defer glib.free(file_bytes);
        return try gpa.dupe(u8, file_bytes[0..file_len]);
    }
    if (err) |e| {
        defer e.free();
        if (e.matches(glib.fileErrorQuark(), @intFromEnum(glib.FileError.noent)) != 0) return null;
        if (!@import("builtin").is_test) std.log.warn("failed to read store {s}: {s}", .{ path, e.f_message orelse "unknown error" });
        if (e.matches(glib.fileErrorQuark(), @intFromEnum(glib.FileError.nomem)) != 0) return error.OutOfMemory;
        if (e.matches(glib.fileErrorQuark(), @intFromEnum(glib.FileError.acces)) != 0 or
            e.matches(glib.fileErrorQuark(), @intFromEnum(glib.FileError.perm)) != 0) return error.AccessDenied;
    } else {
        if (!@import("builtin").is_test) std.log.warn("failed to read store {s}: unknown GLib error", .{path});
    }
    return error.ReadFailed;
}

fn linuxWriteFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
    var err: ?*glib.Error = null;
    if (glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), &err) == 0) {
        if (err) |e| {
            std.log.err("failed to save store to {s}: {s}", .{ path, e.f_message orelse "unknown error" });
            e.free();
        }
        return error.SaveFailed;
    }
}

pub const Backend = struct {
    pub const Mutex = LinuxMutex;
    pub const readFile = linuxReadFile;
    pub const writeFileAtomic = linuxWriteFileAtomic;
    pub const configDir = common.configDir;
};

pub const Store = common.GenericStore(Backend);

const CheckFile = struct {
    dir: [:0]u8,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator) !CheckFile {
        // GLib uses XDG_RUNTIME_DIR, falling back to the user's cache directory.
        const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/oriel-check-{d}-XXXXXX", .{
            std.mem.span(glib.getUserRuntimeDir()), std.c.getpid(),
        }, 0);
        errdefer gpa.free(dir);
        if (glib.mkdirWithParents(glib.getUserRuntimeDir(), 0o700) != 0) return error.CreateDirectoryFailed;
        if (glib.mkdtempFull(dir, 0o700) == null) return error.CreateDirectoryFailed;
        errdefer _ = std.c.rmdir(dir.ptr);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/store.json", .{dir}, 0);
        return .{ .dir = dir, .path = path };
    }

    fn deinit(self: CheckFile, gpa: std.mem.Allocator) void {
        _ = glib.unlink(self.path);
        _ = std.c.rmdir(self.dir.ptr);
        gpa.free(self.path);
        gpa.free(self.dir);
    }
};

pub fn check(gpa: std.mem.Allocator, _: anytype) !@import("../../oriel.zig").Check {
    const file = try CheckFile.init(gpa);
    defer file.deinit(gpa);
    const test_path = file.path;

    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();

    try s.set("test_key", "check_value");
    const val = (try s.getString(gpa, "test_key")) orelse return .{
        .module = "store",
        .ok = false,
        .detail = "failed to read back stored key",
    };
    defer gpa.free(val);
    if (!std.mem.eql(u8, val, "check_value")) {
        return .{
            .module = "store",
            .ok = false,
            .detail = "stored key mismatch",
        };
    }

    return .{
        .module = "store",
        .ok = true,
        .detail = "JSON store roundtrip ok",
    };
}

test "Store operations and persistence" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    const test_path = try std.fs.path.join(gpa, &.{ dir, "store.json" });
    defer gpa.free(test_path);

    var store = try Store.openPath(gpa, test_path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    try store.set("pi", 3.14);

    const name = (try store.getString(gpa, "name")).?;
    defer gpa.free(name);
    try std.testing.expectEqualStrings("oriel", name);
    try std.testing.expectEqual(@as(i64, 1), store.getInt("version", i64).?);
    try std.testing.expectEqual(true, store.getBool("active").?);
    try std.testing.expect(store.has("pi"));

    store.deinit();

    // Reopen and verify persisted values
    var reopened = try Store.openPath(gpa, test_path);
    defer reopened.deinit();

    const reopened_name = (try reopened.getString(gpa, "name")).?;
    defer gpa.free(reopened_name);
    try std.testing.expectEqualStrings("oriel", reopened_name);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    _ = reopened.delete("name");
    try std.testing.expect(!reopened.has("name"));
}

fn checkFileAllocationFailures(gpa: std.mem.Allocator) !void {
    const a = try CheckFile.init(gpa);
    defer a.deinit(gpa);
    const b = try CheckFile.init(gpa);
    defer b.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u8, a.path, b.path));
    try std.testing.expectEqualStrings(std.mem.span(glib.getUserRuntimeDir()), std.fs.path.dirname(a.dir).?);
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, a.dir, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), stat.permissions.toMode() & 0o777);
}

test "store checks use unique private files and clean partial construction" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFileAllocationFailures, .{});
    try std.testing.expect((try check(std.testing.allocator, .{})).ok);
}

test "Store refuses a directory and preserves its contents" {
    const gpa = std.testing.allocator;
    const file = try CheckFile.init(gpa);
    defer file.deinit(gpa);
    const original = "{\"kept\":true}";
    try linuxWriteFileAtomic(file.path, original);

    try std.testing.expectError(error.ReadFailed, Store.openPath(gpa, file.dir));
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, file.dir, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    const content = (try linuxReadFile(gpa, file.path)).?;
    defer gpa.free(content);
    try std.testing.expectEqualStrings(original, content);
}

test "Store refuses an unreadable file without changing it" {
    if (std.c.geteuid() == 0) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const file = try CheckFile.init(gpa);
    defer file.deinit(gpa);
    const original = "{\"kept\":true}";
    try linuxWriteFileAtomic(file.path, original);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(file.path.ptr, 0));
    defer _ = std.c.chmod(file.path.ptr, 0o600);

    try std.testing.expectError(error.AccessDenied, Store.openPath(gpa, file.path));
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, file.path, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(file.path.ptr, 0o600));
    const content = (try linuxReadFile(gpa, file.path)).?;
    defer gpa.free(content);
    try std.testing.expectEqualStrings(original, content);
}
