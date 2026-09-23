//! App data paths and persistent settings store (XDG-compliant).
//!
//! Provides standard XDG directory helpers (`configDir`, `dataDir`, `cacheDir`)
//! and a lightweight thread-safe JSON settings store (`Store`, Tauri `plugin-store` equivalent).
//!
//! Example:
//!     const store = try oriel.store.Store.open(gpa, "com.example.App", "settings");
//!     defer store.deinit();
//!
//!     try store.set("theme", "dark");
//!     try store.set("window_width", 1024);
//!     const theme = store.getString("theme"); // "dark"
//!     const width = store.getInt("window_width", i32); // 1024

const std = @import("std");
const glib = @import("glib");

/// Return the application config directory (creates it if missing).
///
/// Follows `$XDG_CONFIG_HOME/<app_id>`, defaulting to `~/.config/<app_id>`.
pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserConfigDir());
    const path = try std.fs.path.join(gpa, &.{ base, app_id });
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

/// Return the application data directory (creates it if missing).
///
/// Follows `$XDG_DATA_HOME/<app_id>`, defaulting to `~/.local/share/<app_id>`.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserDataDir());
    const path = try std.fs.path.join(gpa, &.{ base, app_id });
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

/// Return the application cache directory (creates it if missing).
///
/// Follows `$XDG_CACHE_HOME/<app_id>`, defaulting to `~/.cache/<app_id>`.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserCacheDir());
    const path = try std.fs.path.join(gpa, &.{ base, app_id });
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    file_path: [:0]const u8,
    arena: std.heap.ArenaAllocator,
    map: std.json.ObjectMap,
    mutex: glib.Mutex,
    auto_save: bool,

    /// Open or create a JSON settings store inside `$XDG_CONFIG_HOME/<app_id>/<name>.json`.
    pub fn open(gpa: std.mem.Allocator, app_id: []const u8, name: []const u8) !*Store {
        const dir = try configDir(gpa, app_id);
        defer gpa.free(dir);

        const filename = if (std.mem.endsWith(u8, name, ".json"))
            try gpa.dupe(u8, name)
        else
            try std.fmt.allocPrint(gpa, "{s}.json", .{name});
        defer gpa.free(filename);

        const full_path = try std.fs.path.join(gpa, &.{ dir, filename });
        defer gpa.free(full_path);

        return openPath(gpa, full_path);
    }

    /// Open or create a JSON settings store at an arbitrary file path.
    pub fn openPath(gpa: std.mem.Allocator, path: []const u8) !*Store {
        const path_z = try gpa.dupeZ(u8, path);
        errdefer gpa.free(path_z);

        const self = try gpa.create(Store);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .file_path = path_z,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .map = .empty,
            .mutex = undefined,
            .auto_save = true,
        };
        self.mutex.init();
        errdefer self.mutex.clear();

        // Read and parse file if it exists.
        var file_bytes: [*]u8 = undefined;
        var file_len: usize = 0;
        var err: ?*glib.Error = null;

        if (glib.fileGetContents(path_z, &file_bytes, &file_len, &err) != 0) {
            defer glib.free(file_bytes);
            const content = file_bytes[0..file_len];
            if (std.mem.trim(u8, content, " \t\r\n").len > 0) {
                var parsed = std.json.parseFromSlice(std.json.Value, self.arena.allocator(), content, .{}) catch |parse_err| {
                    std.log.warn("failed to parse store file {s}: {s}", .{ path, @errorName(parse_err) });
                    return self;
                };
                if (parsed.value == .object) {
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        const key_copy = try self.arena.allocator().dupe(u8, entry.key_ptr.*);
                        try self.map.put(self.gpa, key_copy, entry.value_ptr.*);
                    }
                }
            }
        } else if (err) |e| {
            e.free();
        }

        return self;
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        if (self.auto_save) {
            self.saveInternal() catch {};
        }
        self.mutex.unlock();
        self.mutex.clear();

        self.map.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.free(self.file_path);
        self.gpa.destroy(self);
    }

    /// Retrieve raw `std.json.Value` for a key.
    pub fn get(self: *Store, key: []const u8) ?std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(key);
    }

    /// Retrieve a string value. Returns null if key is missing or not a string.
    pub fn getString(self: *Store, key: []const u8) ?[]const u8 {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }

    /// Retrieve an integer value. Returns null if key is missing or not an integer.
    pub fn getInt(self: *Store, key: []const u8, comptime T: type) ?T {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .integer => |i| std.math.cast(T, i),
            else => null,
        };
    }

    /// Retrieve a float value.
    pub fn getFloat(self: *Store, key: []const u8, comptime T: type) ?T {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    /// Retrieve a boolean value.
    pub fn getBool(self: *Store, key: []const u8) ?bool {
        const val = self.get(key) orelse return null;
        return switch (val) {
            .bool => |b| b,
            else => null,
        };
    }

    /// Check if key exists.
    pub fn has(self: *Store, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.contains(key);
    }

    /// Set a key-value pair and optionally auto-save.
    pub fn set(self: *Store, key: []const u8, value: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const arena_alloc = self.arena.allocator();
        const json_val: std.json.Value = blk: {
            if (@TypeOf(value) == std.json.Value) {
                break :blk value;
            } else {
                // Stringify and parse into arena
                var buf: [1024]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                const str = std.json.Stringify.valueAlloc(fba.allocator(), value, .{}) catch {
                    const dynamic_str = try std.json.Stringify.valueAlloc(self.gpa, value, .{});
                    defer self.gpa.free(dynamic_str);
                    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, dynamic_str, .{});
                    break :blk parsed.value;
                };
                const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, str, .{});
                break :blk parsed.value;
            }
        };

        const key_copy = try arena_alloc.dupe(u8, key);
        try self.map.put(self.gpa, key_copy, json_val);

        if (self.auto_save) {
            try self.saveInternal();
        }
    }

    /// Delete a key. Returns true if key was present.
    pub fn delete(self: *Store, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const removed = self.map.swapRemove(key);
        if (removed and self.auto_save) {
            self.saveInternal() catch {};
        }
        return removed;
    }

    /// Clear all keys.
    pub fn clear(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.map.clearRetainingCapacity();
        if (self.auto_save) {
            try self.saveInternal();
        }
    }

    /// Explicitly save the store to disk atomically.
    pub fn save(self: *Store) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.saveInternal();
    }

    fn saveInternal(self: *Store) !void {
        const root_val = std.json.Value{ .object = self.map };
        const json_text = try std.json.Stringify.valueAlloc(self.gpa, root_val, .{ .whitespace = .indent_2 });
        defer self.gpa.free(json_text);

        var err: ?*glib.Error = null;
        if (glib.fileSetContents(self.file_path, json_text.ptr, @intCast(json_text.len), &err) == 0) {
            if (err) |e| {
                std.log.err("failed to save store to {s}: {s}", .{ self.file_path, e.f_message orelse "unknown error" });
                e.free();
            }
            return error.SaveFailed;
        }
    }
};

pub fn check(gpa: std.mem.Allocator, _: anytype) !@import("../oriel.zig").Check {
    const test_path = "/tmp/oriel_check_store.json";
    _ = glib.unlink(test_path);
    defer _ = glib.unlink(test_path);

    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();

    try s.set("test_key", "check_value");
    const val = s.getString("test_key") orelse return .{
        .module = "store",
        .ok = false,
        .detail = "failed to read back stored key",
    };
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
        .detail = "XDG dirs + JSON store roundtrip ok",
    };
}

test "Store operations and persistence" {
    const gpa = std.testing.allocator;
    const test_path = "/tmp/oriel_test_store.json";

    // Clean up before test
    _ = glib.unlink(test_path);

    var store = try Store.openPath(gpa, test_path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    try store.set("pi", 3.14);

    try std.testing.expectEqualStrings("oriel", store.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), store.getInt("version", i64).?);
    try std.testing.expectEqual(true, store.getBool("active").?);
    try std.testing.expect(store.has("pi"));

    store.deinit();

    // Reopen and verify persisted values
    var reopened = try Store.openPath(gpa, test_path);
    defer {
        reopened.deinit();
        _ = glib.unlink(test_path);
    }

    try std.testing.expectEqualStrings("oriel", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    _ = reopened.delete("name");
    try std.testing.expect(!reopened.has("name"));
}
