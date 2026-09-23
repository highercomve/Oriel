//! JS -> Zig command dispatch.
//!
//! Commands are the `pub fn` declarations of a plain struct:
//!
//!     const Commands = struct {
//!         pub fn ping(gpa: Allocator) []const u8 { ... }
//!         pub fn greet(gpa: Allocator, args: struct { name: []const u8 }) ![]const u8 { ... }
//!         pub fn fetch(gpa: Allocator, io: std.Io, args: struct { url: []const u8 }) ![]const u8 { ... }
//!     };
//!
//! The frontend calls `oriel.invoke("greet", { name: "Ada" })`. Arguments are
//! parsed from JSON into the argument struct type and the result is
//! serialized back to JSON, all driven by `comptime` reflection.
//!
//! Commands can optionally run asynchronously off the main thread by listing them
//! in `pub const async_commands = .{ "cmd1", ... };`.
//! Note on cancellation: command cancellation is currently out of scope.

const std = @import("std");
pub const ThreadPool = @import("ThreadPool.zig").ThreadPool;

pub const Request = struct {
    cmd: []const u8,
    args: std.json.Value = .null,
};

/// Check if `cmd` is configured to run asynchronously on the worker pool.
pub fn isAsync(comptime Commands: type, cmd: []const u8) bool {
    if (!@hasDecl(Commands, "async_commands")) return false;
    const list = @field(Commands, "async_commands");
    inline for (list) |item| {
        if (std.mem.eql(u8, item, cmd)) return true;
    }
    return false;
}

/// Dispatch one JSON request (`{"cmd": ..., "args": ...}`) to `Commands` and
/// return the JSON-encoded result. `arena` owns everything allocated.
pub fn dispatch(comptime Commands: type, arena: std.mem.Allocator, request_json: []const u8, io: ?std.Io) ![]u8 {
    return dispatchRequest(Commands, arena, try parseRequest(arena, request_json), io);
}

pub fn parseRequest(arena: std.mem.Allocator, request_json: []const u8) !Request {
    return std.json.parseFromSliceLeaky(Request, arena, request_json, .{});
}

/// Dispatch an already-parsed request (e.g. after a permission check).
pub fn dispatchRequest(comptime Commands: type, arena: std.mem.Allocator, request: Request, io: ?std.Io) ![]u8 {
    inline for (@typeInfo(Commands).@"struct".decls) |decl| {
        const field = @field(Commands, decl.name);
        if (@typeInfo(@TypeOf(field)) == .@"fn" and std.mem.eql(u8, decl.name, request.cmd)) {
            const result = try call(field, arena, io, request.args);
            if (@TypeOf(result) == void) return arena.dupe(u8, "null");
            return std.json.Stringify.valueAlloc(arena, result, .{});
        }
    }
    return error.UnknownCommand;
}

fn call(comptime f: anytype, arena: std.mem.Allocator, io: ?std.Io, args: std.json.Value) !ReturnPayload(@TypeOf(f)) {
    const F = @TypeOf(f);
    const params = @typeInfo(F).@"fn".params;
    var call_args: std.meta.ArgsTuple(F) = undefined;
    inline for (params, 0..) |p, i| {
        const T = p.type orelse @compileError("command parameters must have concrete types");
        if (T == std.mem.Allocator) {
            call_args[i] = arena;
        } else if (T == std.Io) {
            call_args[i] = io orelse return error.IoNotProvided;
        } else {
            call_args[i] = try std.json.parseFromValueLeaky(T, arena, args, .{
                .ignore_unknown_fields = true,
            });
        }
    }
    const raw = @call(.auto, f, call_args);
    return switch (@typeInfo(@TypeOf(raw))) {
        .error_union => try raw,
        else => raw,
    };
}

/// Asynchronously dispatch a command onto `pool`.
/// A dedicated `ArenaAllocator` is created for the command.
/// Once execution completes on the worker thread, `on_done` is called with the
/// `arena_state`, the null-terminated JSON result or error name.
pub fn dispatchAsync(
    comptime Commands: type,
    pool: *ThreadPool,
    gpa: std.mem.Allocator,
    request_json: []const u8,
    io: ?std.Io,
    context: anytype,
    comptime on_done: fn (@TypeOf(context), arena_state: std.heap.ArenaAllocator, result_json: ?[:0]const u8, err_name: ?[:0]const u8) void,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const req_copy = try arena.dupe(u8, request_json);
    const req = try parseRequest(arena, req_copy);

    const Job = struct {
        task: ThreadPool.Task,
        arena_state: std.heap.ArenaAllocator,
        request: Request,
        io: ?std.Io,
        callback_context: @TypeOf(context),

        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            const alloc = self.arena_state.allocator();
            var res_z: ?[:0]const u8 = null;
            var err_z: ?[:0]const u8 = null;

            if (dispatchRequest(Commands, alloc, self.request, self.io)) |json| {
                res_z = alloc.dupeZ(u8, json) catch null;
                if (res_z == null) err_z = "OutOfMemory";
            } else |err| {
                err_z = @errorName(err);
            }

            on_done(self.callback_context, self.arena_state, res_z, err_z);
        }
    };

    const job = try arena.create(Job);
    job.* = .{
        .task = .{ .run_fn = &Job.run },
        .arena_state = arena_state,
        .request = req,
        .io = io,
        .callback_context = context,
    };
    pool.post(&job.task);
}

fn commandArgsType(comptime F: type) ?type {
    const params = @typeInfo(F).@"fn".params;
    var found: ?type = null;
    for (params) |p| {
        const T = p.type orelse continue;
        if (T == std.mem.Allocator or T == std.Io) continue;
        if (found != null) @compileError("commands can have at most one arguments type");
        found = T;
    }
    return found;
}

/// TypeScript module for the frontend: `Commands` and `Events` interfaces
/// derived from the Zig structs, plus typed `invoke()` and `listen()`.
pub fn typescript(comptime Commands: type, comptime Events: type) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var commands: []const u8 = "";
        for (@typeInfo(Commands).@"struct".decls) |decl| {
            const field = @field(Commands, decl.name);
            const F = @TypeOf(field);
            if (@typeInfo(F) != .@"fn") continue;
            const maybe_args = commandArgsType(F);
            const args = if (maybe_args) |A| tsType(A) else "null";
            commands = commands ++ "  " ++ decl.name ++ ": { args: " ++ args ++ "; result: " ++ tsType(ReturnPayload(F)) ++ " };\n";
        }
        var events: []const u8 = "";
        for (@typeInfo(Events).@"struct".fields) |f| {
            events = events ++ "  " ++ f.name ++ ": " ++ tsType(f.type) ++ ";\n";
        }
        return 
        \\// Generated by oriel from the Zig API. Do not edit.
        \\
        \\export interface Commands {
        \\
        ++ commands ++
            \\}
            \\
            \\export interface Events {
            \\
            \\// Generated by oriel from the Zig API. Do not edit.
            \\
        ++ events ++
            \\}
            \\
            \\type Args<K extends keyof Commands> = Commands[K]["args"];
            \\
            \\declare global {
            \\  interface Window {
            \\    oriel: {
            \\      invoke(cmd: string, args: unknown): Promise<unknown>;
            \\      listen(event: string, callback: (payload: unknown) => void): () => void;
            \\    };
            \\  }
            \\}
            \\
            \\/** Call a Zig command. Rejects with the Zig error name on failure. */
            \\export function invoke<K extends keyof Commands>(
            \\  cmd: K,
            \\  ...args: Args<K> extends null ? [] : [Args<K>]
            \\): Promise<Commands[K]["result"]> {
            \\  return window.oriel.invoke(cmd, args[0] ?? null) as Promise<Commands[K]["result"]>;
            \\}
            \\
            \\/** Subscribe to an event emitted from Zig. Returns an unsubscribe function. */
            \\export function listen<K extends keyof Events>(event: K, callback: (payload: Events[K]) => void): () => void {
            \\  return window.oriel.listen(event, callback as (payload: unknown) => void);
            \\}
            \\
        ;
    }
}

fn tsType(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "boolean",
        .int, .float, .comptime_int, .comptime_float => "number",
        .void, .null => "null",
        .optional => |o| tsType(o.child) ++ " | null",
        .pointer => |p| switch (p.size) {
            .slice => if (p.child == u8) "string" else "(" ++ tsType(p.child) ++ ")[]",
            .one => switch (@typeInfo(p.child)) {
                .array => |a| if (a.child == u8) "string" else "(" ++ tsType(a.child) ++ ")[]",
                else => tsType(p.child),
            },
            else => "unknown",
        },
        .array => |a| if (a.child == u8) "string" else "(" ++ tsType(a.child) ++ ")[]",
        .@"enum" => |e| blk: {
            var out: []const u8 = "";
            for (e.fields, 0..) |f, i| out = out ++ (if (i == 0) "" else " | ") ++ "\"" ++ f.name ++ "\"";
            break :blk out;
        },
        .@"struct" => |s| blk: {
            var out: []const u8 = "{ ";
            for (s.fields) |f| {
                const optional = f.default_value_ptr != null;
                out = out ++ f.name ++ (if (optional) "?" else "") ++ ": " ++ tsType(f.type) ++ "; ";
            }
            break :blk out ++ "}";
        },
        else => "unknown",
    };
}

fn ReturnPayload(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.payload,
        else => R,
    };
}

test "dispatch with and without args" {
    const Commands = struct {
        pub fn ping(_: std.mem.Allocator) []const u8 {
            return "pong";
        }
        pub fn add(_: std.mem.Allocator, args: struct { a: i32, b: i32 }) !i32 {
            return args.a + args.b;
        }
        const not_a_command = 42;
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("\"pong\"", try dispatch(Commands, arena, "{\"cmd\":\"ping\"}", null));
    try std.testing.expectEqualStrings("5", try dispatch(Commands, arena, "{\"cmd\":\"add\",\"args\":{\"a\":2,\"b\":3}}", null));
    try std.testing.expectError(error.UnknownCommand, dispatch(Commands, arena, "{\"cmd\":\"nope\"}", null));
}

test "dispatch with std.Io" {
    const Commands = struct {
        pub fn with_io(_: std.mem.Allocator, io: std.Io, args: struct { msg: []const u8 }) ![]const u8 {
            _ = io;
            return args.msg;
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const io = std.testing.io;
    const res = try dispatch(Commands, arena, "{\"cmd\":\"with_io\",\"args\":{\"msg\":\"hello\"}}", io);
    try std.testing.expectEqualStrings("\"hello\"", res);
}

test "async dispatch runs off-thread and replies once" {
    const io = std.testing.io;
    const pool = try ThreadPool.init(std.testing.allocator, io, 2);
    defer pool.deinit();

    const main_thread_id = std.Thread.getCurrentId();

    const Commands = struct {
        pub const async_commands = .{ "get_worker_id", "slow_add" };

        pub fn get_worker_id(_: std.mem.Allocator) u64 {
            return std.Thread.getCurrentId();
        }

        pub fn slow_add(_: std.mem.Allocator, _: std.Io, args: struct { a: i32, b: i32 }) !i32 {
            return args.a + args.b;
        }
    };

    try std.testing.expect(isAsync(Commands, "get_worker_id"));
    try std.testing.expect(isAsync(Commands, "slow_add"));
    try std.testing.expect(!isAsync(Commands, "sync_cmd"));

    const TestCallback = struct {
        caller_thread_id: u64,
        worker_thread_id: u64 = 0,
        result_json: ?[]u8 = null,
        err_name: ?[:0]const u8 = null,
        call_count: usize = 0,
        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        done: bool = false,

        fn onDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err: ?[:0]const u8) void {
            var a = arena_state;
            defer a.deinit();
            self.mutex.lockUncancelable(std.testing.io);
            defer self.mutex.unlock(std.testing.io);
            self.call_count += 1;
            if (res) |r| {
                self.result_json = std.testing.allocator.dupe(u8, r) catch null;
            }
            self.err_name = err;
            self.done = true;
            self.cond.signal(std.testing.io);
        }
    };

    var cb = TestCallback{ .caller_thread_id = main_thread_id };
    try dispatchAsync(Commands, pool, std.testing.allocator, "{\"cmd\":\"get_worker_id\"}", io, &cb, TestCallback.onDone);

    cb.mutex.lockUncancelable(io);
    while (!cb.done) cb.cond.waitUncancelable(io, &cb.mutex);
    cb.mutex.unlock(io);

    try std.testing.expectEqual(@as(usize, 1), cb.call_count);
    const worker_id = try std.fmt.parseInt(u64, cb.result_json.?, 10);
    try std.testing.expect(worker_id != main_thread_id);
    std.testing.allocator.free(cb.result_json.?);
}

test "typescript generation" {
    const Commands = struct {
        pub fn ping(_: std.mem.Allocator) []const u8 {
            return "pong";
        }
        pub fn add(_: std.mem.Allocator, _: struct { a: i32, label: ?[]const u8 = null }) !struct { sum: i64, tags: []const []const u8 } {
            return undefined;
        }
        pub fn slow_task(_: std.mem.Allocator, _: std.Io) !void {}
    };
    const Events = struct { note_added: struct { id: i64 }, quit: void };
    const ts = comptime typescript(Commands, Events);
    try std.testing.expect(std.mem.indexOf(u8, ts, "  ping: { args: null; result: string };\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "  add: { args: { a: number; label?: string | null; }; result: { sum: number; tags: (string)[]; } };\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "  slow_task: { args: null; result: null };\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "  note_added: { id: number; };\n  quit: null;\n") != null);
}
