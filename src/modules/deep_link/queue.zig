//! Pure queue logic for deep link URL delivery before and after page readiness.
//!
//! When incoming deep link URLs arrive before the page listens for `deep-link`,
//! their webview events are held in a FIFO queue (the Zig `onOpen` handler is
//! called right away). Once the page signals readiness, queued URLs are flushed
//! in order. URLs delivered while ready bypass the queue. When the queue is
//! full, the oldest URL is dropped.

const std = @import("std");
const common = @import("common.zig");

pub const Queue = struct {
    pub const max_queued: usize = 16;

    pub const Item = struct {
        buf: [common.max_url_len]u8 = undefined,
        len: usize = 0,

        pub fn slice(self: *const Item) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *Item, url: []const u8) bool {
            if (url.len > self.buf.len) return false;
            @memcpy(self.buf[0..url.len], url);
            self.len = url.len;
            return true;
        }
    };

    items: [max_queued]Item = [_]Item{.{}} ** max_queued,
    count: usize = 0,
    head: usize = 0,
    is_ready: bool = false,
    latest: ?Item = null,

    /// Record the cold-start launch URL.
    pub fn setColdStartUrl(self: *Queue, url: []const u8) void {
        var item: Item = .{};
        if (item.set(url)) {
            self.latest = item;
        }
    }

    /// The most recent URL: the one that launched the application, or the
    /// latest one received since.
    pub fn current(self: *const Queue) ?[]const u8 {
        if (self.latest) |*l| return l.slice();
        return null;
    }

    /// Push an incoming URL.
    /// If the queue is not yet ready, the URL is stored in the FIFO buffer and `true` is returned.
    /// If the queue is already ready, `false` is returned (caller should deliver immediately).
    /// A full queue drops its oldest URL.
    pub fn push(self: *Queue, url: []const u8) !bool {
        var item: Item = .{};
        if (!item.set(url)) return error.UrlTooLong;
        self.latest = item;

        if (self.is_ready) {
            return false;
        }

        if (self.count >= max_queued) {
            self.head = (self.head + 1) % max_queued;
            self.count -= 1;
        }

        const idx = (self.head + self.count) % max_queued;
        self.items[idx] = item;
        self.count += 1;
        return true;
    }

    /// Pop the next queued URL in FIFO order. Returns null when empty.
    pub fn pop(self: *Queue) ?[]const u8 {
        if (self.count == 0) return null;
        const idx = self.head;
        self.head = (self.head + 1) % max_queued;
        self.count -= 1;
        return self.items[idx].slice();
    }

    /// Update page readiness state.
    pub fn setReady(self: *Queue, ready: bool) void {
        self.is_ready = ready;
    }

    /// Reset all queue state (useful for tests and cleanup).
    pub fn clear(self: *Queue) void {
        self.count = 0;
        self.head = 0;
        self.latest = null;
        self.is_ready = false;
    }
};

test "queued-before-ready delivery" {
    var q: Queue = .{};
    try std.testing.expect(!q.is_ready);
    try std.testing.expect(q.current() == null);

    // 1. Set cold-start URL before ready
    q.setColdStartUrl("myapp://start");
    try std.testing.expectEqualStrings("myapp://start", q.current().?);

    // 2. Push while not ready -> queued
    const queued1 = try q.push("myapp://start");
    try std.testing.expect(queued1);
    try std.testing.expectEqual(@as(usize, 1), q.count);

    const queued2 = try q.push("myapp://second");
    try std.testing.expect(queued2);
    try std.testing.expectEqual(@as(usize, 2), q.count);

    // current() is the latest URL
    try std.testing.expectEqualStrings("myapp://second", q.current().?);

    // 3. Mark ready and drain FIFO
    q.setReady(true);
    try std.testing.expect(q.is_ready);

    const first = q.pop();
    try std.testing.expect(first != null);
    try std.testing.expectEqualStrings("myapp://start", first.?);

    const second = q.pop();
    try std.testing.expect(second != null);
    try std.testing.expectEqualStrings("myapp://second", second.?);

    try std.testing.expect(q.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), q.count);

    // 4. Push while already ready -> not queued (direct delivery)
    const queued3 = try q.push("myapp://third");
    try std.testing.expect(!queued3);
    try std.testing.expectEqual(@as(usize, 0), q.count);

    // 5. Length limit enforcement
    var oversized: [common.max_url_len + 1]u8 = undefined;
    @memset(&oversized, 'a');
    try std.testing.expectError(error.UrlTooLong, q.push(&oversized));
}

test "full queue drops the oldest; current is the latest" {
    var q: Queue = .{};
    q.setColdStartUrl("myapp://cold");
    try std.testing.expectEqualStrings("myapp://cold", q.current().?);
    var buf: [32]u8 = undefined;
    for (0..Queue.max_queued + 2) |i| {
        _ = try q.push(try std.fmt.bufPrint(&buf, "myapp://{d}", .{i}));
    }
    try std.testing.expectEqual(Queue.max_queued, q.count);
    try std.testing.expectEqualStrings("myapp://17", q.current().?);
    q.setReady(true);
    try std.testing.expectEqualStrings("myapp://2", q.pop().?);
}
