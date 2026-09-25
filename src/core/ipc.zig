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
const security = @import("security.zig");
const App = @import("App.zig");

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

/// A command's error message for the page (see `fail`); per thread, because
/// a command and the conversion of its error run on the same thread.
threadlocal var fail_buf: [2048:0]u8 = undefined;
threadlocal var fail_len: ?usize = null;

/// Fail a command with a message for the page: the `invoke()` promise
/// rejects with this text instead of an error name.
///
///     return oriel.ipc.fail("Could not connect to {s}", .{url});
pub fn fail(comptime fmt: []const u8, args: anytype) error{CommandFailed} {
    const text = std.fmt.bufPrint(fail_buf[0 .. fail_buf.len - 1], fmt, args) catch blk: {
        // Too long: keep what fits, marked as cut.
        const cut = fail_buf.len - 4;
        @memcpy(fail_buf[cut..][0..3], "...");
        break :blk fail_buf[0 .. cut + 3];
    };
    fail_buf[text.len] = 0;
    fail_len = text.len;
    return error.CommandFailed;
}

/// What the page sees for a failed command: the `fail` message, or the error name.
pub fn errorText(err: anyerror) [:0]const u8 {
    if (err == error.CommandFailed) if (fail_len) |n| {
        fail_len = null;
        return fail_buf[0..n :0];
    };
    return @errorName(err);
}

test fail {
    const Cmd = struct {
        fn run(ok: bool) !u32 {
            if (!ok) return fail("Could not connect to {s}", .{"http://localhost:11434"});
            return 1;
        }
    };
    const err = Cmd.run(false);
    try std.testing.expectError(error.CommandFailed, err);
    try std.testing.expectEqualStrings("Could not connect to http://localhost:11434", errorText(error.CommandFailed));
    // Used once; other errors keep their names.
    try std.testing.expectEqualStrings("CommandFailed", errorText(error.CommandFailed));
    try std.testing.expectEqualStrings("OutOfMemory", errorText(error.OutOfMemory));
}

/// Check if `cmd` is a framework built-in command.
pub fn isBuiltinCommand(cmd: []const u8) bool {
    return std.mem.eql(u8, cmd, "open_external") or std.mem.eql(u8, cmd, "deep_link:current") or std.mem.eql(u8, cmd, "deep_link:ready") or
        std.mem.eql(u8, cmd, "permissions:query") or std.mem.eql(u8, cmd, "permissions:request") or std.mem.eql(u8, cmd, "permissions:open_settings");
}

/// Dispatch a built-in framework command.
pub fn dispatchBuiltin(sec: security.Security, arena: std.mem.Allocator, request: Request) ![]u8 {
    if (std.mem.eql(u8, request.cmd, "open_external")) {
        const OpenExternalArgs = struct {
            url: []const u8,
        };
        const args = try std.json.parseFromValueLeaky(OpenExternalArgs, arena, request.args, .{
            .ignore_unknown_fields = true,
        });
        try security.validateExternalUrl(sec, args.url);
        const url_z = try arena.dupeZ(u8, args.url);
        App.openExternal(url_z);
        return arena.dupe(u8, "null");
    } else if (std.mem.eql(u8, request.cmd, "deep_link:current")) {
        const build_options = @import("build_options");
        if (build_options.deep_link) {
            const deep_link = @import("../modules/deep_link.zig");
            if (deep_link.current()) |curr| {
                return std.json.Stringify.valueAlloc(arena, curr, .{});
            }
        }
        return arena.dupe(u8, "null");
    } else if (std.mem.startsWith(u8, request.cmd, "permissions:")) {
        const permissions = @import("permissions.zig");
        const PermArgs = struct { name: []const u8 };
        const args = try std.json.parseFromValueLeaky(PermArgs, arena, request.args, .{ .ignore_unknown_fields = true });
        const kind = permissions.parseKind(args.name) orelse return error.UnknownPermission;
        const op = request.cmd["permissions:".len..];
        if (std.mem.eql(u8, op, "query")) return std.json.Stringify.valueAlloc(arena, @tagName(permissions.status(kind)), .{});
        if (std.mem.eql(u8, op, "request")) return std.json.Stringify.valueAlloc(arena, @tagName(permissions.request(kind)), .{});
        return std.json.Stringify.valueAlloc(arena, permissions.openSettings(kind), .{});
    } else if (std.mem.eql(u8, request.cmd, "deep_link:ready")) {
        const build_options = @import("build_options");
        if (build_options.deep_link) {
            const deep_link = @import("../modules/deep_link.zig");
            deep_link.setReady(true);
        }
        return arena.dupe(u8, "null");
    }
    return error.UnknownCommand;
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
                err_z = errorText(err);
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
    const build_options = @import("build_options");
    const deep_link_enabled = if (@hasDecl(build_options, "deep_link")) build_options.deep_link else false;
    return typescriptWithOptions(Commands, Events, deep_link_enabled);
}

pub fn typescriptWithOptions(comptime Commands: type, comptime Events: type, comptime deep_link_enabled: bool) []const u8 {
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
        var has_deep_link = false;
        for (@typeInfo(Events).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "deep-link")) has_deep_link = true;
            const needs_quote = std.mem.indexOfScalar(u8, f.name, '-') != null or std.mem.indexOfScalar(u8, f.name, ' ') != null;
            if (needs_quote) {
                events = events ++ "  \"" ++ f.name ++ "\": " ++ tsType(f.type) ++ ";\n";
            } else {
                events = events ++ "  " ++ f.name ++ ": " ++ tsType(f.type) ++ ";\n";
            }
        }
        if (deep_link_enabled and !has_deep_link) {
            events = events ++ "  \"deep-link\": { url: string };\n";
        }
        var has_permission_changed = false;
        for (@typeInfo(Events).@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, "permission-changed")) has_permission_changed = true;
        }
        if (!has_permission_changed) {
            events = events ++ "  \"permission-changed\": { name: PermissionName; status: PermissionStatus };\n";
        }
        var permission_names: []const u8 = "";
        for (std.enums.values(@import("permissions/common.zig").Kind), 0..) |k, i| {
            permission_names = permission_names ++ (if (i == 0) "" else " | ") ++ "\"" ++ @tagName(k) ++ "\"";
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
        ++ events ++
            \\}
            \\
            \\type Args<K extends keyof Commands> = Commands[K]["args"];
            \\
            \\export interface WindowOptions {
            \\  label: string;
            \\  url?: string;
            \\  title?: string;
            \\  width?: number;
            \\  height?: number;
            \\  min_width?: number;
            \\  min_height?: number;
            \\  max_width?: number;
            \\  max_height?: number;
            \\  resizable?: boolean;
            \\  decorations?: boolean;
            \\  fullscreen?: boolean;
            \\  maximized?: boolean;
            \\}
            \\
            \\export interface WindowHandle {
            \\  readonly label: string;
            \\  close(): Promise<void>;
            \\  show(): Promise<void>;
            \\  hide(): Promise<void>;
            \\  focus(): Promise<void>;
            \\  setTitle(title: string): Promise<void>;
            \\  setSize(width: number, height: number): Promise<void>;
            \\  maximize(maximized?: boolean): Promise<void>;
            \\  fullscreen(fullscreen?: boolean): Promise<void>;
            \\  emit(event: string, payload?: unknown): Promise<void>;
            \\}
            \\
            \\export type PermissionName =
        ++ " " ++ permission_names ++ ";\n" ++
            \\export type PermissionStatus = "granted" | "denied" | "prompt" | "unknown";
            \\
            \\export interface PermissionsApi {
            \\  /** Current status; never prompts. Undeclared permissions are "denied". */
            \\  query(name: PermissionName): Promise<PermissionStatus>;
            \\  /** Ask the user if the OS allows it; resolves with the outcome. */
            \\  request(name: PermissionName): Promise<PermissionStatus>;
            \\  /** Open the OS settings page for the permission; false when there is none. */
            \\  openSettings(name: PermissionName): Promise<boolean>;
            \\}
            \\
            \\export interface DeepLinkApi {
            \\  current(): Promise<string | null>;
            \\}
            \\
            \\export interface WindowApi {
            \\  open(options: WindowOptions): Promise<WindowHandle>;
            \\  current(): WindowHandle;
            \\  get(label: string): Promise<WindowHandle | null>;
            \\  all(): Promise<WindowHandle[]>;
            \\  emitTo(label: string, event: string, payload?: unknown): Promise<void>;
            \\}
            \\
            \\declare global {
            \\  interface Window {
            \\    oriel: {
            \\      invoke(cmd: string, args: unknown): Promise<unknown>;
            \\      listen(event: string, callback: (payload: unknown) => void): () => void;
            \\      window: WindowApi;
            \\      deepLink: DeepLinkApi;
            \\      permissions: PermissionsApi;
            \\      openExternal(url: string): Promise<void>;
            \\    };
            \\  }
            \\  const oriel: Window["oriel"];
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
            \\/** Built-in window management API. */
            \\// Not exported as `window`: that would shadow the global inside this module.
            \\export const orielWindow: WindowApi = (globalThis as any).oriel?.window;
            \\/** Built-in deep link API. */
            \\export const deepLink: DeepLinkApi = (globalThis as any).oriel?.deepLink;
            \\/** Built-in OS permissions API. */
            \\export const permissions: PermissionsApi = (globalThis as any).oriel?.permissions;
            \\/** Global Oriel API object. */
            \\export const oriel: Window["oriel"] = (globalThis as any).oriel;
            \\/** Open a URL in the system's default browser. */
            \\export function openExternal(url: string): Promise<void> {
            \\  return window.oriel.openExternal(url);
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
    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface WindowOptions") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface WindowHandle") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface WindowApi") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "window: WindowApi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export const orielWindow: WindowApi") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export const window") == null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "openExternal(url: string): Promise<void>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export function openExternal(url: string): Promise<void>") != null);
}

test "builtin open_external dispatch and validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const HookHelper = struct {
        var last_uri: ?[]const u8 = null;
        fn hook(uri: [*:0]const u8) void {
            last_uri = std.mem.span(uri);
        }
    };
    App.open_external_hook = &HookHelper.hook;
    defer {
        App.open_external_hook = null;
    }

    const sec: security.Security = .{};

    // Valid url
    const req_ok = try parseRequest(alloc, "{\"cmd\":\"open_external\",\"args\":{\"url\":\"https://example.com/test\"}}");
    const res = try dispatchBuiltin(sec, alloc, req_ok);
    try std.testing.expectEqualStrings("null", res);
    try std.testing.expectEqualStrings("https://example.com/test", HookHelper.last_uri.?);

    // Disallowed scheme: file
    const req_file = try parseRequest(alloc, "{\"cmd\":\"open_external\",\"args\":{\"url\":\"file:///etc/passwd\"}}");
    try std.testing.expectError(error.DisallowedScheme, dispatchBuiltin(sec, alloc, req_file));

    // Disallowed scheme: javascript
    const req_js = try parseRequest(alloc, "{\"cmd\":\"open_external\",\"args\":{\"url\":\"javascript:alert(1)\"}}");
    try std.testing.expectError(error.DisallowedScheme, dispatchBuiltin(sec, alloc, req_js));

    // Disallowed scheme: data
    const req_data = try parseRequest(alloc, "{\"cmd\":\"open_external\",\"args\":{\"url\":\"data:text/html,test\"}}");
    try std.testing.expectError(error.DisallowedScheme, dispatchBuiltin(sec, alloc, req_data));

    // Unknown builtin command
    const req_unknown = try parseRequest(alloc, "{\"cmd\":\"something_else\",\"args\":null}");
    try std.testing.expectError(error.UnknownCommand, dispatchBuiltin(sec, alloc, req_unknown));

    try std.testing.expect(isBuiltinCommand("open_external"));
    try std.testing.expect(!isBuiltinCommand("greet"));
}

test "typescript generation with deep_link" {
    const Commands = struct {
        pub fn greet(_: std.mem.Allocator, _: struct { name: []const u8 }) ![]const u8 {
            return "hello";
        }
    };
    const Events = struct { notes_changed: []const u8 };

    const ts = comptime typescriptWithOptions(Commands, Events, true);
    try std.testing.expect(std.mem.indexOf(u8, ts, "\"deep-link\": { url: string };") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export interface DeepLinkApi") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "current(): Promise<string | null>;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "deepLink: DeepLinkApi;") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export const deepLink: DeepLinkApi") != null);
    try std.testing.expect(std.mem.indexOf(u8, ts, "export const oriel: Window[\"oriel\"]") != null);

    const ts_disabled = comptime typescriptWithOptions(Commands, Events, false);
    try std.testing.expect(std.mem.indexOf(u8, ts_disabled, "\"deep-link\": { url: string };") == null);
}
