//! localStorage for native-renderer pages (main.js `localStorage`): one
//! store per app, every window's page sharing it, kept here and saved as
//! JSON in the app's config directory so it outlives the process, as a
//! WebView's does:
//!
//!   Linux, BSD  $XDG_CONFIG_HOME/<app id>/data/localStorage.json
//!               (~/.config/<app id>/data/... without XDG_CONFIG_HOME)
//!   macOS       ~/Library/Application Support/<app id>/data/...
//!   Windows     %APPDATA%\<app id>\data\...
//!
//! Elsewhere (Android, iOS), or without an app id, it lasts the run.
//!
//! The page calls in synchronously (host.storageGet and the rest, on the UI
//! thread); a change marks the store dirty, and the page asks for a flush
//! a moment later (main.js), so a burst of writes is one file write. The
//! file is replaced whole (written beside it, then renamed over it).

const std = @import("std");
const builtin = @import("builtin");
const App = @import("../core/App.zig");

/// Keys and values together, in bytes: browsers allow about 5 MB an origin.
pub const quota = 5 * 1024 * 1024;

const file_name = "localStorage.json";

var mutex: std.Io.Mutex = .init;
/// Insertion order, as browsers' key(i) keeps it.
var map: std.StringArrayHashMapUnmanaged([]u8) = .empty;
var used: usize = 0;
var loaded = false;
var dirty = false;
/// The data directory, or null: the store lasts the run.
var dir_path: ?[]u8 = null;

fn gpa() std.mem.Allocator {
    return std.heap.smp_allocator;
}

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn lock() void {
    std.Io.Threaded.mutexLock(&mutex);
}

fn unlock() void {
    std.Io.Threaded.mutexUnlock(&mutex);
}

/// The app's data directory for this OS (see the top), or null.
fn dataDir(a: std.mem.Allocator, app_id: []const u8) ?[]u8 {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const v = std.c.getenv(name) orelse return null;
            const s = std.mem.span(v);
            return if (s.len > 0) s else null;
        }
    }.get;
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => if (builtin.abi.isAndroid()) null else if (env("XDG_CONFIG_HOME")) |x|
            std.fs.path.join(a, &.{ x, app_id, "data" }) catch null
        else if (env("HOME")) |h|
            std.fs.path.join(a, &.{ h, ".config", app_id, "data" }) catch null
        else
            null,
        .macos => if (env("HOME")) |h| std.fs.path.join(a, &.{ h, "Library", "Application Support", app_id, "data" }) catch null else null,
        .windows => if (env("APPDATA")) |d| std.fs.path.join(a, &.{ d, app_id, "data" }) catch null else null,
        else => null,
    };
}

/// The saved store, read once (the first page to touch localStorage).
fn ensureLoaded() void {
    if (loaded) return;
    loaded = true;
    const id = App.current_app_id orelse return;
    dir_path = dataDir(gpa(), id);
    const dir = dir_path orelse return;
    const path = std.fs.path.join(gpa(), &.{ dir, file_name }) catch return;
    defer gpa().free(path);
    loadFile(path);
}

/// The entries of a saved store (a JSON object of strings), added.
fn loadFile(path: []const u8) void {
    const text = std.Io.Dir.cwd().readFileAlloc(io(), path, gpa(), .limited(quota * 2 + 64 * 1024)) catch return;
    defer gpa().free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa(), text, .{}) catch {
        std.log.scoped(.native_ui).warn("localStorage: {s} isn't valid JSON, starting empty", .{path});
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        const v = switch (e.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        putLocked(e.key_ptr.*, v) catch break;
    }
}

fn putLocked(key: []const u8, value: []const u8) error{ Quota, OutOfMemory }!void {
    const old = map.get(key);
    const after = used - (if (old) |o| key.len + o.len else 0) + key.len + value.len;
    if (after > quota) return error.Quota;
    const v = try gpa().dupe(u8, value);
    errdefer gpa().free(v);
    const gop = try map.getOrPut(gpa(), key);
    if (gop.found_existing) {
        gpa().free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa().dupe(u8, key) catch |err| {
            map.swapRemoveAt(gop.index);
            return err;
        };
    }
    gop.value_ptr.* = v;
    used = after;
}

/// A key's value, copied with `a` (null: no such key).
pub fn get(a: std.mem.Allocator, key: []const u8) ?[]u8 {
    lock();
    defer unlock();
    ensureLoaded();
    const v = map.get(key) orelse return null;
    return a.dupe(u8, v) catch null;
}

/// Set a key: error.Quota past the quota (nothing changed then).
pub fn set(key: []const u8, value: []const u8) error{ Quota, OutOfMemory }!void {
    lock();
    defer unlock();
    ensureLoaded();
    if (map.get(key)) |old| if (std.mem.eql(u8, old, value)) return;
    try putLocked(key, value);
    dirty = true;
}

pub fn remove(key: []const u8) void {
    lock();
    defer unlock();
    ensureLoaded();
    const kv = map.fetchOrderedRemove(key) orelse return;
    used -= kv.key.len + kv.value.len;
    gpa().free(kv.key);
    gpa().free(kv.value);
    dirty = true;
}

pub fn clear() void {
    lock();
    defer unlock();
    ensureLoaded();
    if (map.count() == 0) return;
    clearLocked();
    dirty = true;
}

fn clearLocked() void {
    var it = map.iterator();
    while (it.next()) |e| {
        gpa().free(e.key_ptr.*);
        gpa().free(e.value_ptr.*);
    }
    map.clearRetainingCapacity();
    used = 0;
}

pub fn count() usize {
    lock();
    defer unlock();
    ensureLoaded();
    return map.count();
}

/// The i-th key, copied with `a` (null past the end).
pub fn keyAt(a: std.mem.Allocator, i: usize) ?[]u8 {
    lock();
    defer unlock();
    ensureLoaded();
    if (i >= map.count()) return null;
    return a.dupe(u8, map.keys()[i]) catch null;
}

/// Save the store if it changed since the last save.
pub fn flush() void {
    lock();
    defer unlock();
    if (!dirty) return;
    const dir = dir_path orelse {
        dirty = false;
        return;
    };
    save(dir) catch |err| {
        std.log.scoped(.native_ui).warn("localStorage: not saved in {s}: {s}", .{ dir, @errorName(err) });
        return;
    };
    dirty = false;
}

fn save(dir: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa());
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer };
    try js.beginObject();
    var it = map.iterator();
    while (it.next()) |e| {
        try js.objectField(e.key_ptr.*);
        try js.write(e.value_ptr.*);
    }
    try js.endObject();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io(), dir);
    const path = try std.fs.path.join(gpa(), &.{ dir, file_name });
    defer gpa().free(path);
    const tmp = try std.mem.concat(gpa(), u8, &.{ path, ".tmp" });
    defer gpa().free(tmp);
    try cwd.writeFile(io(), .{ .sub_path = tmp, .data = out.written() });
    try cwd.rename(tmp, cwd, path, io());
}

/// Tests: forget the store (and where it's saved).
fn resetForTest() void {
    clearLocked();
    map.deinit(gpa());
    map = .empty;
    loaded = false;
    dirty = false;
    if (dir_path) |d| gpa().free(d);
    dir_path = null;
}

test "localStorage: set, get, remove, quota, and the file it's saved to" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];

    defer resetForTest();
    resetForTest();
    loaded = true; // no app id here: the directory is the test's
    dir_path = try std.fs.path.join(gpa(), &.{ root, "dev.oriel.Test", "data" });

    try set("theme", "dark");
    try set("n", "1");
    try t.expectEqual(@as(usize, 2), count());
    const v = get(t.allocator, "theme").?;
    defer t.allocator.free(v);
    try t.expectEqualStrings("dark", v);
    try t.expect(get(t.allocator, "missing") == null);
    const k = keyAt(t.allocator, 1).?;
    defer t.allocator.free(k);
    try t.expectEqualStrings("n", k);
    // Past the quota: refused, nothing changed.
    const big = try t.allocator.alloc(u8, quota);
    defer t.allocator.free(big);
    @memset(big, 'x');
    try t.expectError(error.Quota, set("big", big));
    try t.expectEqual(@as(usize, 2), count());
    remove("n");
    try t.expectEqual(@as(usize, 1), count());

    flush();
    const saved = try tmp.dir.readFileAlloc(t.io, "dev.oriel.Test/data/" ++ file_name, t.allocator, .limited(4096));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("{\"theme\":\"dark\"}", saved);

    // A new run reads it back.
    clearLocked();
    {
        const path = try std.fs.path.join(gpa(), &.{ dir_path.?, file_name });
        defer gpa().free(path);
        loadFile(path);
    }
    const again = get(t.allocator, "theme").?;
    defer t.allocator.free(again);
    try t.expectEqualStrings("dark", again);
}
