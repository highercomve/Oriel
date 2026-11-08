//! Page-to-Zig policy and scheduling, independent of the WebView transport.
//! Transports retain/release their reply endpoint, post UI tasks (including
//! cleanup on rejection), check reply liveness, and settle JSON/error replies.
const std = @import("std");
const App = @import("App.zig");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const isolation = @import("isolation.zig");
const internal = @import("internal.zig");
const windows = @import("window_commands.zig");

pub fn Dispatcher(comptime api: App.Api, comptime config: App.Config, comptime local: security.Local, comptime Transport: type) type {
    return struct {
        const Self = @This();

        /// Called on the UI thread with a borrowed reply endpoint and parse arena.
        /// Security order: token, isolation, window API policy (inside dispatch),
        /// then capabilities for ordinary commands, before any command runs.
        pub fn run(t: Transport, gpa: std.mem.Allocator, arena: std.mem.Allocator, request: ipc.Request, json: []const u8, page: []const u8, label: ?[]const u8, view: usize) !void {
            if (!ipc.tokenValid(request.token, config.security, local, page)) {
                Transport.warn("refused an IPC call without this page's token (\"{f}\")", .{std.zig.fmtString(request.cmd[0..@min(request.cmd.len, 64)])});
                return settle(t, null, "Forbidden");
            }
            const checked = isolation.check(arena, config.app.isolation, local, page, view, request, json) catch |err| {
                return settle(t, null, isolation.errorText(err));
            };
            const call = checked.request;
            const is_window = windows.isWindowCommand(call.cmd);
            if (!is_window and !security.commandAllowedForWindow(config.security, local, page, call.cmd, label)) {
                Transport.warn("blocked command \"{f}\" from {s} (window: {?s})", .{ std.zig.fmtString(call.cmd[0..@min(call.cmd.len, 64)]), page, label });
                return settle(t, null, "Forbidden");
            }
            const pool = internal.getWorkerPool();
            defer if (pool != null) internal.releaseWorkerPool();
            return route(t, gpa, arena, call, page, label, pool);
        }

        fn route(t: Transport, gpa: std.mem.Allocator, arena: std.mem.Allocator, call: ipc.Request, page: []const u8, label: ?[]const u8, pool: ?*@import("ThreadPool.zig").ThreadPool) !void {
            const is_window = windows.isWindowCommand(call.cmd);
            const io = if (pool) |p| p.io else null;
            if (is_window or ipc.isBuiltinCommand(call.cmd) or !ipc.isAsync(api.commands, call.cmd)) {
                // Always leave the WebView callback before running app code:
                // modal commands can pump UI messages or close their window.
                const job = try Job.prepare(gpa, t, call, page, label, io);
                Transport.post(Job.runSync, job, Job.discard);
                return;
            }
            const worker_pool = pool orelse return settle(t, null, "WorkerPoolNotRunning");
            // The worker gets its own JSON copy below: the job keeps no request.
            const job = try Job.prepare(gpa, t, null, page, label, io);
            errdefer job.finish();
            const worker_json = try std.json.Stringify.valueAlloc(arena, ipc.Request{ .cmd = call.cmd, .args = call.args }, .{});
            try ipc.dispatchAsync(api.commands, worker_pool, gpa, worker_json, worker_pool.io, job, Job.onWorkerDone);
        }

        pub fn settle(t: Transport, result: ?[:0]const u8, err: ?[:0]const u8) void {
            if (t.alive()) t.settle(result, err);
        }

        fn execute(t: Transport, arena: std.mem.Allocator, request: ipc.Request, page: []const u8, label: ?[]const u8, io: ?std.Io) void {
            const result = (if (windows.isWindowCommand(request.cmd))
                windows.dispatch(config.security, local, arena, page, label, request.cmd, request.args)
            else if (ipc.isBuiltinCommand(request.cmd))
                ipc.dispatchBuiltin(config.security, arena, request)
            else
                ipc.dispatchRequest(api.commands, arena, request, io)) catch |err| return settle(t, null, ipc.errorText(err));
            const z = arena.dupeZ(u8, result) catch return settle(t, null, "OutOfMemory");
            settle(t, z, null);
        }

        const Job = struct {
            gpa: std.mem.Allocator,
            transport: Transport,
            arena_state: std.heap.ArenaAllocator,
            request: ipc.Request,
            page: []const u8,
            label: ?[]const u8,
            io: ?std.Io,
            result: ?[:0]const u8 = null,
            err: ?[:0]const u8 = null,

            /// `request` null: an async job, whose worker parses its own copy.
            fn prepare(gpa: std.mem.Allocator, t: Transport, request: ?ipc.Request, page: []const u8, label: ?[]const u8, io: ?std.Io) !*Job {
                const self = try gpa.create(Job);
                errdefer gpa.destroy(self);
                self.* = .{ .gpa = gpa, .transport = t, .arena_state = .init(gpa), .request = undefined, .page = "", .label = null, .io = io };
                errdefer self.arena_state.deinit();
                const a = self.arena_state.allocator();
                self.page = try a.dupe(u8, page);
                if (label) |l| self.label = try a.dupe(u8, l);
                if (request) |r| {
                    const json = try std.json.Stringify.valueAlloc(a, r, .{});
                    self.request = try ipc.parseRequest(a, json);
                } else {
                    self.request = .{ .cmd = "", .args = .null };
                }
                // No fallible work after retaining a thread-affine endpoint.
                try self.transport.retain();
                return self;
            }

            fn runSync(ctx: ?*anyopaque) void {
                const self: *Job = @ptrCast(@alignCast(ctx.?));
                defer self.finish();
                execute(self.transport, self.arena_state.allocator(), self.request, self.page, self.label, self.io);
            }

            fn onWorkerDone(self: *Job, arena: std.heap.ArenaAllocator, result: ?[:0]const u8, err: ?[:0]const u8) void {
                self.arena_state.deinit();
                self.arena_state = arena;
                self.result = result;
                self.err = err;
                Transport.post(reply, self, discard);
            }

            fn reply(ctx: ?*anyopaque) void {
                const self: *Job = @ptrCast(@alignCast(ctx.?));
                defer self.finish();
                Self.settle(self.transport, self.result orelse "null", self.err);
            }

            fn discard(ctx: ?*anyopaque) void {
                const self: *Job = @ptrCast(@alignCast(ctx.?));
                defer self.finish();
                self.transport.discard();
            }

            fn finish(self: *Job) void {
                self.transport.release();
                self.arena_state.deinit();
                self.gpa.destroy(self);
            }
        };
    };
}

/// Snapshot engines under the window lock, evaluate outside it. Re-check both
/// membership and serial before each call: earlier scripts may close windows.
/// Engine and evaluator are injected so tests exercise the production path.
pub fn NativeEngines(comptime Engine: type, comptime enabled: bool, comptime evaluate: fn (*Engine, [:0]const u8) void) type {
    return struct {
        const Self = @This();
        const Entry = struct { engine: *Engine, serial: u64 };
        items: std.ArrayList(Entry) = .empty,
        allocator: std.mem.Allocator = std.heap.smp_allocator,
        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }
        pub fn reserve(self: *Self, gpa: std.mem.Allocator, count: usize) bool {
            if (!enabled) return true;
            if (self.items.capacity == 0) self.allocator = gpa;
            self.items.ensureUnusedCapacity(self.allocator, count) catch return false;
            return true;
        }
        pub fn add(self: *Self, win: *App.Window) void {
            if (!enabled) return;
            const e: *Engine = @ptrCast(@alignCast(win.handle.native orelse return));
            self.items.append(self.allocator, .{ .engine = e, .serial = e.serial }) catch {
                std.log.err("native engine broadcast failed: out of memory", .{});
            };
        }
        pub fn alive(e: *Engine, serial: u64) bool {
            if (!enabled) return false;
            internal.ensureWindowsMutex();
            internal.windows_mutex.lock();
            defer internal.windows_mutex.unlock();
            for (internal.windows_list.items) |win| {
                if (win.handle.native == @as(?*anyopaque, @ptrCast(e))) return e.serial == serial;
            }
            return false;
        }
        pub fn eval(self: *Self, script: [:0]const u8) void {
            self.evalWith(script, evaluate);
        }
        pub fn evalWith(self: *Self, script: [:0]const u8, comptime run: fn (*Engine, [:0]const u8) void) void {
            defer self.deinit();
            for (self.items.items) |item| if (alive(item.engine, item.serial)) run(item.engine, script);
        }
    };
}

const TestCommands = struct {
    pub const async_commands = .{ "background", "background_fail" };
    var calls: usize = 0;
    pub fn ping(_: std.mem.Allocator) u32 {
        calls += 1;
        return 7;
    }
    pub fn background(_: std.mem.Allocator) u32 {
        return 9;
    }
    pub fn background_fail(_: std.mem.Allocator) !u32 {
        return error.TestWorkerFailure;
    }
    pub fn fail(_: std.mem.Allocator) !void {
        return error.TestCommandFailure;
    }
};
const TestState = struct {
    refs: usize = 0,
    replies: usize = 0,
    live: bool = true,
    text: [256]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
    fn answer(self: *TestState) []const u8 {
        return self.text[0..self.len];
    }
};
const TestTransport = struct {
    pub fn warn(comptime _: []const u8, _: anytype) void {}
    state: *TestState,
    const Pending = struct { run: *const fn (?*anyopaque) void, ctx: ?*anyopaque, drop: *const fn (?*anyopaque) void };
    var pending: ?Pending = null;
    pub fn retain(self: *@This()) !void {
        self.state.refs += 1;
    }
    pub fn release(self: @This()) void {
        self.state.refs -= 1;
    }
    pub fn alive(self: @This()) bool {
        return self.state.live;
    }
    pub fn settle(self: @This(), result: ?[:0]const u8, err: ?[:0]const u8) void {
        const text = err orelse result orelse "null";
        self.state.len = text.len;
        @memcpy(self.state.text[0..text.len], text);
        self.state.failed = err != null;
        self.state.replies += 1;
    }
    pub fn discard(self: @This()) void {
        self.settle(null, "AppNotRunning");
    }
    pub fn post(run: *const fn (?*anyopaque) void, ctx: ?*anyopaque, drop: *const fn (?*anyopaque) void) void {
        std.debug.assert(pending == null);
        pending = .{ .run = run, .ctx = ctx, .drop = drop };
    }
    fn drain(cancel: bool) void {
        const task = pending orelse return;
        pending = null;
        if (cancel) task.drop(task.ctx) else task.run(task.ctx);
    }
};
const test_config: App.Config = .{
    .app = .{ .id = "test" },
    .security = .{ .capabilities = &.{.{ .origin = "https://partner.example", .commands = &.{"ping"}, .windows = &.{"main"} }} },
};
const TestDispatch = Dispatcher(.{ .commands = TestCommands }, test_config, .{}, TestTransport);

// Read the token from the script production injects, without exposing the key.
fn testToken(a: std.mem.Allocator) ![]u8 {
    ipc.initToken(std.testing.io);
    const script = try ipc.tokenScript(a, test_config.security, .{});
    defer a.free(script);
    const start = (std.mem.indexOf(u8, script, "return \"") orelse return error.TestUnexpectedResult) + "return \"".len;
    return a.dupe(u8, script[start..][0..64]);
}

test "page dispatch: token, isolation and capability checks precede routing" {
    TestTransport.pending = null;
    TestCommands.calls = 0;
    var state: TestState = .{};
    const t: TestTransport = .{ .state = &state };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try testToken(a);
    const page = security.app_origin ++ "/";
    try TestDispatch.run(t, std.testing.allocator, a, .{ .cmd = "ping" }, "{}", page, "main", 1);
    try std.testing.expectEqualStrings("Forbidden", state.answer());
    try std.testing.expect(TestTransport.pending == null);
    const Isolated = Dispatcher(.{ .commands = TestCommands }, .{ .app = .{ .id = "test", .isolation = .{ .hook = "(c) => c" } } }, .{}, TestTransport);
    try Isolated.run(t, std.testing.allocator, a, .{ .cmd = "ping", .token = token }, "{}", page, "main", 1);
    try std.testing.expectEqualStrings("Forbidden", state.answer());
    try std.testing.expect(TestTransport.pending == null);
    // A valid capability token for the wrong window must be denied.
    const script = try ipc.tokenScript(a, test_config.security, .{});
    const marker = "[\"https://partner.example\", \"";
    const off = (std.mem.indexOf(u8, script, marker) orelse return error.TestUnexpectedResult) + marker.len;
    try TestDispatch.run(t, std.testing.allocator, a, .{ .cmd = "ping", .token = script[off..][0..64] }, "{}", "https://partner.example/", "settings", 1);
    try std.testing.expectEqualStrings("Forbidden", state.answer());
    try std.testing.expectEqual(@as(usize, 0), TestCommands.calls);
    try std.testing.expect(TestTransport.pending == null);
}

test "page dispatch: window routing, queued sync replies, errors and stale drop" {
    TestTransport.pending = null;
    defer TestTransport.drain(true);
    TestCommands.calls = 0;
    var state: TestState = .{};
    const t: TestTransport = .{ .state = &state };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try testToken(a);
    const page = security.app_origin ++ "/";
    for ([_][]const u8{ "ping", "fail", "oriel:window:all", "oriel:window:unknown" }, [_][]const u8{ "7", "TestCommandFailure", "[]", "UnknownCommand" }) |cmd, answer| {
        try TestDispatch.run(t, std.testing.allocator, a, .{ .cmd = cmd, .token = token }, "{}", page, "main", 1);
        try std.testing.expectEqual(@as(usize, 1), state.refs);
        TestTransport.drain(false);
        try std.testing.expectEqualStrings(answer, state.answer());
        try std.testing.expectEqual(@as(usize, 0), state.refs);
    }
    const before = state.replies;
    try TestDispatch.run(t, std.testing.allocator, a, .{ .cmd = "ping", .token = token }, "{}", page, "main", 1);
    state.live = false;
    TestTransport.drain(false);
    try std.testing.expectEqual(before, state.replies);
    try std.testing.expectEqual(@as(usize, 0), state.refs);
}

test "page dispatch: async reply returns through UI transport and drops stale result" {
    for ([_]bool{ true, false }) |live| {
        TestTransport.pending = null;
        defer TestTransport.drain(true);
        var state: TestState = .{ .live = live };
        const t: TestTransport = .{ .state = &state };
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const pool = try @import("ThreadPool.zig").ThreadPool.init(std.testing.allocator, std.testing.io, 1);
        // Joining workers also synchronizes the fake UI queue publication.
        TestDispatch.route(t, std.testing.allocator, arena.allocator(), .{ .cmd = "background" }, security.app_origin ++ "/", "main", pool) catch |err| {
            pool.deinit();
            return err;
        };
        pool.deinit();
        try std.testing.expectEqual(@as(usize, 0), state.replies);
        TestTransport.drain(false);
        try std.testing.expectEqual(@as(usize, if (live) 1 else 0), state.replies);
        if (live) try std.testing.expectEqualStrings("9", state.answer());
        try std.testing.expectEqual(@as(usize, 0), state.refs);
    }
}

fn testPrepareAllocationFailures(a: std.mem.Allocator) !void {
    TestTransport.pending = null;
    var state: TestState = .{};
    defer std.debug.assert(state.refs == 0);
    const job = try TestDispatch.Job.prepare(a, .{ .state = &state }, .{ .cmd = "ping", .args = .{ .string = "owned argument" } }, security.app_origin ++ "/", "main", null);
    defer job.finish();
    try std.testing.expectEqualStrings("owned argument", job.request.args.string);
}

test "page dispatch: every queued-call allocation failure releases ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testPrepareAllocationFailures, .{});
}

test "native broadcasts visit more than 16 windows and recheck serials between evaluations" {
    if (comptime !@hasField(@import("../platform/platform.zig").WindowHandle, "native")) return error.SkipZigTest;
    const Engine = struct { serial: u64 };
    const Probe = struct {
        var visited: usize = 0;
        var replaced: *Engine = undefined;
        fn evaluate(_: *Engine, _: [:0]const u8) void {
            if (visited == 0) {
                internal.windows_mutex.lock();
                _ = internal.windows_list.orderedRemove(1);
                replaced.serial = 999;
                internal.windows_mutex.unlock();
            }
            visited += 1;
        }
    };
    const Snapshot = NativeEngines(Engine, true, Probe.evaluate);
    internal.ensureWindowsMutex();
    defer {
        internal.windows_list.deinit(std.testing.allocator);
        internal.windows_list = .empty;
    }
    var engines: [20]Engine = undefined;
    var wins: [20]App.Window = undefined;
    for (&engines, &wins, 0..) |*e, *w, i| {
        e.* = .{ .serial = i + 1 };
        w.* = .{ .handle = undefined, .label = "test", .options = .{}, .app_id = "test" };
        w.handle.native = e;
        try internal.windows_list.append(std.testing.allocator, w);
    }
    Probe.visited = 0;
    Probe.replaced = &engines[2];
    var snapshot: Snapshot = .{};
    try std.testing.expect(snapshot.reserve(std.heap.smp_allocator, 20));
    for (internal.windows_list.items) |w| snapshot.add(w);
    snapshot.eval("test");
    try std.testing.expectEqual(@as(usize, 18), Probe.visited);
    try std.testing.expect(!Snapshot.alive(&engines[1], 2));
    try std.testing.expect(!Snapshot.alive(&engines[2], 3));
    try std.testing.expect(Snapshot.alive(&engines[2], 999));
}

fn testSnapshotAllocationFailures(a: std.mem.Allocator) !void {
    const Engine = struct { serial: u64 };
    const Snapshot = NativeEngines(Engine, true, struct {
        fn eval(_: *Engine, _: [:0]const u8) void {}
    }.eval);
    var snapshot: Snapshot = .{};
    defer snapshot.deinit();
    if (!snapshot.reserve(a, 20)) return error.OutOfMemory;
    try std.testing.expect(snapshot.items.capacity >= 20);
}

test "native broadcast snapshot releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testSnapshotAllocationFailures, .{});
}

test "page dispatch: rejected submissions and discarded UI calls release the endpoint" {
    TestTransport.pending = null;
    defer TestTransport.drain(true);
    var state: TestState = .{};
    const t: TestTransport = .{ .state = &state };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pool = try @import("ThreadPool.zig").ThreadPool.init(std.testing.allocator, std.testing.io, 1);
    defer pool.deinit();
    pool.mutex.lockUncancelable(pool.io);
    pool.max_queued = 0;
    pool.mutex.unlock(pool.io);
    try std.testing.expectError(error.WorkerPoolBusy, TestDispatch.route(t, std.testing.allocator, arena.allocator(), .{ .cmd = "background" }, security.app_origin ++ "/", "main", pool));
    try std.testing.expectEqual(@as(usize, 0), state.refs);
    pool.stop();
    try std.testing.expectError(error.WorkerPoolNotRunning, TestDispatch.route(t, std.testing.allocator, arena.allocator(), .{ .cmd = "background" }, security.app_origin ++ "/", "main", pool));
    try std.testing.expectEqual(@as(usize, 0), state.refs);
    try TestDispatch.route(t, std.testing.allocator, arena.allocator(), .{ .cmd = "ping" }, security.app_origin ++ "/", "main", null);
    TestTransport.drain(true);
    try std.testing.expectEqualStrings("AppNotRunning", state.answer());
    try std.testing.expectEqual(@as(usize, 0), state.refs);
}

test "page dispatch: worker errors settle through the UI transport" {
    TestTransport.pending = null;
    defer TestTransport.drain(true);
    var state: TestState = .{};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pool = try @import("ThreadPool.zig").ThreadPool.init(std.testing.allocator, std.testing.io, 1);
    TestDispatch.route(.{ .state = &state }, std.testing.allocator, arena.allocator(), .{ .cmd = "background_fail" }, security.app_origin ++ "/", "main", pool) catch |err| {
        pool.deinit();
        return err;
    };
    pool.deinit();
    TestTransport.drain(false);
    try std.testing.expectEqualStrings("TestWorkerFailure", state.answer());
    try std.testing.expect(state.failed);
    try std.testing.expectEqual(@as(usize, 0), state.refs);
}
