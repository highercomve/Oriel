//! The store's folder and the generic JSON store over a platform backend.

const std = @import("std");
const paths = @import("../../core/paths.zig");
const target = @import("../../core/target.zig");

/// The store's folder: `oriel.paths.appConfig`, and on Android an
/// `<app_id>` folder inside it (`<filesDir>/<app_id>`), where existing
/// apps' settings already are. Created if missing; caller frees.
pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = try paths.appConfig(gpa, .{ .name = app_id });
    if (comptime target.os != .android) return base;
    defer gpa.free(base);
    const dir = try std.fs.path.join(gpa, &.{ base, app_id });
    errdefer gpa.free(dir);
    try @import("../../core/paths/posix.zig").makePath(gpa, dir);
    return dir;
}

/// Generic thread-safe JSON settings store parameterized over a platform backend.
/// Backend must provide:
/// - `Mutex`: a type with `init(*Mutex)` (initializes in place: a GMutex must
///   not be copied once initialized), `deinit()`, `lock()`, and `unlock()`
/// - `readFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8`: caller frees;
///   null only for a missing file, all other read failures propagate.
/// - `writeFileAtomic(path: [:0]const u8, bytes: []const u8) !void`
/// - `configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8`
pub fn GenericStore(comptime Backend: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            arena: std.heap.ArenaAllocator,
            value: std.json.Value,
        };

        gpa: std.mem.Allocator,
        file_path: [:0]const u8,
        map: std.StringArrayHashMapUnmanaged(Entry),
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
                .map = .empty,
                .mutex = undefined,
                .auto_save = true,
            };
            self.mutex.init();
            errdefer self.mutex.deinit();
            errdefer self.map.deinit(gpa);
            errdefer self.freeEntries();

            if (try Backend.readFile(gpa, path_z)) |content| {
                defer gpa.free(content);
                if (std.mem.trim(u8, content, " \t\r\n").len > 0) {
                    var parsed = std.json.parseFromSlice(std.json.Value, gpa, content, .{ .allocate = .alloc_always }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            try self.quarantine(content);
                            return self;
                        },
                    };
                    defer parsed.deinit();
                    if (parsed.value != .object) {
                        try self.quarantine(content);
                        return self;
                    }
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        try self.putValue(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            if (self.auto_save) {
                self.saveInternal() catch |err| self.logSaveFailure(err);
            }
            self.mutex.unlock();
            self.mutex.deinit();

            self.freeEntries();
            self.map.deinit(self.gpa);
            self.gpa.free(self.file_path);
            self.gpa.destroy(self);
        }

        /// Return an owned copy of the value for `key`, or null if missing.
        /// Call `deinit()` on the returned `std.json.Parsed(std.json.Value)` to free it.
        pub fn get(self: *Self, gpa: std.mem.Allocator, key: []const u8) !?std.json.Parsed(std.json.Value) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.get(key) orelse return null;
            const arena = try gpa.create(std.heap.ArenaAllocator);
            errdefer gpa.destroy(arena);
            arena.* = .init(gpa);
            errdefer arena.deinit();
            return .{
                .arena = arena,
                .value = try cloneValue(arena.allocator(), entry.value),
            };
        }

        /// Return an owned copy of a string value (caller frees with `gpa.free`),
        /// or null if `key` is missing or not a string.
        pub fn getString(self: *Self, gpa: std.mem.Allocator, key: []const u8) !?[]u8 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.get(key) orelse return null;
            return switch (entry.value) {
                .string => |s| try gpa.dupe(u8, s),
                else => null,
            };
        }

        /// Retrieve an integer value. Returns null if key is missing or not an integer.
        pub fn getInt(self: *Self, key: []const u8, comptime T: type) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.get(key) orelse return null;
            return switch (entry.value) {
                .integer => |i| std.math.cast(T, i),
                else => null,
            };
        }

        /// Retrieve a float value.
        pub fn getFloat(self: *Self, key: []const u8, comptime T: type) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.get(key) orelse return null;
            return switch (entry.value) {
                .float => |f| @floatCast(f),
                .integer => |i| @floatFromInt(i),
                else => null,
            };
        }

        /// Retrieve a boolean value.
        pub fn getBool(self: *Self, key: []const u8) ?bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.map.get(key) orelse return null;
            return switch (entry.value) {
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

            try self.putValue(key, value);

            if (self.auto_save) {
                try self.saveInternal();
            }
        }

        /// Delete a key. Returns true if key was present.
        pub fn delete(self: *Self, key: []const u8) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            const removed = self.map.fetchSwapRemove(key) orelse return false;
            var arena = removed.value.arena;
            arena.deinit();
            if (self.auto_save) {
                self.saveInternal() catch |err| self.logSaveFailure(err);
            }
            return true;
        }

        /// Clear all keys.
        pub fn clear(self: *Self) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.freeEntries();
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

        fn quarantine(self: *Self, content: []const u8) !void {
            const backup = try std.fmt.allocPrintSentinel(self.gpa, "{s}.corrupt", .{self.file_path}, 0);
            defer self.gpa.free(backup);
            // Opening fails if preserving the original fails; it cannot be saved over.
            try Backend.writeFileAtomic(backup, content);
            if (!@import("builtin").is_test)
                std.log.warn("invalid store file {s}; kept a copy at {s}", .{ self.file_path, backup });
        }

        fn cloneValue(alloc: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error!std.json.Value {
            return switch (value) {
                .null => .null,
                .bool => |b| .{ .bool = b },
                .integer => |i| .{ .integer = i },
                .float => |f| .{ .float = f },
                .number_string => |s| .{ .number_string = try alloc.dupe(u8, s) },
                .string => |s| .{ .string = try alloc.dupe(u8, s) },
                .array => |arr| blk: {
                    var copy = try std.json.Array.initCapacity(alloc, arr.items.len);
                    for (arr.items) |item| {
                        copy.appendAssumeCapacity(try cloneValue(alloc, item));
                    }
                    break :blk .{ .array = copy };
                },
                .object => |obj| blk: {
                    var copy: std.json.ObjectMap = .empty;
                    try copy.ensureTotalCapacity(alloc, obj.count());
                    var it = obj.iterator();
                    while (it.next()) |entry| {
                        copy.putAssumeCapacityNoClobber(
                            try alloc.dupe(u8, entry.key_ptr.*),
                            try cloneValue(alloc, entry.value_ptr.*),
                        );
                    }
                    break :blk .{ .object = copy };
                },
            };
        }

        fn putValue(self: *Self, key: []const u8, value: anytype) !void {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();
            // Prepare independent ownership before replacing any borrowed input.
            const parsed = if (@TypeOf(value) == std.json.Value)
                try cloneValue(alloc, value)
            else blk: {
                const json_text = try std.json.Stringify.valueAlloc(self.gpa, value, .{});
                defer self.gpa.free(json_text);
                break :blk try std.json.parseFromSliceLeaky(std.json.Value, alloc, json_text, .{ .allocate = .alloc_always });
            };
            const owned_key = try alloc.dupe(u8, key);
            const gop = try self.map.getOrPut(self.gpa, key);
            if (gop.found_existing) gop.value_ptr.arena.deinit();
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = .{ .arena = arena, .value = parsed };
        }

        fn freeEntries(self: *Self) void {
            for (self.map.values()) |*entry| entry.arena.deinit();
        }

        fn logSaveFailure(self: *Self, err: anyerror) void {
            std.log.warn("failed to save store to {s}: {s}", .{ self.file_path, @errorName(err) });
        }

        fn saveInternal(self: *Self) !void {
            var out: std.Io.Writer.Allocating = .init(self.gpa);
            defer out.deinit();
            var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .indent_2 } };
            json.beginObject() catch return error.OutOfMemory;
            var it = self.map.iterator();
            while (it.next()) |entry| {
                json.objectField(entry.key_ptr.*) catch return error.OutOfMemory;
                json.write(entry.value_ptr.value) catch return error.OutOfMemory;
            }
            json.endObject() catch return error.OutOfMemory;
            try Backend.writeFileAtomic(self.file_path, out.written());
        }
    };
}

const MockBackend = struct {
    var stored_data: ?[]const u8 = null;
    var last_path: ?[]const u8 = null;
    var backup_data: ?[]const u8 = null;
    var fail_write = false;

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
        if (fail_write) return error.SaveFailed;
        const gpa = std.testing.allocator;
        const data = try gpa.dupe(u8, bytes);
        errdefer gpa.free(data);
        const new_path = try gpa.dupe(u8, path);
        const dest = if (std.mem.endsWith(u8, path, ".corrupt")) &backup_data else &stored_data;
        if (dest.*) |old| gpa.free(old);
        dest.* = data;
        if (last_path) |old| gpa.free(old);
        last_path = new_path;
    }

    pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(gpa, "/test/config/{s}", .{app_id});
    }

    pub fn reset() void {
        fail_write = false;
        if (backup_data) |data| std.testing.allocator.free(data);
        backup_data = null;
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

    const name = (try store.getString(gpa, "name")).?;
    defer gpa.free(name);
    try std.testing.expectEqualStrings("test-app", name);
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

    const reopened_name = (try reopened.getString(gpa, "name")).?;
    defer gpa.free(reopened_name);
    try std.testing.expectEqualStrings("test-app", reopened_name);
    try std.testing.expectEqual(@as(i64, 42), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("enabled").?);

    _ = reopened.delete("name");
    try std.testing.expect(!reopened.has("name"));

    try reopened.clear();
    try std.testing.expect(!reopened.has("version"));
}

test "GenericStore: set copies values instead of borrowing them" {
    const gpa = std.testing.allocator;
    defer MockBackend.reset();
    MockBackend.reset();

    const TestStore = GenericStore(MockBackend);
    var store = try TestStore.openPath(gpa, "/test/store.json");
    defer store.deinit();

    // A std.json.Value pointing at caller memory that changes afterwards.
    var buf = "borrowed".*;
    try store.set("value", std.json.Value{ .string = &buf });
    @memset(&buf, 'x');
    const val = (try store.getString(gpa, "value")).?;
    defer gpa.free(val);
    try std.testing.expectEqualStrings("borrowed", val);

    // Strings must not point into set()'s scratch buffer either.
    try store.set("a", "first");
    try store.set("b", "second value, long enough to overwrite the first");
    const a1 = (try store.getString(gpa, "a")).?;
    defer gpa.free(a1);
    try std.testing.expectEqualStrings("first", a1);

    // Overwriting a key keeps a single entry.
    try store.set("a", "again");
    const a2 = (try store.getString(gpa, "a")).?;
    defer gpa.free(a2);
    try std.testing.expectEqualStrings("again", a2);
    try std.testing.expectEqual(@as(usize, 3), store.map.count());
}

test "GenericStore: get and getString return owned copies that survive set, delete, and clear" {
    const gpa = std.testing.allocator;
    defer MockBackend.reset();
    MockBackend.reset();

    const TestStore = GenericStore(MockBackend);
    var store = try TestStore.openPath(gpa, "/test/store.json");
    defer store.deinit();
    store.auto_save = false;

    try store.set("greeting", "hello");
    try store.set("complex", .{
        .label = "initial",
        .items = [_][]const u8{ "one", "two" },
    });

    const owned_str = (try store.getString(gpa, "greeting")).?;
    defer gpa.free(owned_str);
    const owned_val = (try store.get(gpa, "complex")).?;
    defer owned_val.deinit();

    // Overwrite both keys.
    try store.set("greeting", "replaced");
    try store.set("complex", .{ .label = "replaced", .items = [_][]const u8{"three"} });
    try std.testing.expectEqualStrings("hello", owned_str);
    try std.testing.expectEqualStrings("initial", owned_val.value.object.get("label").?.string);
    try std.testing.expectEqualStrings("two", owned_val.value.object.get("items").?.array.items[1].string);

    // Delete both keys.
    try std.testing.expect(store.delete("greeting"));
    try std.testing.expect(store.delete("complex"));
    try std.testing.expectEqualStrings("hello", owned_str);
    try std.testing.expectEqualStrings("initial", owned_val.value.object.get("label").?.string);

    // Re-populate and clear the store.
    try store.set("greeting", "third");
    try store.clear();
    try std.testing.expectEqualStrings("hello", owned_str);
    try std.testing.expectEqualStrings("initial", owned_val.value.object.get("label").?.string);

    try std.testing.expect((try store.get(gpa, "greeting")) == null);
    try std.testing.expect((try store.getString(gpa, "greeting")) == null);
}

fn openAllocationFailures(gpa: std.mem.Allocator) !void {
    MockBackend.reset();
    defer MockBackend.reset();
    const original = "{\"a\":\"x\",\"b\":[1,999999999999999999999999999999],\"c\":{\"d\":true,\"e\":null,\"f\":1.5}}";
    try MockBackend.writeFileAtomic("/test/store.json", original);
    const store = GenericStore(MockBackend).openPath(gpa, "/test/store.json") catch |err| {
        try std.testing.expectEqualStrings(original, MockBackend.stored_data.?);
        try std.testing.expectEqualStrings("/test/store.json", MockBackend.last_path.?);
        return err;
    };
    store.auto_save = false;
    defer store.deinit();
    const a = (try store.getString(gpa, "a")).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("x", a);
    const b = (try store.get(gpa, "b")).?;
    defer b.deinit();
    try std.testing.expectEqualStrings("999999999999999999999999999999", b.value.array.items[1].number_string);
    try std.testing.expectEqual(@as(usize, 3), store.map.count());
}

test "GenericStore: openPath propagates every allocation failure without changing disk" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, openAllocationFailures, .{});
}

test "GenericStore: invalid JSON and non-object roots preserve original bytes" {
    for ([_][]const u8{ "{invalid", "[1,2]", "null" }) |original| {
        MockBackend.reset();
        defer MockBackend.reset();
        try MockBackend.writeFileAtomic("/test/store.json", original);
        const store = try GenericStore(MockBackend).openPath(std.testing.allocator, "/test/store.json");
        defer store.deinit();
        try std.testing.expectEqualStrings(original, MockBackend.stored_data.?);
        try std.testing.expectEqualStrings(original, MockBackend.backup_data.?);
        try std.testing.expectEqualStrings("/test/store.json.corrupt", MockBackend.last_path.?);
        try std.testing.expectEqual(@as(usize, 0), store.map.count());
        try store.set("new", true);
        try std.testing.expectEqualStrings(original, MockBackend.backup_data.?);
    }
}

test "GenericStore: failed quarantine prevents opening and overwriting original" {
    MockBackend.reset();
    defer MockBackend.reset();
    const original = "{invalid";
    try MockBackend.writeFileAtomic("/test/store.json", original);
    MockBackend.fail_write = true;
    try std.testing.expectError(error.SaveFailed, GenericStore(MockBackend).openPath(std.testing.allocator, "/test/store.json"));
    try std.testing.expectEqualStrings(original, MockBackend.stored_data.?);
    try std.testing.expect(MockBackend.backup_data == null);
}

fn mutationAllocationFailures(gpa: std.mem.Allocator) !void {
    MockBackend.reset();
    defer MockBackend.reset();
    const store = try GenericStore(MockBackend).openPath(gpa, "/test/store.json");
    store.auto_save = false;
    defer store.deinit();
    try store.set("key", .{ .nested = [_][]const u8{ "old", "value" } });
    try store.set("other", "stable");
    store.set("key", .{ .nested = [_][]const u8{ "new", "value" } }) catch |err| {
        try std.testing.expectEqualStrings("old", store.map.get("key").?.value.object.get("nested").?.array.items[0].string);
        return err;
    };
    const owned_other = (try store.getString(gpa, "other")).?;
    defer gpa.free(owned_other);
    const owned_key = (try store.get(gpa, "key")).?;
    defer owned_key.deinit();
    try store.set("copy", owned_key.value);
    try std.testing.expectEqualStrings("stable", owned_other);
    try store.save();
    try std.testing.expect(store.delete("key"));
    try store.clear();
}

test "GenericStore: mutations and serialization release every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, mutationAllocationFailures, .{});
}

fn getAllocationFailures(gpa: std.mem.Allocator) !void {
    MockBackend.reset();
    defer MockBackend.reset();
    const stable = std.testing.allocator;
    const store = try GenericStore(MockBackend).openPath(stable, "/test/store.json");
    store.auto_save = false;
    defer store.deinit();
    try store.set("str", "hello world");
    try store.set("num", 42);
    try store.set("tree", .{
        .title = "settings",
        .list = [_][]const u8{ "alpha", "beta" },
        .inner = .{ .ok = true },
    });

    const s = (try store.getString(gpa, "str")).?;
    defer gpa.free(s);
    try std.testing.expectEqualStrings("hello world", s);
    try std.testing.expect((try store.getString(gpa, "num")) == null);
    try std.testing.expect((try store.getString(gpa, "missing")) == null);

    const tree = (try store.get(gpa, "tree")).?;
    defer tree.deinit();
    try std.testing.expectEqualStrings("settings", tree.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("beta", tree.value.object.get("list").?.array.items[1].string);
    try std.testing.expect((try store.get(gpa, "missing")) == null);
}

test "GenericStore: get and getString release every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, getAllocationFailures, .{});
}

test "GenericStore: replace delete and clear reclaim entry memory immediately" {
    MockBackend.reset();
    defer MockBackend.reset();
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const store = try GenericStore(MockBackend).openPath(tracking.allocator(), "/test/store.json");
    defer store.deinit();
    store.auto_save = false;
    const large = "x" ** 8192;
    try store.set("key", large);
    var freed = tracking.freed_bytes;
    // Even replacing from an existing entry's value prepares the copy before freeing it.
    try store.set("key", store.map.get("key").?.value);
    try std.testing.expect(tracking.freed_bytes > freed + large.len);
    freed = tracking.freed_bytes;
    try std.testing.expect(store.delete("key"));
    try std.testing.expect(tracking.freed_bytes > freed + large.len);
    try store.set("key", large);
    freed = tracking.freed_bytes;
    try store.clear();
    try std.testing.expect(tracking.freed_bytes > freed + large.len);
}

fn quarantineAllocationFailures(gpa: std.mem.Allocator) !void {
    MockBackend.reset();
    defer MockBackend.reset();
    const original = "{invalid";
    try MockBackend.writeFileAtomic("/test/store.json", original);
    const store = GenericStore(MockBackend).openPath(gpa, "/test/store.json") catch |err| {
        try std.testing.expectEqualStrings(original, MockBackend.stored_data.?);
        try std.testing.expect(MockBackend.backup_data == null);
        return err;
    };
    store.auto_save = false;
    defer store.deinit();
    try std.testing.expectEqualStrings(original, MockBackend.stored_data.?);
    try std.testing.expectEqualStrings(original, MockBackend.backup_data.?);
}

test "GenericStore: quarantine propagates allocation failures without changing disk" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, quarantineAllocationFailures, .{});
}
