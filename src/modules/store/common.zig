//! Common logic for application data directories and path resolution.
//!
//! Platform-neutral validation, pure path joining, and generic JSON store.

const std = @import("std");

pub const AppIdError = error{
    EmptyAppId,
    InvalidAppId,
};

/// Validates that an `app_id` cannot contain path separators, traversal (`..`),
/// colons (Windows ADS / drive separators), NUL bytes, or control characters.
pub fn validateAppId(app_id: []const u8) AppIdError!void {
    if (app_id.len == 0) return error.EmptyAppId;
    if (std.mem.indexOfScalar(u8, app_id, 0) != null) return error.InvalidAppId;
    if (std.mem.indexOfScalar(u8, app_id, '/') != null) return error.InvalidAppId;
    if (std.mem.indexOfScalar(u8, app_id, '\\') != null) return error.InvalidAppId;
    if (std.mem.indexOfScalar(u8, app_id, ':') != null) return error.InvalidAppId;
    if (std.mem.indexOf(u8, app_id, "..") != null) return error.InvalidAppId;

    for (app_id) |c| {
        if (c < 0x20 or c == 0x7F) return error.InvalidAppId;
    }
}

/// Joins base directory, validated app_id, and an optional subdirectory.
pub fn buildAppPath(gpa: std.mem.Allocator, base: []const u8, app_id: []const u8, subdir: ?[]const u8) ![]const u8 {
    try validateAppId(app_id);
    if (subdir) |sub| {
        return try std.fs.path.join(gpa, &.{ base, app_id, sub });
    } else {
        return try std.fs.path.join(gpa, &.{ base, app_id });
    }
}

/// Generic thread-safe JSON settings store parameterized over a platform backend.
/// Backend must provide:
/// - `Mutex`: a type with `init(*Mutex)` (initializes in place: a GMutex must
///   not be copied once initialized), `deinit()`, `lock()`, and `unlock()`
/// - `readFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8`
/// - `writeFileAtomic(path: [:0]const u8, bytes: []const u8) !void`
/// - `configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8`
pub fn GenericStore(comptime Backend: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        file_path: [:0]const u8,
        arena: std.heap.ArenaAllocator,
        map: std.json.ObjectMap,
        mutex: Backend.Mutex,
        auto_save: bool,

        /// Open or create a JSON settings store inside `<config_dir>/<name>.json`.
        pub fn open(gpa: std.mem.Allocator, app_id: []const u8, name: []const u8) !*Self {
            const dir = try Backend.configDir(gpa, app_id);
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
        pub fn openPath(gpa: std.mem.Allocator, path: []const u8) !*Self {
            const path_z = try gpa.dupeZ(u8, path);
            errdefer gpa.free(path_z);

            const self = try gpa.create(Self);
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
            errdefer self.mutex.deinit();

            if (try Backend.readFile(gpa, path_z)) |content| {
                defer gpa.free(content);
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
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            if (self.auto_save) {
                self.saveInternal() catch {};
            }
            self.mutex.unlock();
            self.mutex.deinit();

            self.map.deinit(self.gpa);
            self.arena.deinit();
            self.gpa.free(self.file_path);
            self.gpa.destroy(self);
        }

        /// Retrieve raw `std.json.Value` for a key.
        pub fn get(self: *Self, key: []const u8) ?std.json.Value {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.get(key);
        }

        /// Retrieve a string value. Returns null if key is missing or not a string.
        pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }

        /// Retrieve an integer value. Returns null if key is missing or not an integer.
        pub fn getInt(self: *Self, key: []const u8, comptime T: type) ?T {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .integer => |i| std.math.cast(T, i),
                else => null,
            };
        }

        /// Retrieve a float value.
        pub fn getFloat(self: *Self, key: []const u8, comptime T: type) ?T {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        }

        /// Retrieve a boolean value.
        pub fn getBool(self: *Self, key: []const u8) ?bool {
            const val = self.get(key) orelse return null;
            return switch (val) {
                .bool => |b| b,
                else => null,
            };
        }

        /// Check if key exists.
        pub fn has(self: *Self, key: []const u8) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.map.contains(key);
        }

        /// Set a key-value pair and optionally auto-save.
        pub fn set(self: *Self, key: []const u8, value: anytype) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const arena_alloc = self.arena.allocator();
            const json_val: std.json.Value = blk: {
                if (@TypeOf(value) == std.json.Value) {
                    break :blk value;
                } else {
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
        pub fn delete(self: *Self, key: []const u8) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const removed = self.map.swapRemove(key);
            if (removed and self.auto_save) {
                self.saveInternal() catch {};
            }
            return removed;
        }

        /// Clear all keys.
        pub fn clear(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.map.clearRetainingCapacity();
            if (self.auto_save) {
                try self.saveInternal();
            }
        }

        /// Explicitly save the store to disk atomically.
        pub fn save(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.saveInternal();
        }

        fn saveInternal(self: *Self) !void {
            const root_val = std.json.Value{ .object = self.map };
            const json_text = try std.json.Stringify.valueAlloc(self.gpa, root_val, .{ .whitespace = .indent_2 });
            defer self.gpa.free(json_text);

            try Backend.writeFileAtomic(self.file_path, json_text);
        }
    };
}

test "validateAppId: valid identifiers" {
    try validateAppId("com.example.App");
    try validateAppId("dev.oriel.demo");
    try validateAppId("my-app_1.0");
    try validateAppId("singleword");
}

test "validateAppId: invalid identifiers" {
    // Empty
    try std.testing.expectError(error.EmptyAppId, validateAppId(""));

    // Path separators
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo/bar"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo\\bar"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("/root"));

    // Traversal
    try std.testing.expectError(error.InvalidAppId, validateAppId(".."));
    try std.testing.expectError(error.InvalidAppId, validateAppId("../foo"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo..bar"));

    // Drive letters / ADS colons
    try std.testing.expectError(error.InvalidAppId, validateAppId("C:app"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("app:stream"));

    // Control characters and NUL
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo\x00bar"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo\nbar"));
    try std.testing.expectError(error.InvalidAppId, validateAppId("foo\tbar"));
}

test "buildAppPath: joining base, app_id, and optional subdir" {
    const gpa = std.testing.allocator;

    const p1 = try buildAppPath(gpa, "/base/dir", "com.example.App", null);
    defer gpa.free(p1);
    try std.testing.expect(std.mem.endsWith(u8, p1, "com.example.App"));

    const p2 = try buildAppPath(gpa, "/base/dir", "com.example.App", "cache");
    defer gpa.free(p2);
    try std.testing.expect(std.mem.endsWith(u8, p2, "cache"));

    // Rejects invalid app_id during build
    try std.testing.expectError(error.InvalidAppId, buildAppPath(gpa, "/base/dir", "../evil", null));
}

const MockBackend = struct {
    var stored_data: ?[]const u8 = null;
    var last_path: ?[]const u8 = null;

    pub const Mutex = struct {
        pub fn init(_: *Mutex) void {}
        pub fn deinit(_: *Mutex) void {}
        pub fn lock(_: *Mutex) void {}
        pub fn unlock(_: *Mutex) void {}
    };

    pub fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
        _ = path;
        if (stored_data) |data| {
            return try gpa.dupe(u8, data);
        }
        return null;
    }

    pub fn writeFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
        const gpa = std.testing.allocator;
        if (stored_data) |old| gpa.free(old);
        stored_data = try gpa.dupe(u8, bytes);
        if (last_path) |p| gpa.free(p);
        last_path = try gpa.dupe(u8, path);
    }

    pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(gpa, "/test/config/{s}", .{app_id});
    }

    pub fn reset() void {
        const gpa = std.testing.allocator;
        if (stored_data) |d| {
            gpa.free(d);
            stored_data = null;
        }
        if (last_path) |p| {
            gpa.free(p);
            last_path = null;
        }
    }
};

test "GenericStore: basic operations, auto-save, and reopening" {
    const gpa = std.testing.allocator;
    defer MockBackend.reset();
    MockBackend.reset();

    const TestStore = GenericStore(MockBackend);

    var store = try TestStore.openPath(gpa, "/test/store.json");
    try store.set("name", "test-app");
    try store.set("version", 42);
    try store.set("ratio", 2.5);
    try store.set("enabled", true);

    try std.testing.expectEqualStrings("test-app", store.getString("name").?);
    try std.testing.expectEqual(@as(i64, 42), store.getInt("version", i64).?);
    try std.testing.expectEqual(@as(f64, 2.5), store.getFloat("ratio", f64).?);
    try std.testing.expectEqual(true, store.getBool("enabled").?);
    try std.testing.expect(store.has("name"));
    try std.testing.expect(!store.has("nonexistent"));

    store.deinit();

    // Verify MockBackend saved the data
    try std.testing.expect(MockBackend.stored_data != null);

    // Reopen and check values
    var reopened = try TestStore.openPath(gpa, "/test/store.json");
    defer reopened.deinit();

    try std.testing.expectEqualStrings("test-app", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 42), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("enabled").?);

    _ = reopened.delete("name");
    try std.testing.expect(!reopened.has("name"));

    try reopened.clear();
    try std.testing.expect(!reopened.has("version"));
}
