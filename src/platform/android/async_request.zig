//! Reusable async request synchronization for Android JNI calls.
//!
//! Many Android APIs (camera, SAF file pickers, folder permissions) run
//! asynchronously on Kotlin/Android threads and report back via JNI
//! callbacks using a 64-bit integer handle (pointer address).
//!
//! `AsyncRequest(T)` encapsulates the pthread mutex/condvar wait and
//! signal logic, handle conversion, and result storage.

const std = @import("std");

pub fn AsyncRequest(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.c.pthread_mutex_t = .{},
        cond: std.c.pthread_cond_t = .{},
        done: bool = false,
        result: T,

        pub fn init(initial: T) Self {
            return .{ .result = initial };
        }

        pub fn handle(self: *Self) i64 {
            return @bitCast(@as(u64, @intFromPtr(self)));
        }

        pub fn fromHandle(raw: i64) *Self {
            return @ptrFromInt(@as(usize, @bitCast(raw)));
        }

        pub fn reset(self: *Self, initial: T) void {
            _ = std.c.pthread_mutex_lock(&self.mutex);
            self.result = initial;
            self.done = false;
            _ = std.c.pthread_mutex_unlock(&self.mutex);
        }

        pub fn wait(self: *Self) void {
            _ = std.c.pthread_mutex_lock(&self.mutex);
            defer _ = std.c.pthread_mutex_unlock(&self.mutex);
            while (!self.done) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        }

        pub fn complete(self: *Self, val: T) void {
            _ = std.c.pthread_mutex_lock(&self.mutex);
            self.result = val;
            self.done = true;
            _ = std.c.pthread_cond_broadcast(&self.cond);
            _ = std.c.pthread_mutex_unlock(&self.mutex);
        }
    };
}

test "AsyncRequest basic flow" {
    var req: AsyncRequest(u32) = .init(0);
    const h = req.handle();
    const ptr = AsyncRequest(u32).fromHandle(h);
    try std.testing.expectEqual(&req, ptr);

    const Worker = struct {
        fn run(r: *AsyncRequest(u32)) void {
            std.time.sleep(10 * std.time.ns_per_ms);
            r.complete(42);
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{&req});
    req.wait();
    thread.join();
    try std.testing.expectEqual(@as(u32, 42), req.result);
}
