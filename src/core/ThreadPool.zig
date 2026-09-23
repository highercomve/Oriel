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

    /// Create and start a worker pool with `count` threads (defaults to CPU count clamped [2, 16]).
    pub fn init(allocator: std.mem.Allocator, io: std.Io, count: ?usize) !*ThreadPool {
        const num_threads = count orelse blk: {
            const cpus = std.Thread.getCpuCount() catch 4;
            break :blk @max(2, @min(cpus, 16));
        };
        const pool = try allocator.create(ThreadPool);
        pool.* = .{
            .io = io,
            .allocator = allocator,
            .threads = try allocator.alloc(std.Thread, num_threads),
            .mutex = .init,
            .cond = .init,
            .head = null,
            .tail = null,
            .shutdown = false,
        };
        var spawned: usize = 0;
        errdefer {
            pool.mutex.lockUncancelable(io);
            pool.shutdown = true;
            pool.cond.broadcast(io);
            pool.mutex.unlock(io);
            for (pool.threads[0..spawned]) |t| t.join();
            allocator.free(pool.threads);
            allocator.destroy(pool);
        }
        for (pool.threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{pool});
            spawned += 1;
        }
        return pool;
    }

    /// Enqueue a task to be run on one of the worker threads.
    pub fn post(pool: *ThreadPool, task: *Task) void {
        task.next = null;
        pool.mutex.lockUncancelable(pool.io);
        defer pool.mutex.unlock(pool.io);
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
            pool.mutex.unlock(io);

            task.run_fn(task);
        }
    }

    /// Signal all workers to shut down and wait for all threads to finish.
    pub fn deinit(pool: *ThreadPool) void {
        const io = pool.io;
        pool.mutex.lockUncancelable(io);
        pool.shutdown = true;
        pool.cond.broadcast(io);
        pool.mutex.unlock(io);

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

    pool.post(&job.task);

    while (!done.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    try std.testing.expect(done.load(.acquire));
}
