//! Events that may come before anyone listens: a notification click or a
//! share that launched the app arrives before the app sets its handler and
//! before the page calls `listen`. Each such event has a queue that keeps
//! what came early and hands it over later, once to each audience:
//!
//! - the app's Zig handler, when it is set (`handlerSet`);
//! - the page, when it listens: the bridges' `listen()` sends the
//!   `events:ready` built-in (`{ event }`) for the events in `queued`.
//!
//! Each audience's queue holds up to `capacity` events; when full, the
//! oldest is dropped. Everything runs on the main thread except
//! `handlerSet` and `pageReady`, which may be called from any thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const heap = @import("heap.zig");

const log = std.log.scoped(.events);

/// The events that are queued: the bridges' `listen()` sends `events:ready`
/// for these (a frozen set, so the bridges and Zig agree).
pub const queued = [_][]const u8{ "notification:action", "share:received", "deep-link" };

fn slotOf(comptime event: []const u8) usize {
    inline for (queued, 0..) |name, i| {
        if (comptime std.mem.eql(u8, name, event)) return i;
    }
    @compileError("pending_events: add " ++ event ++ " to `queued` (and to the bridges' listen())");
}

/// Whether `event` is one of `queued`.
pub fn isQueued(event: []const u8) bool {
    for (queued) |name| if (std.mem.eql(u8, name, event)) return true;
    return false;
}

// Main thread only.
var page_ready = [_]bool{false} ** queued.len;
var page_flush = [_]?*const fn () void{null} ** queued.len;

/// The page listens for `event` (the `events:ready` built-in; any thread):
/// what came earlier is emitted now, and later ones as they come. False if
/// `event` isn't queued.
pub fn pageReady(event: []const u8) bool {
    for (queued, 0..) |name, i| {
        if (std.mem.eql(u8, name, event)) {
            App.runOnMain(i, pageReadyMain);
            return true;
        }
    }
    return false;
}

fn pageReadyMain(slot: usize) void {
    page_ready[slot] = true;
    if (page_flush[slot]) |flush| flush();
}

/// The queue of `event`, carrying `T` (copied, so a backend's buffers can go
/// once `deliver` returns). `toHandler` hands one to the app's Zig handler,
/// returning false when there is none.
pub fn Queue(comptime T: type, comptime event: []const u8, comptime capacity: usize, comptime toHandler: fn (*const T) bool) type {
    const slot = slotOf(event);
    return struct {
        var pending: Pending(T, capacity) = .{ .gpa = heap.gpa };

        /// An event from a backend (main thread).
        pub fn deliver(value: T) void {
            page_flush[slot] = flushPage;
            pending.deliver(value, toHandler, page_ready[slot], emit);
        }

        /// The app set its handler (any thread): what came earlier reaches it.
        pub fn handlerSet() void {
            App.runOnMain({}, flushHandler);
        }

        fn flushHandler(_: void) void {
            pending.flushHandler(toHandler);
        }

        fn flushPage() void {
            pending.flushPage(emit);
        }

        fn emit(value: *const T) void {
            App.emit(event, value.*);
        }
    };
}

/// `Queue`'s state, without the main thread and the page (tested).
pub fn Pending(comptime T: type, comptime capacity: usize) type {
    return struct {
        gpa: Allocator,
        for_handler: Fifo(T, capacity) = .{},
        for_page: Fifo(T, capacity) = .{},

        const Self = @This();

        pub fn deliver(self: *Self, value: T, toHandler: *const fn (*const T) bool, page_listens: bool, emit: *const fn (*const T) void) void {
            if (!toHandler(&value)) self.for_handler.push(self.gpa, value);
            if (page_listens) emit(&value) else self.for_page.push(self.gpa, value);
        }

        /// Hand what the handler missed to it, oldest first, until it's gone.
        pub fn flushHandler(self: *Self, toHandler: *const fn (*const T) bool) void {
            while (self.for_handler.pop()) |item| {
                if (!toHandler(&item)) {
                    self.for_handler.pushFront(item);
                    return;
                }
                freeDeep(self.gpa, T, item);
            }
        }

        pub fn flushPage(self: *Self, emit: *const fn (*const T) void) void {
            while (self.for_page.pop()) |item| {
                emit(&item);
                freeDeep(self.gpa, T, item);
            }
        }

        pub fn deinit(self: *Self) void {
            while (self.for_handler.pop()) |item| freeDeep(self.gpa, T, item);
            while (self.for_page.pop()) |item| freeDeep(self.gpa, T, item);
        }
    };
}

/// A ring of owned copies; full, a push drops the oldest.
fn Fifo(comptime T: type, comptime capacity: usize) type {
    comptime std.debug.assert(capacity > 0);
    return struct {
        items: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, gpa: Allocator, value: T) void {
            const copy = dupeDeep(gpa, T, value) catch {
                log.err("dropped an event: out of memory", .{});
                return;
            };
            if (self.len == capacity) {
                if (capacity > 1) log.info("{d} events came before anyone listened: dropped the oldest", .{capacity + 1});
                freeDeep(gpa, T, self.items[self.head]);
                self.head = (self.head + 1) % capacity;
                self.len -= 1;
            }
            self.items[(self.head + self.len) % capacity] = copy;
            self.len += 1;
        }

        /// Put back what `pop` returned (there is room: it came out).
        fn pushFront(self: *Self, item: T) void {
            std.debug.assert(self.len < capacity);
            self.head = (self.head + capacity - 1) % capacity;
            self.items[self.head] = item;
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }
    };
}

/// A copy of `value` owning every slice in it (strings, slices of structs,
/// optionals), freed by `freeDeep`.
pub fn dupeDeep(gpa: Allocator, comptime T: type, value: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => return value,
        .optional => |o| return if (value) |v| try dupeDeep(gpa, o.child, v) else null,
        .pointer => |p| {
            if (p.size != .slice) @compileError("pending_events: can't copy " ++ @typeName(T));
            const out = try gpa.alloc(p.child, value.len);
            errdefer gpa.free(out);
            if (comptime needsDeepCopy(p.child)) {
                var done: usize = 0;
                errdefer for (out[0..done]) |item| freeDeep(gpa, p.child, item);
                for (value, out) |item, *dst| {
                    dst.* = try dupeDeep(gpa, p.child, item);
                    done += 1;
                }
            } else @memcpy(out, value);
            return out;
        },
        .@"struct" => |s| {
            var out: T = value;
            inline for (s.fields, 0..) |f, i| {
                errdefer inline for (s.fields[0..i]) |g| freeDeep(gpa, g.type, @field(out, g.name));
                @field(out, f.name) = try dupeDeep(gpa, f.type, @field(value, f.name));
            }
            return out;
        },
        else => @compileError("pending_events: can't copy " ++ @typeName(T)),
    }
}

pub fn freeDeep(gpa: Allocator, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => {},
        .optional => |o| if (value) |v| freeDeep(gpa, o.child, v),
        .pointer => |p| {
            if (comptime needsDeepCopy(p.child)) for (value) |item| freeDeep(gpa, p.child, item);
            gpa.free(value);
        },
        .@"struct" => |s| inline for (s.fields) |f| freeDeep(gpa, f.type, @field(value, f.name)),
        else => @compileError("pending_events: can't free " ++ @typeName(T)),
    }
}

fn needsDeepCopy(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => false,
        else => true,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Click = struct { id: []const u8, action: ?[]const u8 };

/// What the test handler and page saw, in order.
const Seen = struct {
    var handler_on = false;
    var handler: [8][32]u8 = undefined;
    var handler_n: usize = 0;
    var page: [8][32]u8 = undefined;
    var page_n: usize = 0;

    fn reset() void {
        handler_on = false;
        handler_n = 0;
        page_n = 0;
    }

    fn record(buf: *[8][32]u8, n: *usize, c: *const Click) void {
        _ = std.fmt.bufPrint(&buf[n.*], "{s}/{s}", .{ c.id, c.action orelse "-" }) catch unreachable;
        n.* += 1;
    }

    fn toHandler(c: *const Click) bool {
        if (!handler_on) return false;
        record(&handler, &handler_n, c);
        return true;
    }

    fn emit(c: *const Click) void {
        record(&page, &page_n, c);
    }

    fn expectHandler(i: usize, want: []const u8) !void {
        try testing.expectStringStartsWith(&handler[i], want);
    }

    fn expectPage(i: usize, want: []const u8) !void {
        try testing.expectStringStartsWith(&page[i], want);
    }
};

test "Pending: events before the handler and the page reach both later, once" {
    Seen.reset();
    var p: Pending(Click, 4) = .{ .gpa = testing.allocator };
    defer p.deinit();
    var id_buf = "msg-1".*;
    p.deliver(.{ .id = &id_buf, .action = "reply" }, Seen.toHandler, false, Seen.emit);
    id_buf[4] = '2'; // the backend's buffer changes: the queue kept a copy
    p.deliver(.{ .id = &id_buf, .action = null }, Seen.toHandler, false, Seen.emit);
    try testing.expectEqual(@as(usize, 0), Seen.handler_n);
    try testing.expectEqual(@as(usize, 0), Seen.page_n);

    Seen.handler_on = true;
    p.flushHandler(Seen.toHandler);
    try testing.expectEqual(@as(usize, 2), Seen.handler_n);
    try Seen.expectHandler(0, "msg-1/reply");
    try Seen.expectHandler(1, "msg-2/-");
    p.flushHandler(Seen.toHandler);
    try testing.expectEqual(@as(usize, 2), Seen.handler_n);

    p.flushPage(Seen.emit);
    try testing.expectEqual(@as(usize, 2), Seen.page_n);
    try Seen.expectPage(0, "msg-1/reply");

    // Both listening: straight through.
    p.deliver(.{ .id = "msg-3", .action = null }, Seen.toHandler, true, Seen.emit);
    try testing.expectEqual(@as(usize, 3), Seen.handler_n);
    try testing.expectEqual(@as(usize, 3), Seen.page_n);
}

test "Pending: a full queue drops the oldest; capacity 1 keeps the last" {
    Seen.reset();
    var p: Pending(Click, 1) = .{ .gpa = testing.allocator };
    defer p.deinit();
    p.deliver(.{ .id = "a", .action = null }, Seen.toHandler, false, Seen.emit);
    p.deliver(.{ .id = "b", .action = null }, Seen.toHandler, false, Seen.emit);
    p.flushPage(Seen.emit);
    try testing.expectEqual(@as(usize, 1), Seen.page_n);
    try Seen.expectPage(0, "b/-");

    var q: Pending(Click, 2) = .{ .gpa = testing.allocator };
    defer q.deinit();
    for ([_][]const u8{ "1", "2", "3" }) |id| q.deliver(.{ .id = id, .action = null }, Seen.toHandler, true, Seen.emit);
    Seen.handler_on = true;
    q.flushHandler(Seen.toHandler);
    try testing.expectEqual(@as(usize, 2), Seen.handler_n);
    try Seen.expectHandler(0, "2/-");
    try Seen.expectHandler(1, "3/-");
}

test "Pending: a handler gone while flushing keeps the rest" {
    Seen.reset();
    var p: Pending(Click, 4) = .{ .gpa = testing.allocator };
    defer p.deinit();
    p.deliver(.{ .id = "a", .action = null }, Seen.toHandler, true, Seen.emit);
    p.deliver(.{ .id = "b", .action = null }, Seen.toHandler, true, Seen.emit);
    p.flushHandler(Seen.toHandler); // no handler yet
    try testing.expectEqual(@as(usize, 2), p.for_handler.len);
    Seen.handler_on = true;
    p.flushHandler(Seen.toHandler);
    try Seen.expectHandler(0, "a/-");
    try Seen.expectHandler(1, "b/-");
}

test dupeDeep {
    const File = struct { handle: u32, name: []const u8 };
    const Share = struct { id: u32, text: ?[]const u8, files: []const File };
    const gpa = testing.allocator;
    const files = [_]File{ .{ .handle = 1, .name = "a.png" }, .{ .handle = 2, .name = "b.txt" } };
    const copy = try dupeDeep(gpa, Share, .{ .id = 7, .text = "hi", .files = &files });
    defer freeDeep(gpa, Share, copy);
    try testing.expectEqual(@as(u32, 7), copy.id);
    try testing.expectEqualStrings("hi", copy.text.?);
    try testing.expect(copy.files.ptr != &files);
    try testing.expectEqualStrings("b.txt", copy.files[1].name);
    try testing.expect(copy.files[1].name.ptr != files[1].name.ptr);
    // Out of memory part-way: nothing leaks.
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 3 });
    try testing.expectError(error.OutOfMemory, dupeDeep(failing.allocator(), Share, .{ .id = 7, .text = "hi", .files = &files }));
}

test isQueued {
    try testing.expect(isQueued("notification:action"));
    try testing.expect(isQueued("share:received"));
    try testing.expect(!isQueued("tick"));
}
