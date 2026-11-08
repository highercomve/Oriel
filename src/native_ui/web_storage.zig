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
const internal = @import("../core/internal.zig");

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

/// Tests only: the allocator the store hydrates, saves and keeps through
/// (null: the process's) — smp_allocator can't be wrapped for fault tests.
var test_gpa: ?std.mem.Allocator = null;

/// Tests only: stands for the app's real data directory (null: the OS's,
/// which wants an app id and the process's environment) when a test drives
/// the store's first use through ensureLoaded.
var test_data_dir: ?[]const u8 = null;

fn gpa() std.mem.Allocator {
    return test_gpa orelse std.heap.smp_allocator;
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

/// The directory the store is saved in: the OS's for this app id (see the
/// top), or — tests only — `test_data_dir` standing for it. null: nowhere
/// (the store lasts the run).
fn dataDir(a: std.mem.Allocator, app_id: []const u8) error{OutOfMemory}!?[]u8 {
    if (test_data_dir) |d| return try a.dupe(u8, d);
    return osDataDir(a, app_id);
}

/// The OS's own data directory for this OS (see the top), or null.
fn osDataDir(a: std.mem.Allocator, app_id: []const u8) error{OutOfMemory}!?[]u8 {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const v = std.c.getenv(name) orelse return null;
            const s = std.mem.span(v);
            return if (s.len > 0) s else null;
        }
    }.get;
    return switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => if (builtin.abi.isAndroid()) null else if (env("XDG_CONFIG_HOME")) |x|
            try std.fs.path.join(a, &.{ x, app_id, "data" })
        else if (env("HOME")) |h|
            try std.fs.path.join(a, &.{ h, ".config", app_id, "data" })
        else
            null,
        .macos => if (env("HOME")) |h| try std.fs.path.join(a, &.{ h, "Library", "Application Support", app_id, "data" }) else null,
        .windows => if (env("APPDATA")) |d| try std.fs.path.join(a, &.{ d, app_id, "data" }) else null,
        else => null,
    };
}

/// The saved store, read once (the first page to touch localStorage), the
/// whole first use one transaction (AGENTS.md pattern 2): where saving
/// lands is settled with what the load did. `dir_path` is published only
/// once the load committed — or the file is genuinely missing, or its
/// unreadable content was moved aside — so a later set() + flush() can
/// never write over the only copy of the data with what the store lost;
/// any other failure frees `dir` again and leaves saving switched off for
/// the run (logged once, in notLoaded, from where the failure was).
fn ensureLoaded() void {
    if (loaded) return;
    loaded = true;
    const id = internal.current_app_id orelse return;
    const dir = (dataDir(gpa(), id) catch |err| {
        std.log.scoped(.native_ui).warn("localStorage: no data directory ({s}), not saving this run", .{@errorName(err)});
        return;
    }) orelse return;
    const path = std.fs.path.join(gpa(), &.{ dir, file_name }) catch |err| {
        notLoaded(dir, @errorName(err));
        gpa().free(dir);
        return;
    };
    defer gpa().free(path);
    loadFile(path) catch {
        // Where it failed, and what that did to saving, was logged there;
        // the run gets on with what the store has (`dir` was never
        // published: not saved to either).
        gpa().free(dir);
        return;
    };
    // The load committed (or there was no file yet): the run's sets are
    // saved to `dir` from here on.
    dir_path = dir;
}

/// The entries of a saved store (a JSON object of strings), taken whole
/// (AGENTS.md pattern 2): the store commits only once every entry could be
/// copied, so a later set() + flush() can't replace the only copy of the
/// data with half of it. The map is empty when a load ran (it's the store's
/// very first use).
///
/// A file that doesn't read back because of its *content* (not JSON, not an
/// object) is moved aside, to localStorage.json.corrupt-<unix nanoseconds>, and
/// the store starts empty: the next save writes a fresh file instead of
/// replacing the only copy of the data. Where it couldn't be moved aside,
/// the load fails (error.StoreNotLoaded) instead: the unreadable file is
/// kept where it is, and saving is switched off for this run, like a
/// resource failure.
///
/// A *resource* failure (a failed read, out of memory) is different: the
/// file is kept whole, and saving is switched off for this run (see
/// notLoaded).
fn loadFile(path: []const u8) error{ OutOfMemory, StoreNotLoaded }!void {
    // Saved as JSON, a byte can take up to six (\u0001), keys and values
    // alike: room for a full store of the worst case, and the punctuation.
    const text = std.Io.Dir.cwd().readFileAlloc(io(), path, gpa(), .limited(quota * 6 + 64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return;
        // A failed read isn't corrupt content: the file is kept, and so is
        // its protection (notLoaded). OutOfMemory is told apart for the
        // caller (fault tests surface it as exactly that).
        notLoaded(path, @errorName(err));
        return if (err == error.OutOfMemory) error.OutOfMemory else error.StoreNotLoaded;
    };
    defer gpa().free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa(), text, .{}) catch |err| {
        if (err == error.OutOfMemory) {
            notLoaded(path, "out of memory");
            return error.OutOfMemory;
        }
        return moveAside(path, "not valid JSON");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return moveAside(path, "not a JSON object");
    // The entries hydrate into a side map, then commit at once: a partial
    // hydration owns nothing yet.
    var hydrated: std.StringArrayHashMapUnmanaged([]u8) = .empty;
    var hydrated_used: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |e| {
        const v = switch (e.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        putInto(&hydrated, &hydrated_used, e.key_ptr.*, v) catch |err| {
            dropMap(&hydrated);
            // Past the quota isn't corrupt content either (what our own
            // saves write stays under it): kept, and not saved over.
            notLoaded(path, switch (err) {
                error.OutOfMemory => "out of memory",
                error.Quota => "past the quota",
            });
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.Quota => error.StoreNotLoaded,
            };
        };
    }
    // Committed: nothing from here on can fail.
    clearLocked(); // empty in practice: the load runs first
    map = hydrated;
    used = hydrated_used;
}

/// A load that didn't finish for a reason that isn't the file's content
/// (a failed read or hydration; AGENTS.md pattern 2): the file is kept,
/// and saving is switched off for this run, so a later set() + flush()
/// can't write over it with what the store lost. The callers return their
/// own error.
fn notLoaded(path: []const u8, why: []const u8) void {
    forgetDir();
    const log = std.log.scoped(.native_ui);
    log.warn("localStorage: {s} not loaded ({s}), not saving this run", .{ path, why });
}

/// Rename an unreadable store file out of the way (see loadFile); where it
/// couldn't be (the log tells), the file is kept whole where it is, saving
/// is switched off for this run (notLoaded), and that is what comes back
/// to the caller as the error.
fn moveAside(path: []const u8, why: []const u8) error{StoreNotLoaded}!void {
    const log = std.log.scoped(.native_ui);
    // Nanoseconds: two copies moved aside in the same second keep both.
    const ns = std.Io.Timestamp.now(io(), .real).nanoseconds;
    var buf: [48]u8 = undefined;
    const suffix = std.fmt.bufPrint(&buf, ".corrupt-{d}", .{ns}) catch unreachable;
    const aside = std.mem.concat(gpa(), u8, &.{ path, suffix }) catch {
        forgetDir(); // can't keep the file: don't overwrite it either
        log.warn("localStorage: {s} unreadable ({s}), not saving this run", .{ path, why });
        return error.StoreNotLoaded;
    };
    defer gpa().free(aside);
    const cwd = std.Io.Dir.cwd();
    cwd.rename(path, cwd, aside, io()) catch |err| {
        forgetDir();
        log.warn("localStorage: {s} unreadable ({s}) and not moved aside ({s}), not saving this run", .{ path, why, @errorName(err) });
        return error.StoreNotLoaded;
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

/// One entry into `m`, its byte total kept in `used_total` past the
/// store's quota: the value and, for a new key, the key are copies owned
/// by `m`.
fn putInto(m: *std.StringArrayHashMapUnmanaged([]u8), used_total: *usize, key: []const u8, value: []const u8) error{ Quota, OutOfMemory }!void {
    const old = m.get(key);
    const after = used_total.* - (if (old) |o| key.len + o.len else 0) + key.len + value.len;
    if (after > quota) return error.Quota;
    const v = try gpa().dupe(u8, value);
    errdefer gpa().free(v);
    const gop = try m.getOrPut(gpa(), key);
    if (gop.found_existing) {
        gpa().free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = gpa().dupe(u8, key) catch |err| {
            m.swapRemoveAt(gop.index);
            return err;
        };
    }
    gop.value_ptr.* = v;
    used_total.* = after;
}

/// One entry into the store (see putInto for what it owns, and put's
/// guard).
fn putLocked(key: []const u8, value: []const u8) error{ Quota, OutOfMemory }!void {
    try putInto(&map, &used, key, value);
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

/// Every entry of `m` and `m` itself, gone (a hydration that didn't commit
/// owns nothing any more; see loadFile).
fn dropMap(m: *std.StringArrayHashMapUnmanaged([]u8)) void {
    var it = m.iterator();
    while (it.next()) |e| {
        gpa().free(e.key_ptr.*);
        gpa().free(e.value_ptr.*);
    }
    m.deinit(gpa());
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

/// Written whole, and made whole with the file's sync before the rename
/// (a partial file never takes the place of the only copy of the data).
/// The rules followed are src/modules/store/posix.zig's: a temp created
/// exclusively under an unpredictable name, data synced first, a rename
/// that can't leave a temp behind when the save fails halfway.
fn save(dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io(), dir);
    const path = try std.fs.path.join(gpa(), &.{ dir, file_name });
    defer gpa().free(path);

    // A sibling temp: created exclusively (no searching a shared ".tmp"
    // name), written, sync'ed, then renamed over the saved store; the
    // deinit takes the temp with it when a step failed (AGENTS.md
    // pattern 4).
    var atomic = try cwd.createFileAtomic(io(), path, .{ .replace = true });
    defer atomic.deinit(io());
    var buffer: [4096]u8 = undefined;
    var file_writer = atomic.file.writer(io(), &buffer);
    var js: std.json.Stringify = .{ .writer = &file_writer.interface };
    try js.beginObject();
    var it = map.iterator();
    while (it.next()) |e| {
        try js.objectField(e.key_ptr.*);
        try js.write(e.value_ptr.*);
    }
    try js.endObject();
    try file_writer.flush();
    // The bytes are on disk before the rename takes the old store away.
    try atomic.file.sync(io());
    try atomic.replace(io());

    // And the rename itself durable, best effort like posix.zig's (the
    // data itself is already synced).
    // Windows can't sync a directory; NTFS journals the rename.
    if (builtin.os.tag == .windows) return;
    if (std.fs.path.dirname(path)) |parent| {
        // `.iterate` opens it readable: the default O_PATH handle can't be
        // fsync'ed (EBADF).
        const saved_dir = cwd.openDir(io(), parent, .{ .iterate = true }) catch return;
        defer saved_dir.close(io());
        const dir_file: std.Io.File = .{ .handle = saved_dir.handle, .flags = .{ .nonblocking = false } };
        dir_file.sync(io()) catch {};
    }
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
        try loadFile(path);
    }
    const again = get(t.allocator, "theme").?;
    defer t.allocator.free(again);
    try t.expectEqualStrings("dark", again);

    // And saving left no temp behind (the write is atomic; a fixed
    // "<path>.tmp" would sit beside it between saves, or after a failed
    // one).
    var dir = try tmp.dir.openDir(t.io, "dev.oriel.Test/data", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(t.io)) |e| {
        try t.expectEqualStrings(file_name, e.name);
        files += 1;
    }
    try t.expectEqual(@as(usize, 1), files);
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
    try loadFile(path);
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
    try loadFile(path);
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

test "localStorage: two corrupt files moved aside back to back keep both" {
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
    const path = try std.fs.path.join(gpa(), &.{ dir_path.?, file_name });
    defer gpa().free(path);

    // Well within one second: a seconds-only name would make the second
    // rename replace the first copy.
    for ([_][]const u8{ "{\"a\":", "[1," }) |bad| {
        try tmp.dir.writeFile(t.io, .{ .sub_path = "data/" ++ file_name, .data = bad });
        try loadFile(path);
    }

    var dir = try tmp.dir.openDir(t.io, "data", .{ .iterate = true });
    defer dir.close(t.io);
    var it = dir.iterate();
    var copies: usize = 0;
    while (try it.next(t.io)) |e| {
        if (std.mem.startsWith(u8, e.name, file_name ++ ".corrupt-")) copies += 1;
    }
    try t.expectEqual(@as(usize, 2), copies);
}

// One hydration (loadFile) under a fault-injected allocator: a load that
// didn't reach its end must commit nothing, dirty nothing and save
// nowhere, so a later set() + flush() can't replace the only copy of the
// data (see loadFile). The checker runs it once without a failure, then
// once more at every allocation it makes (AGENTS.md pattern 3).
const hydration_run = struct {
    fn run(a: std.mem.Allocator, path: []const u8, saved: []const u8) anyerror!void {
        const t = std.testing;
        test_gpa = a;
        defer {
            // Nothing a run left in the store survives it: each run
            // starts from an empty one.
            clearLocked();
            map.deinit(gpa());
            map = .empty;
            used = 0;
            dirty = false;
            loaded = false;
            if (dir_path) |d| gpa().free(d);
            dir_path = null;
            test_gpa = null;
        }
        loadFile(path) catch {
            // Nothing was committed: what's on disk is the file whole,
            // and nothing can be saved over it.
            try t.expectEqual(@as(usize, 0), map.count());
            try t.expect(!dirty);
            try t.expect(dir_path == null);
            const on_disk = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(4096));
            defer std.testing.allocator.free(on_disk);
            try t.expectEqualStrings(saved, on_disk);
            // The run's allocation surfaced as out-of-memory exactly (the
            // checker balances the bytes of a run that returned this).
            return error.OutOfMemory;
        };
        // A committing load: both entries are in, still nothing dirty.
        try t.expectEqual(@as(usize, 2), map.count());
        try t.expect(!dirty);
    }
};

test "localStorage: a load that fails partway keeps the file and saves nothing over it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "data");
    const saved = "{\"theme\":\"dark\",\"n\":\"1\"}";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "data/" ++ file_name, .data = saved });
    const path = try std.fs.path.join(t.allocator, &.{ root, "data", file_name });
    defer t.allocator.free(path);
    const data_dir = try std.fs.path.join(t.allocator, &.{ root, "data" });
    defer t.allocator.free(data_dir);

    defer resetForTest();
    resetForTest();

    // Every allocation of a hydration, failed one by one.
    try t.checkAllAllocationFailures(std.testing.allocator, hydration_run.run, .{ path, saved });

    // How many the hydration makes (the checker works the same way), so
    // one run can fail at the last of them.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var needed: usize = 0;
    {
        test_gpa = probe.allocator();
        defer {
            resetForTest();
            test_gpa = null;
        }
        try loadFile(path);
        needed = probe.alloc_index;
    }
    try t.expect(needed > 1);

    // One run spelled out: the load failed partway (the run started with
    // somewhere to save), then the page writes and flushes — the file it
    // lands on is the old one.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = needed - 1 });
        test_gpa = failing.allocator();
        defer {
            resetForTest();
            test_gpa = null;
        }
        dir_path = try gpa().dupe(u8, data_dir);
        try t.expectError(error.OutOfMemory, loadFile(path));
        try t.expectEqual(@as(usize, 0), map.count());
        try t.expect(!dirty);
        // The failed run doesn't save anywhere, any more.
        try t.expect(dir_path == null);
        test_gpa = null;
        try set("later", "1");
        flush();
        const after = try tmp.dir.readFileAlloc(t.io, "data/" ++ file_name, t.allocator, .limited(4096));
        defer t.allocator.free(after);
        try t.expectEqualStrings(saved, after);
    }
}

// The store's first use — ensureLoaded, run through set() with an app id
// and a directory standing in for the real ones — at a fault-injected
// allocator: a first use that didn't finish leaves the store either
// savable-nowhere (nothing hydrated, dir_path null) or savable-whole (the
// load committed), never the half of it that published somewhere with
// nothing hydrated — the medley a later set() + flush() would write over
// the only copy of the data with (AGENTS.md pattern 2, see ensureLoaded).
// Whatever the run did, the file's bytes survive it: no flush happened in
// the run (a failed first use doesn't dirty anything, and a succeeding
// one's set is discarded, not saved), so every run reads the same bytes
// back. Then a store state the checker doesn't see, spelled out below the
// loop: the run's failure, the store forgotten, and a fresh first use —
// a healthy allocator — writing and flushing while the file has it all.
const first_use_run = struct {
    fn run(a: std.mem.Allocator, data_dir: []const u8, path: []const u8, saved: []const u8) anyerror!void {
        const t = std.testing;
        test_gpa = a;
        test_data_dir = data_dir;
        defer {
            resetForTest(); // what the run owns, freed with its allocator
            test_data_dir = null;
            test_gpa = null;
        }
        var failed = false;
        _ = set("page", "1") catch |err| switch (err) {
            error.OutOfMemory => failed = true,
            error.Quota => return err,
        };
        {
            // Whatever the run did with the store, the file's bytes are
            // the same: no flush happened (a failed first use doesn't
            // dirty anything, and a succeeding one's set isn't saved
            // here).
            const on_disk = try std.Io.Dir.cwd().readFileAlloc(io(), path, std.testing.allocator, .limited(1 << 16));
            defer std.testing.allocator.free(on_disk);
            try t.expectEqualStrings(saved, on_disk);
        }
        if (failed) {
            // Not dirty, and not published-with-nothing: either nowhere to
            // save (the load never committed) or the whole load committed
            // in front of the set itself failing.
            try t.expect(!dirty);
            if (dir_path == null) {
                try t.expectEqual(@as(usize, 0), map.count());
            } else {
                try t.expectEqual(@as(usize, 2), map.count());
            }
            // The failure surfaced as exactly that (the checker balances
            // the bytes of a run that returned it).
            return error.OutOfMemory;
        }
        // A first use that met no failure (the checker's probing run, and
        // a run whose injected index was never reached): in memory, whole
        // and ready to be saved — the page's set still dirty here, saved
        // by no one (the defer forgets it).
        try t.expect(dir_path != null);
        try t.expectEqual(@as(usize, 3), map.count());
    }
};

test "localStorage: a first use that fails partway publishes nowhere but whole" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(t.io, &buf)];
    try tmp.dir.createDirPath(t.io, "app/data");
    const saved = "{\"theme\":\"dark\",\"n\":\"1\"}";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "app/data/" ++ file_name, .data = saved });
    // What the file looks like once a first use ran, the store was
    // forgotten, and a fresh one (healthy this time) loaded, set the
    // page's key and flushed: all three, in the file's and then the set's
    // order.
    const expected = "{\"theme\":\"dark\",\"n\":\"1\",\"page\":\"1\"}";
    const path = try std.fs.path.join(t.allocator, &.{ root, "app", "data", file_name });
    defer t.allocator.free(path);
    const data_dir = try std.fs.path.join(t.allocator, &.{ root, "app", "data" });
    defer t.allocator.free(data_dir);

    defer {
        resetForTest();
        internal.current_app_id = null;
        test_data_dir = null;
    }
    resetForTest();
    internal.current_app_id = "dev.oriel.Test";

    // Every allocation of the first use, failed one by one.
    try t.checkAllAllocationFailures(std.testing.allocator, first_use_run.run, .{ data_dir, path, saved });

    // How many the first use makes (the checker works the same way), so
    // the spelled-out run below fails inside the load, not at its edges.
    var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var needed: usize = 0;
    {
        test_gpa = probe.allocator();
        test_data_dir = data_dir;
        defer {
            resetForTest();
            test_data_dir = null;
            test_gpa = null;
        }
        try set("page", "1");
        needed = probe.alloc_index;
    }
    try t.expect(needed > 2);

    // One run spelled out: the first use failed partway (here, deep in the
    // load: nothing hydrated, nowhere to save), the store was forgotten,
    // then a fresh first use — a healthy allocator — loads the file whole
    // again, sets the page's key and flushes. What lands on the file is
    // exactly the whole store; nothing of the file's own two entries was
    // lost to the failed first use.
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = needed / 2 });
        test_gpa = failing.allocator();
        test_data_dir = data_dir;
        _ = set("page", "1") catch |err| switch (err) {
            error.OutOfMemory => {},
            error.Quota => return err,
        };
        try t.expect(!dirty);
        if (dir_path == null) {
            try t.expectEqual(@as(usize, 0), map.count());
        } else {
            try t.expectEqual(@as(usize, 2), map.count());
        }
        resetForTest();
        test_data_dir = null;
        test_gpa = null;

        test_gpa = std.testing.allocator;
        test_data_dir = data_dir;
        try set("page", "1");
        flush();
        const on_disk = try tmp.dir.readFileAlloc(t.io, "app/data/" ++ file_name, t.allocator, .limited(1 << 16));
        defer t.allocator.free(on_disk);
        try t.expectEqualStrings(expected, on_disk);

        resetForTest();
        test_data_dir = null;
        test_gpa = null;
    }
}
