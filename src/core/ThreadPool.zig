//! Worker thread pool for offloading commands from the main/UI thread.
//!
//! Owned by `App.run` and shut down cleanly when the application terminates.

const std = @import("std");

pub const ThreadPool = struct {
    pub const Task = struct {
        run_fn: *const fn (*Task) void,
        next: ?*Task = null,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    threads: []std.Thread,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    head: ?*Task = null,
    tail: ?*Task = null,
    shutdown: bool = false,
    /// Tasks accepted and not yet taken by a worker.
    queued: usize = 0,
    /// `post` refuses a task beyond this many waiting ones: pages can queue
    /// async commands faster than workers run them, and each holds memory.
    max_queued: usize = default_max_queued,

    pub const default_max_queued = 1024;

    pub const PostError = error{ WorkerPoolNotRunning, WorkerPoolBusy };

    /// Create and start a worker pool with `count` threads (defaults to CPU count clamped [2, 16]).
    pub fn init(allocator: std.mem.Allocator, io: std.Io, count: ?usize) !*ThreadPool {
        const num_threads = count orelse blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :blk @max(2, @min(cpus, 16));
        };
        const pool = try allocator.create(ThreadPool);
        errdefer allocator.destroy(pool);
        pool.* = .{
            .io = io,
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, num_threads),
            .mutex = .init,
            .cond = .init,
            .head = null,
            .tail = null,
            .shutdown = false,
            .queued = 0,
            .max_queued = default_max_queued,
        };
        var spawned: usize = 0;
        errdefer {
            pool.mutex.lockUncancelable(io);
            pool.shutdown = true;
            pool.cond.broadcast(io);
            pool.mutex.unlock(io);
            for (pool.threads[0..spawned]) |t| t.join();
            allocator.free(pool.threads);
        }
        for (pool.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{pool});
            spawned += 1;
        }
        return pool;
    }

    /// Enqueue a task to be run on one of the worker threads. False when
    /// the pool is stopping or already holds `max_queued` waiting tasks.
    pub fn post(pool: *ThreadPool, task: *Task) bool {
        pool.submit(task) catch return false;
        return true;
    }

    /// `post`, telling a stopped pool (WorkerPoolNotRunning) from a full
    /// queue (WorkerPoolBusy).
    pub fn submit(pool: *ThreadPool, task: *Task) PostError!void {
        task.next = null;
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);
        if (pool.shutdown) return error.WorkerPoolNotRunning;
        if (pool.queued >= pool.max_queued) return error.WorkerPoolBusy;
        pool.queued += 1;
        if (pool.tail) |tail| {
            tail.next = task;
            pool.tail = task;
        } else {
            pool.head = task;
            pool.tail = task;
        }
        pool.cond.signal(pool.io);
    }

    fn workerLoop(pool: *ThreadPool) void {
        const io = pool.io;
        while (true) {
            pool.mutex.lockUncancelable(io);
            while (pool.head == null and !pool.shutdown) {
                pool.cond.waitUncancelable(io, &pool.mutex);
            }
            if (pool.shutdown and pool.head == null) {
                pool.mutex.unlock(io);
                break;
            }
            const task = pool.head.?;
            pool.head = task.next;
            if (pool.head == null) pool.tail = null;
            pool.queued -= 1;
            pool.mutex.unlock(io);

            task.run_fn(task);
        }
    }

    /// Refuse new tasks and let workers drain the accepted queue.
    pub fn stop(pool: *ThreadPool) void {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        pool.shutdown = true;
        pool.cond.broadcast(io);
        pool.mutex.unlock(io);
    }

    /// Stop, wait for the accepted queue to drain, and free the pool.
    pub fn deinit(pool: *ThreadPool) void {
        pool.stop();
        for (pool.threads) |t| {
            t.join();
        }
        pool.allocator.free(pool.threads);
        pool.allocator.destroy(pool);
    }
};

test "ThreadPool execution" {
    const io = std.testing.io;
    const pool = try ThreadPool.init(std.testing.allocator, io, 2);
    defer pool.deinit();

    const Job = struct {
        task: ThreadPool.Task,
        done: *std.atomic.Value(bool),

        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            self.done.store(true, .release);
        }
    };

    var done = std.atomic.Value(bool).init(false);
    var job = Job{
        .task = .{ .run_fn = &Job.run },
        .done = &done,
    };

    try std.testing.expect(pool.post(&job.task));

    while (!done.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(done.load(.acquire));
}

test "a full queue refuses tasks" {
    const pool = try ThreadPool.init(std.testing.allocator, std.testing.io, 1);
    defer pool.deinit();
    const Job = struct {
        task: ThreadPool.Task = .{ .run_fn = run },
        gate: *std.atomic.Value(bool),
        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            while (!self.gate.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    var gate: std.atomic.Value(bool) = .init(false);
    var jobs: [3]Job = .{ .{ .gate = &gate }, .{ .gate = &gate }, .{ .gate = &gate } };
    // Set before the first post: the worker reads it under the same lock.
    pool.mutex.lockUncancelable(pool.io);
    pool.max_queued = 1;
    pool.mutex.unlock(pool.io);
    try pool.submit(&jobs[0].task);
    // Wait for the worker to take the first (blocking on the gate).
    while (true) {
        pool.mutex.lockUncancelable(pool.io);
        const n = pool.queued;
        pool.mutex.unlock(pool.io);
        if (n == 0) break;
        std.Thread.yield() catch {};
    }
    try pool.submit(&jobs[1].task);
    try std.testing.expectError(error.WorkerPoolBusy, pool.submit(&jobs[2].task));
    gate.store(true, .release);
}

test "shutdown drains accepted tasks and rejects new tasks" {
    const pool = try ThreadPool.init(std.testing.allocator, std.testing.io, 1);
    var count: std.atomic.Value(u32) = .init(0);
    const Job = struct {
        task: ThreadPool.Task = .{ .run_fn = run },
        count: *std.atomic.Value(u32),
        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            _ = self.count.fetchAdd(1, .release);
        }
    };
    var first: Job = .{ .count = &count };
    var rejected: Job = .{ .count = &count };
    const accepted = pool.post(&first.task);
    pool.stop();
    const late = pool.post(&rejected.task);
    pool.deinit();
    try std.testing.expect(accepted);
    try std.testing.expect(!late);
    try std.testing.expectEqual(@as(u32, 1), count.load(.acquire));
}
