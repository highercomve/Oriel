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

/// The entries of a saved store (a JSON object of strings), added. A file
/// that can't be read back (unreadable, not JSON, not an object) is moved
/// aside, to localStorage.json.corrupt-<unix seconds>, and the store starts
/// empty: the next save writes a fresh file instead of replacing the only
/// copy of the data.
fn loadFile(path: []const u8) void {
    // Saved as JSON, a byte can take up to six (\u0001), keys and values
    // alike: room for a full store of the worst case, and the punctuation.
    const text = std.Io.Dir.cwd().readFileAlloc(io(), path, gpa(), .limited(quota * 6 + 64 * 1024)) catch |err| {
        if (err != error.FileNotFound) moveAside(path, @errorName(err));
        return;
    };
    defer gpa().free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa(), text, .{}) catch {
        moveAside(path, "not valid JSON");
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        moveAside(path, "not a JSON object");
        return;
    }
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        const v = switch (e.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        putLocked(e.key_ptr.*, v) catch break;
    }
}

/// Rename an unreadable store file out of the way (see loadFile).
fn moveAside(path: []const u8, why: []const u8) void {
    const log = std.log.scoped(.native_ui);
    const secs = std.Io.Timestamp.now(io(), .real).toSeconds();
    var buf: [32]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, ".corrupt-{d}", .{secs}) catch unreachable;
    const aside = std.mem.concat(gpa(), u8, &.{ path, suffix }) catch {
        forgetDir(); // can't keep the file: don't overwrite it either
        log.warn("localStorage: {s} unreadable ({s}), not saving this run", .{ path, why });
        return;
    };
    defer gpa().free(aside);
    const cwd = std.Io.Dir.cwd();
    cwd.rename(path, cwd, aside, io()) catch |err| {
        forgetDir();
        log.warn("localStorage: {s} unreadable ({s}) and not moved aside ({s}), not saving this run", .{ path, why, @errorName(err) });
        return;
    };
    // (Not in tests: the test that makes one would read as failed.)
    if (!builtin.is_test) log.warn("localStorage: {s} unreadable ({s}), moved to {s}, starting empty", .{ path, why, aside });
}

/// The store lasts the run from here on (nowhere it may be saved).
fn forgetDir() void {
    if (dir_path) |d| gpa().free(d);
    dir_path = null;
}

/// A copy of `s` with each invalid UTF-8 sequence as U+FFFD, or `s` itself
/// when it's valid (`copied` says which). QuickJS hands over a lone
/// surrogate as its WTF-8 bytes, which std.json writes out raw (or as a
/// number array): the file wouldn't parse back. As tree.zig's
/// dupeUtf8Lossy.
fn utf8Lossy(s: []const u8, copied: *bool) error{OutOfMemory}![]const u8 {
    copied.* = false;
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa());
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len > 0 and i + len <= s.len and std.meta.isError(std.unicode.utf8Decode(s[i .. i + len])) == false) {
            try out.appendSlice(gpa(), s[i .. i + len]);
            i += len;
        } else if (len == 3 and i + 3 <= s.len and s[i] == 0xed and s[i + 1] >= 0xa0 and s[i + 1] <= 0xbf) {
            // A surrogate, one U+FFFD as String.prototype.toWellFormed.
            try out.appendSlice(gpa(), "\u{FFFD}");
            i += 3;
        } else {
            try out.appendSlice(gpa(), "\u{FFFD}");
            i += 1;
        }
    }
    copied.* = true;
    return out.toOwnedSlice(gpa());
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
    var kc: bool = undefined;
    const k = utf8Lossy(key, &kc) catch return null;
    defer if (kc) gpa().free(k);
    const v = map.get(k) orelse return null;
    return a.dupe(u8, v) catch null;
}

/// Set a key: error.Quota past the quota (nothing changed then). Keys and
/// values are kept as valid UTF-8 (see utf8Lossy), so the file reads back.
pub fn set(key_in: []const u8, value_in: []const u8) error{ Quota, OutOfMemory }!void {
    lock();
    defer unlock();
    ensureLoaded();
    var kc: bool = undefined;
    var vc: bool = undefined;
    const key = try utf8Lossy(key_in, &kc);
    defer if (kc) gpa().free(key);
    const value = try utf8Lossy(value_in, &vc);
    defer if (vc) gpa().free(value);
    if (map.get(key)) |old| if (std.mem.eql(u8, old, value)) return;
    try putLocked(key, value);
    dirty = true;
}

pub fn remove(key_in: []const u8) void {
    lock();
    defer unlock();
    ensureLoaded();
    var kc: bool = undefined;
    const key = utf8Lossy(key_in, &kc) catch return;
    defer if (kc) gpa().free(key);
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

test "localStorage: a lone surrogate (WTF-8) in a key or value saves and reads back" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];

    defer resetForTest();
    resetForTest();
    loaded = true;
    dir_path = try std.fs.path.join(gpa(), &.{ root, "data" });

    // U+D800 alone, as QuickJS encodes it.
    try set("k\xed\xa0\x80", "v\xed\xa0\x80");
    {
        const v = get(t.allocator, "k\xed\xa0\x80").?;
        defer t.allocator.free(v);
        try t.expectEqualStrings("v\u{FFFD}", v);
    }
    flush();
    try t.expect(!dirty);

    clearLocked();
    const path = try std.fs.path.join(gpa(), &.{ dir_path.?, file_name });
    defer gpa().free(path);
    loadFile(path);
    try t.expectEqual(@as(usize, 1), count());
    const v = get(t.allocator, "k\u{FFFD}").?;
    defer t.allocator.free(v);
    try t.expectEqualStrings("v\u{FFFD}", v);
    // Read back, so not moved aside.
    try t.expect(dir_path != null);
    const saved = try tmp.dir.readFileAlloc(t.io, "data/" ++ file_name, t.allocator, .limited(4096));
    t.allocator.free(saved);
}

test "localStorage: a corrupt file is moved aside, not overwritten" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];

    defer resetForTest();
    resetForTest();
    loaded = true;
    dir_path = try std.fs.path.join(gpa(), &.{ root, "data" });
    try tmp.dir.createDirPath(t.io, "data");
    const bad = "{\"theme\":\"da";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/" ++ file_name, .data = bad });

    const path = try std.fs.path.join(gpa(), &.{ dir_path.?, file_name });
    defer gpa().free(path);
    loadFile(path);
    try t.expectEqual(@as(usize, 0), count());

    // The bad file is kept beside, whole.
    var dir = try tmp.dir.openDir(t.io, "data", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var found = false;
    while (try it.next(t.io)) |e| {
        if (!std.mem.startsWith(u8, e.name, file_name ++ ".corrupt-")) continue;
        const kept = try dir.readFileAlloc(t.io, e.name, t.allocator, .limited(4096));
        defer t.allocator.free(kept);
        try t.expectEqualStrings(bad, kept);
        found = true;
    }
    try t.expect(found);

    // And saving writes a fresh file.
    try set("theme", "light");
    flush();
    const saved = try tmp.dir.readFileAlloc(t.io, "data/" ++ file_name, t.allocator, .limited(4096));
    defer t.allocator.free(saved);
    try t.expectEqualStrings("{\"theme\":\"light\"}", saved);
}
