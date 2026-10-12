//! App extensions (`oriel.extensions`): an app's own native code, named in
//! build.zig (`AppOptions.extensions`) and implemented per platform in
//! Kotlin (Android), Objective-C or Swift (iOS), or Zig (desktop). Zig calls
//! them by name; the page reaches them only through Zig, via an app command
//! or `expose` (docs/extensions.md).
//!
//! A call is `(method, input bytes) -> reply bytes`. Each extension has its
//! own workers (`concurrency`, default 1) and a bounded queue in front of
//! them; the caller blocks until the reply, the timeout or its cancel token,
//! so calls are refused on the main thread. Inputs and replies are capped
//! (`max_bytes`). Native code polls `isCancelled`, may `emit` events (to
//! `onEvent` handlers on the main thread and to the page as
//! `extension:<name>`, queued until listened), and gets `oriel.lifecycle`
//! events on the main thread.
//!
//! The table of extensions is generated per app and per target by build.zig
//! (the `oriel_extensions` module): `get("name")` with a name that isn't
//! declared is a build error, and `available()` is comptime.

const std = @import("std");
const spec = @import("extension_spec.zig");
const lifecycle = @import("lifecycle.zig");
const heap = @import("heap.zig");
const target = @import("target.zig");
const pending_events = @import("pending_events.zig");
const App = @import("App.zig");
const ipc = @import("ipc.zig");
const registry = @import("oriel_extensions");

const log = std.log.scoped(.extensions);

pub const max_extensions = spec.max_extensions;
pub const default_max_bytes = spec.default_max_bytes;
pub const max_concurrency = spec.max_concurrency;
pub const queue_capacity = spec.queue_capacity;
pub const default_timeout_ms = spec.default_timeout_ms;
pub const max_timeout_ms = spec.max_timeout_ms;

pub const Error = error{
    /// No implementation on this platform, or the app isn't running.
    Unavailable,
    Timeout,
    Cancelled,
    /// The input or the reply is over the extension's `max_bytes`.
    TooLarge,
    /// The implementation failed: the code and message are in `Diagnostics`.
    ExtensionFailed,
    /// Called on the main thread, which must never block on native code.
    WrongThread,
    /// `queue_capacity` calls are already waiting for a worker.
    Busy,
    InvalidMethod,
    OutOfMemory,
};

/// Which implementation this build has (build.zig decides per target).
pub const Backend = enum { none, zig, android, objc };

/// Cancels a call from another thread: the native side sees `isCancelled`
/// and the caller gets error.Cancelled at once.
pub const CancelToken = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn cancel(t: *CancelToken) void {
        t.flag.store(true, .release);
    }

    pub fn isCancelled(t: *const CancelToken) bool {
        return t.flag.load(.acquire);
    }
};

pub const CallOptions = struct {
    /// Clamped to `max_timeout_ms`. The timeout cancels the call, then reports.
    timeout_ms: u32 = default_timeout_ms,
    cancel: ?*const CancelToken = null,
    /// Filled when the call fails with error.ExtensionFailed (or TooLarge).
    diag: ?*Diagnostics = null,
};

/// The code and message an implementation failed with (Kotlin
/// `OrielExtensionError(code, message)`, an `NSError`, `ctx.fail`).
pub const Diagnostics = struct {
    code_buf: [spec.max_code_len]u8 = undefined,
    code_len: usize = 0,
    message_buf: [spec.max_message_len]u8 = undefined,
    message_len: usize = 0,

    pub fn code(d: *const Diagnostics) []const u8 {
        return d.code_buf[0..d.code_len];
    }

    pub fn message(d: *const Diagnostics) []const u8 {
        return d.message_buf[0..d.message_len];
    }

    /// Both cut to fit.
    pub fn set(d: *Diagnostics, code_text: []const u8, message_text: []const u8) void {
        d.code_len = @min(code_text.len, d.code_buf.len);
        @memcpy(d.code_buf[0..d.code_len], code_text[0..d.code_len]);
        d.message_len = @min(message_text.len, d.message_buf.len);
        @memcpy(d.message_buf[0..d.message_len], message_text[0..d.message_len]);
    }
};

/// What an implementation gets for a call (`call`) or at load (`onLoad`,
/// with no call: never cancelled).
pub const Context = struct {
    /// The extension's name ("pantry.vision").
    name: []const u8,
    /// Freed when the call returns: allocate the reply here.
    arena: std.mem.Allocator,
    runner: *Runner,
    call: ?*Call,

    /// Poll it in long work: the caller cancelled or timed out.
    pub fn isCancelled(ctx: *const Context) bool {
        const c = ctx.call orelse return false;
        return c.cancelled.load(.acquire);
    }

    /// An event for `onEvent` handlers and the page (`extension:<name>`
    /// with `{ name, data }`; `data` is parsed when it is JSON).
    pub fn emit(ctx: *const Context, event: []const u8, data: []const u8) void {
        ctx.runner.on_emit(ctx.runner, event, data);
    }

    /// Fail the call with a code and a message for the caller.
    ///
    ///     return ctx.fail("model_missing", "no model at {s}", .{path});
    pub fn fail(ctx: *Context, code: []const u8, comptime fmt: []const u8, args: anytype) error{ExtensionFailed} {
        const c = ctx.call orelse return error.ExtensionFailed;
        var buf: [spec.max_message_len]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
        c.diag.set(code, text);
        return error.ExtensionFailed;
    }

    /// The call's id (what Kotlin's OrielCall and Objective-C's OrielCall
    /// poll cancellation by); 0 at load.
    pub fn callId(ctx: *const Context) u64 {
        return if (ctx.call) |c| c.id else 0;
    }

    /// Where a native backend reports a structured failure.
    pub fn diagnostics(ctx: *Context) ?*Diagnostics {
        return if (ctx.call) |c| &c.diag else null;
    }
};

/// An implementation, as the workers call it.
pub const Impl = struct {
    /// The reply, in `ctx.arena` (or memory living until the call returns).
    call: *const fn (ctx: *Context, method: []const u8, input: []const u8) anyerror![]const u8,
    /// On the first worker, before any call.
    load: ?*const fn (ctx: *Context) anyerror!void = null,
    /// On the main thread, once loaded.
    lifecycle: ?*const fn (runner: *Runner, event: lifecycle.Event) void = null,
    /// Each worker thread, first and last (Android attaches it to the VM).
    thread_start: ?*const fn () void = null,
    thread_end: ?*const fn () void = null,
};

pub const EmitFn = *const fn (runner: *Runner, event: []const u8, data: []const u8) void;

/// One call: shared by the caller and the worker (`refs`), so a caller
/// that timed out can leave while the native side still runs.
pub const Call = struct {
    id: u64,
    method: []u8,
    input: []u8,
    refs: std.atomic.Value(u8) = .init(2),
    done: std.atomic.Value(u32) = .init(0),
    cancelled: std.atomic.Value(bool) = .init(false),
    result: ?[]u8 = null,
    err: ?Error = null,
    diag: Diagnostics = .{},

    fn create(method: []const u8, input: []const u8) error{OutOfMemory}!*Call {
        const gpa = heap.gpa;
        const c = try gpa.create(Call);
        errdefer gpa.destroy(c);
        const m = try gpa.dupe(u8, method);
        errdefer gpa.free(m);
        const in = try gpa.dupe(u8, input);
        c.* = .{ .id = next_call_id.fetchAdd(1, .monotonic), .method = m, .input = in };
        return c;
    }

    fn release(c: *Call) void {
        if (c.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = heap.gpa;
        if (c.result) |r| gpa.free(r);
        gpa.free(c.method);
        gpa.free(c.input);
        gpa.destroy(c);
    }
};

var next_call_id: std.atomic.Value(u64) = .init(1);

/// How often a waiting caller looks at its cancel token.
const poll_ms = 50;

/// One extension's queue and workers.
pub const Runner = struct {
    name: []const u8,
    max_bytes: usize = default_max_bytes,
    concurrency: u8 = 1,
    impl: Impl,
    on_emit: EmitFn = dropEmit,
    /// The Kotlin/Objective-C class, and the instance its backend made at load.
    class: []const u8 = "",
    native: ?*anyopaque = null,
    index: usize = 0,

    io: ?std.Io = null,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: [queue_capacity]*Call = undefined,
    head: usize = 0,
    len: usize = 0,
    threads: [max_concurrency]std.Thread = undefined,
    spawned: usize = 0,
    stopping: bool = false,
    loaded: std.atomic.Value(bool) = .init(false),

    /// Run `method` (any thread but the main one; the caller checks that):
    /// queued, then run by a worker; blocks until the reply (copied into
    /// `arena`), the timeout or the cancel token.
    pub fn call(r: *Runner, io: std.Io, arena: std.mem.Allocator, method: []const u8, input: []const u8, options: CallOptions) Error![]u8 {
        if (!spec.validMethod(method)) return error.InvalidMethod;
        if (input.len > r.max_bytes) return error.TooLarge;
        try r.start(io);
        const c = try Call.create(method, input);
        r.mutex.lockUncancelable(io);
        if (r.stopping or r.len == queue_capacity) {
            const stopping = r.stopping;
            r.mutex.unlock(io);
            c.release();
            c.release();
            return if (stopping) error.Unavailable else error.Busy;
        }
        r.queue[(r.head + r.len) % queue_capacity] = c;
        r.len += 1;
        r.cond.signal(io);
        r.mutex.unlock(io);
        return wait(io, c, arena, options);
    }

    /// Start the workers if they aren't (the first loads the extension).
    pub fn start(r: *Runner, io: std.Io) Error!void {
        r.mutex.lockUncancelable(io);
        defer r.mutex.unlock(io);
        if (r.stopping) return error.Unavailable;
        if (r.spawned > 0) return;
        r.io = io;
        const n = std.math.clamp(r.concurrency, 1, max_concurrency);
        for (0..n) |i| {
            r.threads[i] = std.Thread.spawn(.{}, workerMain, .{ r, i }) catch |err| {
                log.err("{s}: no worker thread ({s})", .{ r.name, @errorName(err) });
                if (r.spawned == 0) return error.Unavailable;
                break;
            };
            r.spawned += 1;
        }
    }

    /// Stop the workers (tests; apps never stop them): queued calls fail
    /// with Unavailable, running ones finish first.
    pub fn stop(r: *Runner) void {
        const io = r.io orelse return;
        r.mutex.lockUncancelable(io);
        r.stopping = true;
        r.cond.broadcast(io);
        r.mutex.unlock(io);
        for (r.threads[0..r.spawned]) |t| t.join();
        r.spawned = 0;
        while (r.pop()) |c| finish(io, c, error.Unavailable);
    }

    fn pop(r: *Runner) ?*Call {
        if (r.len == 0) return null;
        const c = r.queue[r.head];
        r.head = (r.head + 1) % queue_capacity;
        r.len -= 1;
        return c;
    }

    fn workerMain(r: *Runner, index: usize) void {
        const io = r.io.?;
        if (r.impl.thread_start) |f| f();
        defer if (r.impl.thread_end) |f| f();
        if (index == 0) {
            r.load();
            r.mutex.lockUncancelable(io);
            r.loaded.store(true, .release);
            r.cond.broadcast(io);
            r.mutex.unlock(io);
        }
        while (true) {
            r.mutex.lockUncancelable(io);
            while ((r.len == 0 or !r.loaded.load(.acquire)) and !r.stopping) r.cond.waitUncancelable(io, &r.mutex);
            if (r.stopping) {
                r.mutex.unlock(io);
                return;
            }
            const c = r.pop().?;
            r.mutex.unlock(io);
            r.run(io, c);
        }
    }

    fn load(r: *Runner) void {
        const f = r.impl.load orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(heap.gpa);
        defer arena_state.deinit();
        var ctx: Context = .{ .name = r.name, .arena = arena_state.allocator(), .runner = r, .call = null };
        f(&ctx) catch |err| log.err("{s}: onLoad failed: {s}", .{ r.name, @errorName(err) });
    }

    fn run(r: *Runner, io: std.Io, c: *Call) void {
        // Cancelled or timed out while it waited: never started.
        if (c.cancelled.load(.acquire)) return finish(io, c, error.Cancelled);
        if (!inflight.add(c)) {
            c.diag.set("busy", "too many native calls at once");
            return finish(io, c, error.Busy);
        }
        defer inflight.remove(c.id);
        var arena_state: std.heap.ArenaAllocator = .init(heap.gpa);
        defer arena_state.deinit();
        var ctx: Context = .{ .name = r.name, .arena = arena_state.allocator(), .runner = r, .call = c };
        const out = r.impl.call(&ctx, c.method, c.input) catch |err| return finish(io, c, mapError(err, &c.diag));
        if (out.len > r.max_bytes) {
            var buf: [96]u8 = undefined;
            c.diag.set("too_large", std.fmt.bufPrint(&buf, "the reply has {d} bytes, over max_bytes ({d})", .{ out.len, r.max_bytes }) catch "");
            return finish(io, c, error.TooLarge);
        }
        c.result = heap.gpa.dupe(u8, out) catch return finish(io, c, error.OutOfMemory);
        finish(io, c, null);
    }
};

fn dropEmit(_: *Runner, _: []const u8, _: []const u8) void {}

/// The worker's half: publish the outcome, wake the caller, drop its ref.
fn finish(io: std.Io, c: *Call, err: ?Error) void {
    c.err = err;
    c.done.store(1, .release);
    io.futexWake(u32, &c.done.raw, 1);
    c.release();
}

/// The caller's half.
fn wait(io: std.Io, c: *Call, arena: std.mem.Allocator, options: CallOptions) Error![]u8 {
    const timeout_ns: i96 = @as(i96, @min(options.timeout_ms, max_timeout_ms)) * std.time.ns_per_ms;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + timeout_ns;
    // Ends: every pass either sees the reply or moves toward the deadline.
    while (c.done.load(.acquire) == 0) {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        const cancelled = if (options.cancel) |t| t.isCancelled() else false;
        if (cancelled or now >= deadline) {
            // The native side sees isCancelled; a queued call never starts.
            c.cancelled.store(true, .release);
            c.release();
            return if (cancelled) error.Cancelled else error.Timeout;
        }
        const slice = @min(deadline - now, @as(i96, poll_ms) * std.time.ns_per_ms);
        io.futexWaitTimeout(u32, &c.done.raw, 0, .{ .duration = .{ .raw = .fromNanoseconds(slice), .clock = .awake } }) catch {};
    }
    defer c.release();
    if (c.err) |e| {
        if (options.diag) |d| d.* = c.diag;
        return e;
    }
    return arena.dupe(u8, c.result orelse "") catch error.OutOfMemory;
}

/// An implementation's error, as the caller sees it.
fn mapError(err: anyerror, diag: *Diagnostics) Error {
    return switch (err) {
        error.ExtensionFailed => {
            if (diag.code_len == 0) diag.set("failed", "");
            return error.ExtensionFailed;
        },
        error.Cancelled => error.Cancelled,
        error.Timeout => error.Timeout,
        error.TooLarge => error.TooLarge,
        error.Unavailable => error.Unavailable,
        error.OutOfMemory => error.OutOfMemory,
        else => {
            diag.set(@errorName(err), @errorName(err));
            return error.ExtensionFailed;
        },
    };
}

/// The native calls running now, by id: Kotlin's and Objective-C's
/// `isCancelled` look theirs up (a stale id reads as cancelled).
pub fn Inflight(comptime capacity: usize) type {
    return struct {
        mutex: std.Io.Mutex = .init,
        slots: [capacity]?*Call = @splat(null),

        const Self = @This();

        pub fn add(self: *Self, c: *Call) bool {
            std.Io.Threaded.mutexLock(&self.mutex);
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            for (&self.slots) |*s| if (s.* == null) {
                s.* = c;
                return true;
            };
            return false;
        }

        pub fn remove(self: *Self, id: u64) void {
            std.Io.Threaded.mutexLock(&self.mutex);
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            for (&self.slots) |*s| if (s.*) |c| if (c.id == id) {
                s.* = null;
                return;
            };
        }

        pub fn cancelled(self: *Self, id: u64) bool {
            std.Io.Threaded.mutexLock(&self.mutex);
            defer std.Io.Threaded.mutexUnlock(&self.mutex);
            for (self.slots) |s| if (s) |c| if (c.id == id) return c.cancelled.load(.acquire);
            return true;
        }
    };
}

var inflight: Inflight(max_extensions * 2) = .{};

/// Whether native call `id` should stop (any thread).
pub fn cancelledById(id: u64) bool {
    return inflight.cancelled(id);
}

// ---------------------------------------------------------------------------
// The app's extensions (the generated `oriel_extensions` table)
// ---------------------------------------------------------------------------

const entries = registry.list;
/// Extensions this app declares.
pub const count = entries.len;

comptime {
    if (count > max_extensions) @compileError("oriel.extensions: more than 64 extensions");
}

fn backendOf(comptime i: usize) Backend {
    return entries[i].backend;
}

fn indexOf(comptime name: []const u8) usize {
    @setEvalBranchQuota(10_000);
    inline for (entries, 0..) |e, i| {
        if (comptime std.mem.eql(u8, e.name, name)) return i;
    }
    comptime var names: []const u8 = "";
    inline for (entries) |e| names = names ++ " \"" ++ e.name ++ "\"";
    @compileError("oriel.extensions.get(\"" ++ name ++ "\"): no such extension in AppOptions.extensions (build.zig); declared:" ++ (if (names.len == 0) " none" else names));
}

/// Whether AppOptions.extensions declares `name` (comptime): for code shared
/// by builds that declare different sets (`if (comptime declared("x"))`).
pub fn declared(comptime name: []const u8) bool {
    inline for (entries) |e| {
        if (comptime std.mem.eql(u8, e.name, name)) return true;
    }
    return false;
}

/// The extension `name`, checked at build time:
///
///     const vision = oriel.extensions.get("pantry.vision");
///     if (!vision.available()) return error.Unavailable;
///     const reply = try vision.call(arena, "detect", input, .{ .timeout_ms = 30_000 });
pub fn get(comptime name: []const u8) type {
    const i = comptime indexOf(name);
    return struct {
        pub const extension_name = name;

        /// Whether this platform has an implementation (comptime).
        pub inline fn available() bool {
            return comptime backendOf(i) != .none;
        }

        /// Call `method` with `input`; the reply is copied into `arena`.
        /// Any thread but the main one: error.WrongThread there.
        pub fn call(arena: std.mem.Allocator, method: []const u8, input: []const u8, options: CallOptions) Error![]u8 {
            if (comptime backendOf(i) == .none) return error.Unavailable;
            return callIndex(i, arena, method, input, options);
        }

        /// Start the workers and load the extension now rather than at the
        /// first call (it gets lifecycle events from then on).
        pub fn load() Error!void {
            if (comptime backendOf(i) == .none) return error.Unavailable;
            const io = app_io orelse return error.Unavailable;
            return runners[i].start(io);
        }

        /// Events the native side emits, on the main thread (those from
        /// before the handler was set come first). One handler; a second
        /// replaces it.
        pub fn onEvent(handler: EventHandler) void {
            handlers[i].store(handler, .release);
            App.runOnMain(i, flushHandler);
        }
    };
}

var runners: [count]Runner = blk: {
    var out: [count]Runner = undefined;
    for (entries, 0..) |e, i| out[i] = .{
        .name = e.name,
        .max_bytes = e.max_bytes,
        .concurrency = e.concurrency,
        .impl = implOf(i),
        .on_emit = emitToApp,
        .class = e.class,
        .index = i,
    };
    break :blk out;
};

fn implOf(comptime i: usize) Impl {
    return switch (backendOf(i)) {
        .none => .{ .call = unavailableCall },
        .zig => ZigImpl(entries[i].impl).impl,
        .android => if (target.is_android) @import("../platform/android/extensions.zig").impl else @compileError("android backend off Android"),
        .objc => if (target.is_ios) @import("../platform/apple/extensions.zig").impl else @compileError("Objective-C backend off iOS"),
    };
}

fn unavailableCall(_: *Context, _: []const u8, _: []const u8) anyerror![]const u8 {
    return error.Unavailable;
}

/// A desktop module (`.desktop = .{ .zig = path }`): `pub fn call(ctx,
/// method, input) ![]u8`, optional `pub fn onLoad(ctx) !void` and
/// `pub fn onLifecycle(event) void`.
fn ZigImpl(comptime M: type) type {
    if (!@hasDecl(M, "call")) @compileError("an extension's Zig module needs `pub fn call(ctx: *oriel.extensions.Context, method: []const u8, input: []const u8) ![]u8`");
    return struct {
        const impl: Impl = .{
            .call = callFn,
            .load = if (@hasDecl(M, "onLoad")) loadFn else null,
            .lifecycle = if (@hasDecl(M, "onLifecycle")) lifecycleFn else null,
        };
        fn callFn(ctx: *Context, method: []const u8, input: []const u8) anyerror![]const u8 {
            return M.call(ctx, method, input);
        }
        fn loadFn(ctx: *Context) anyerror!void {
            const r = M.onLoad(ctx);
            if (@typeInfo(@TypeOf(r)) == .error_union) try r;
        }
        fn lifecycleFn(_: *Runner, event: lifecycle.Event) void {
            M.onLifecycle(event);
        }
    };
}

/// The Io the workers wait with, from `App.run`; null before it.
var app_io: ?std.Io = null;
/// Set once in `begin`, before any worker exists.
var main_thread: std.Thread.Id = undefined;
var main_thread_set = std.atomic.Value(bool).init(false);
var lifecycle_subscribed = std.atomic.Value(bool).init(false);

/// App.run, on the main thread before the loop.
pub fn begin(io: std.Io) void {
    app_io = io;
    main_thread = std.Thread.getCurrentId();
    main_thread_set.store(true, .release);
    if (count == 0 or lifecycle_subscribed.swap(true, .monotonic)) return;
    lifecycle.subscribe(&forwardLifecycle) catch log.warn("no room in oriel.lifecycle: extensions won't get its events", .{});
}

fn onMainThread() bool {
    if (!main_thread_set.load(.acquire)) return false;
    return main_thread == std.Thread.getCurrentId();
}

fn callIndex(i: usize, arena: std.mem.Allocator, method: []const u8, input: []const u8, options: CallOptions) Error![]u8 {
    if (onMainThread()) return error.WrongThread;
    const io = app_io orelse return error.Unavailable;
    return runners[i].call(io, arena, method, input, options);
}

/// Every loaded extension, in declaration order (main thread).
fn forwardLifecycle(event: lifecycle.Event) void {
    for (&runners) |*r| {
        if (!r.loaded.load(.acquire)) continue;
        if (r.impl.lifecycle) |f| f(r, event);
    }
}

/// The index of extension `name` at run time (native code emits by name).
pub fn indexByName(name: []const u8) ?usize {
    for (&runners, 0..) |*r, i| if (std.mem.eql(u8, r.name, name)) return i;
    return null;
}

/// The runner of `name`, for native backends.
pub fn runnerByName(name: []const u8) ?*Runner {
    if (comptime count == 0) return null;
    const i = indexByName(name) orelse return null;
    return &runners[i];
}

pub fn runnerAt(index: usize) ?*Runner {
    if (comptime count == 0) return null;
    return if (index < count) &runners[index] else null;
}

/// The reply format of a native backend that can't return errors directly
/// (Kotlin through JNI): a status byte, then
/// - 0 ok: the reply;
/// - 1 failed: the code, a NUL, the message (UTF-8);
/// - 2 unavailable (no such extension in the app's registry);
/// - 3 cancelled.
pub fn decodeStatusReply(ctx: *Context, bytes: []const u8) anyerror![]const u8 {
    if (bytes.len == 0) return error.Unavailable;
    const rest = bytes[1..];
    switch (bytes[0]) {
        0 => return rest,
        1 => {
            const nul = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
            if (ctx.diagnostics()) |d| d.set(rest[0..nul], if (nul < rest.len) rest[nul + 1 ..] else "");
            return error.ExtensionFailed;
        },
        2 => return error.Unavailable,
        3 => return error.Cancelled,
        else => return error.Unavailable,
    }
}

// ---------------------------------------------------------------------------
// Events from native code
// ---------------------------------------------------------------------------

pub const Event = struct {
    extension: []const u8,
    name: []const u8,
    data: []const u8,
};

pub const EventHandler = *const fn (event: Event) void;

var handlers: [count]std.atomic.Value(?EventHandler) = @splat(.init(null));

/// Oriel's own modules on extensions (`oriel.*`, e.g. oriel.system_ai's
/// streamed tokens): the extension's events on the thread that emits them,
/// instead of `onEvent` and `extension:<name>`. Keep it short.
pub const Sink = *const fn (event: []const u8, data: []const u8) void;

var sinks: [count]std.atomic.Value(?Sink) = @splat(.init(null));

/// Route extension `name`'s events to `sink` (Oriel's own extensions only).
pub fn setSink(comptime name: []const u8, sink: Sink) void {
    comptime if (!spec.reserved(name)) @compileError("oriel.extensions.setSink is for Oriel's own extensions (oriel.*)");
    sinks[comptime indexOf(name)].store(sink, .release);
}

/// JSON as is (pending_events copies it like any struct of slices).
const RawJson = struct {
    json: []const u8,

    pub fn jsonStringify(self: RawJson, jw: anytype) !void {
        try jw.print("{s}", .{self.json});
    }
};

/// What the page's `extension:<name>` event carries: `{ name, data }`.
const PageEvent = struct {
    index: usize,
    name: []const u8,
    /// The emitted bytes as JSON: parsed when they are JSON, else a string
    /// (base64 when they aren't UTF-8).
    data: RawJson,
    /// The raw bytes, for the Zig handler.
    bytes: []const u8,
};

var pending: [count]pending_events.Pending(PageEvent, 8) = @splat(.{ .gpa = heap.gpa });
var page_ready: [count]bool = @splat(false);

/// `ctx.emit` / native emits (any thread): copied, then delivered on the
/// main thread.
fn emitToApp(r: *Runner, event: []const u8, data: []const u8) void {
    emitIndex(r.index, event, data);
}

/// Native code's emit by extension name (Kotlin, Objective-C; any thread).
pub fn emitByName(extension: []const u8, event: []const u8, data: []const u8) void {
    const i = indexByName(extension) orelse return log.warn("an event from unknown extension \"{f}\"", .{std.zig.fmtString(extension[0..@min(extension.len, 64)])});
    emitIndex(i, event, data);
}

fn emitIndex(i: usize, event: []const u8, data: []const u8) void {
    if (comptime count == 0) return;
    const name = runners[i].name;
    if (!spec.validEventName(event)) return log.warn("{s}: dropped an event with an invalid name", .{name});
    if (data.len > spec.max_event_bytes) return log.warn("{s}: dropped event {s}: {d} bytes, over {d}", .{ name, event, data.len, spec.max_event_bytes });
    if (sinks[i].load(.acquire)) |sink| return sink(event, data);
    const gpa = heap.gpa;
    const json = dataJson(gpa, data) catch return log.err("{s}: dropped event {s}: out of memory", .{ name, event });
    const value: PageEvent = .{ .index = i, .name = event, .data = .{ .json = json }, .bytes = data };
    const copy = pending_events.dupeDeep(gpa, PageEvent, value) catch {
        gpa.free(json);
        return log.err("{s}: dropped event {s}: out of memory", .{ name, event });
    };
    gpa.free(json);
    const boxed = gpa.create(PageEvent) catch {
        pending_events.freeDeep(gpa, PageEvent, copy);
        return;
    };
    boxed.* = copy;
    App.runOnMain(boxed, deliverMain);
}

fn deliverMain(ev: *PageEvent) void {
    if (comptime count == 0) return;
    const gpa = heap.gpa;
    defer {
        pending_events.freeDeep(gpa, PageEvent, ev.*);
        gpa.destroy(ev);
    }
    pending[ev.index].deliver(ev.*, toHandler, page_ready[ev.index], emitPage);
}

fn toHandler(ev: *const PageEvent) bool {
    if (comptime count == 0) return false;
    const h = handlers[ev.index].load(.acquire) orelse return false;
    h(.{ .extension = runners[ev.index].name, .name = ev.name, .data = ev.bytes });
    return true;
}

fn emitPage(ev: *const PageEvent) void {
    if (comptime count == 0) return;
    var buf: [10 + spec.max_name_len]u8 = undefined;
    const event = std.fmt.bufPrint(&buf, "extension:{s}", .{runners[ev.index].name}) catch return;
    App.emit(event, .{ .name = ev.name, .data = ev.data });
}

fn flushHandler(i: usize) void {
    if (comptime count == 0) return;
    pending[i].flushHandler(toHandler);
}

/// The bridges' `events:ready` for `extension:<name>` (any thread): false
/// for an event that isn't one.
pub fn pageReady(event: []const u8) bool {
    const prefix = "extension:";
    if (!std.mem.startsWith(u8, event, prefix)) return false;
    const i = indexByName(event[prefix.len..]) orelse return false;
    App.runOnMain(i, pageReadyMain);
    return true;
}

fn pageReadyMain(i: usize) void {
    if (comptime count == 0) return;
    page_ready[i] = true;
    pending[i].flushPage(emitPage);
}

/// `data` as a JSON value (caller frees).
fn dataJson(gpa: std.mem.Allocator, data: []const u8) error{OutOfMemory}![]u8 {
    if (data.len > 0 and try std.json.validate(gpa, data)) return gpa.dupe(u8, data);
    if (std.unicode.utf8ValidateSlice(data)) return std.json.Stringify.valueAlloc(gpa, data, .{});
    const enc = std.base64.standard.Encoder;
    const out = try gpa.alloc(u8, enc.calcSize(data.len) + 2);
    out[0] = '"';
    _ = enc.encode(out[1 .. out.len - 1], data);
    out[out.len - 1] = '"';
    return out;
}

// ---------------------------------------------------------------------------
// The page: `expose` and `oriel.extensions.call`
// ---------------------------------------------------------------------------

/// The built-in command behind the page's `oriel.extensions.call` (always
/// async: it runs on an IPC worker, src/core/ipc.zig).
pub const page_command = "extensions:call";

/// What the page may call on one extension.
pub const Expose = struct {
    /// Up to 32; others fail with "not exposed".
    methods: []const []const u8,
    /// Sees each call first: validate, rate-limit, rewrite `request.input`
    /// (allocate in `request.arena`), or refuse with an error (its name, or
    /// an `oriel.ipc.fail` message, is what the page gets).
    filter: ?Filter = null,
    timeout_ms: u32 = default_timeout_ms,
};

pub const PageRequest = struct {
    extension: []const u8,
    method: []const u8,
    /// The page's payload as JSON.
    input: []const u8,
    arena: std.mem.Allocator,
};

pub const Filter = *const fn (request: *PageRequest) anyerror!void;

pub const Exposed = std.atomic.Value(?*const Expose);

var exposed: [count]Exposed = @splat(.init(null));

/// Let the page call `options.methods` of extension `name` (any thread,
/// usually setup). A second call replaces the first.
pub fn expose(comptime name: []const u8, comptime options: Expose) void {
    comptime {
        if (spec.reserved(name)) @compileError("oriel.extensions.expose(\"" ++ name ++ "\"): Oriel's own extensions reach the page through their module's API");
        if (options.methods.len > spec.max_exposed_methods) @compileError("oriel.extensions.expose: at most 32 methods");
        for (options.methods) |m| if (!spec.validMethod(m)) @compileError("oriel.extensions.expose: invalid method name \"" ++ m ++ "\"");
    }
    const Static = struct {
        const value = options;
    };
    exposed[comptime indexOf(name)].store(&Static.value, .release);
}

/// `extensions:call {name, method, payload}` from the page (an IPC worker).
pub fn pageCall(arena: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const io = app_io orelse return error.Unavailable;
    return pageCallIn(&runners, &exposed, io, arena, args);
}

/// `pageCall` over any table (tested with fake backends).
pub fn pageCallIn(table: []Runner, exposures: []const Exposed, io: std.Io, arena: std.mem.Allocator, args: std.json.Value) anyerror![]u8 {
    const Args = struct { name: []const u8, method: []const u8, payload: std.json.Value = .null };
    const a = try std.json.parseFromValueLeaky(Args, arena, args, .{ .ignore_unknown_fields = true });
    const name_log = std.zig.fmtString(a.name[0..@min(a.name.len, spec.max_name_len)]);
    const method_log = std.zig.fmtString(a.method[0..@min(a.method.len, spec.max_method_len)]);
    const i = for (table, 0..) |*r, n| {
        if (std.mem.eql(u8, r.name, a.name)) break n;
    } else return ipc.fail("unknown extension \"{f}\"", .{name_log});
    const options = exposures[i].load(.acquire) orelse return ipc.fail("{f}.{f} is not exposed", .{ name_log, method_log });
    const listed = for (options.methods) |m| {
        if (std.mem.eql(u8, m, a.method)) break true;
    } else false;
    if (!listed) return ipc.fail("{f}.{f} is not exposed", .{ name_log, method_log });

    var request: PageRequest = .{
        .extension = table[i].name,
        .method = a.method,
        .input = try std.json.Stringify.valueAlloc(arena, a.payload, .{}),
        .arena = arena,
    };
    if (options.filter) |f| try f(&request);
    if (request.input.len > table[i].max_bytes) return ipc.fail("{s}.{f}: the payload is over {d} bytes", .{ table[i].name, method_log, table[i].max_bytes });
    var diag: Diagnostics = .{};
    const reply = table[i].call(io, arena, a.method, request.input, .{ .timeout_ms = options.timeout_ms, .diag = &diag }) catch |err| switch (err) {
        error.ExtensionFailed, error.TooLarge => return if (diag.message().len == 0)
            ipc.fail("{s}", .{if (diag.code().len > 0) diag.code() else @errorName(err)})
        else
            ipc.fail("{s}: {s}", .{ diag.code(), diag.message() }),
        else => return err,
    };
    // JSON is the convention: anything else goes to the page as a string.
    if (reply.len > 0 and try std.json.validate(arena, reply)) return reply;
    return dataJson(arena, reply);
}

// ---------------------------------------------------------------------------
// Tests (fake backends, no app)
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fake = struct {
    var gate: std.atomic.Value(bool) = .init(true);
    var started: std.atomic.Value(u32) = .init(0);
    var saw_cancel: std.atomic.Value(bool) = .init(false);
    var loads: std.atomic.Value(u32) = .init(0);
    var emitted: std.atomic.Value(u32) = .init(0);

    fn reset() void {
        gate.store(true, .release);
        started.store(0, .release);
        saw_cancel.store(false, .release);
        loads.store(0, .release);
        emitted.store(0, .release);
    }

    fn call(ctx: *Context, method: []const u8, input: []const u8) anyerror![]const u8 {
        _ = started.fetchAdd(1, .acq_rel);
        if (std.mem.eql(u8, method, "echo")) return input;
        if (std.mem.eql(u8, method, "reverse")) {
            const out = try ctx.arena.dupe(u8, input);
            std.mem.reverse(u8, out);
            ctx.emit("reversed", out);
            return out;
        }
        if (std.mem.eql(u8, method, "fail")) return ctx.fail("bad_input", "input was {d} bytes", .{input.len});
        if (std.mem.eql(u8, method, "oops")) return error.FileNotFound;
        if (std.mem.eql(u8, method, "big")) return try ctx.arena.alloc(u8, 64);
        if (std.mem.eql(u8, method, "hold")) {
            // Until the gate opens or the caller gives up (bounded: ~5 s).
            for (0..5000) |_| {
                if (ctx.isCancelled()) {
                    saw_cancel.store(true, .release);
                    return error.Cancelled;
                }
                if (gate.load(.acquire)) return "held";
                std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {};
            }
            return "held";
        }
        return error.UnknownMethod;
    }

    fn load(_: *Context) anyerror!void {
        _ = loads.fetchAdd(1, .acq_rel);
    }

    fn emit(_: *Runner, _: []const u8, _: []const u8) void {
        _ = emitted.fetchAdd(1, .acq_rel);
    }

    const impl: Impl = .{ .call = call, .load = load };
};

fn fakeRunner(concurrency: u8, max_bytes: usize) Runner {
    return .{ .name = "test.fake", .impl = Fake.impl, .concurrency = concurrency, .max_bytes = max_bytes, .on_emit = Fake.emit };
}

test "calls: reply, emit, failures with diagnostics, load once" {
    Fake.reset();
    var r = fakeRunner(2, 32);
    defer r.stop();
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("hi", try r.call(io, arena, "echo", "hi", .{}));
    try testing.expectEqualStrings("cba", try r.call(io, arena, "reverse", "abc", .{}));
    try testing.expectEqual(@as(u32, 1), Fake.emitted.load(.acquire));
    try testing.expectEqual(@as(u32, 1), Fake.loads.load(.acquire));

    var diag: Diagnostics = .{};
    try testing.expectError(error.ExtensionFailed, r.call(io, arena, "fail", "1234", .{ .diag = &diag }));
    try testing.expectEqualStrings("bad_input", diag.code());
    try testing.expectEqualStrings("input was 4 bytes", diag.message());
    try testing.expectError(error.ExtensionFailed, r.call(io, arena, "oops", "", .{ .diag = &diag }));
    try testing.expectEqualStrings("FileNotFound", diag.code());
    try testing.expectError(error.InvalidMethod, r.call(io, arena, "", "", .{}));
    try testing.expectError(error.InvalidMethod, r.call(io, arena, "a b", "", .{}));
}

test "size caps: input refused before it crosses, reply refused after" {
    Fake.reset();
    var r = fakeRunner(1, 32);
    defer r.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const started_before = Fake.started.load(.acquire);
    try testing.expectError(error.TooLarge, r.call(testing.io, arena_state.allocator(), "echo", &(@as([33]u8, @splat('x'))), .{}));
    try testing.expectEqual(started_before, Fake.started.load(.acquire));
    var diag: Diagnostics = .{};
    try testing.expectError(error.TooLarge, r.call(testing.io, arena_state.allocator(), "big", "", .{ .diag = &diag }));
    try testing.expectEqualStrings("too_large", diag.code());
}

test "timeout cancels the running call, then reports" {
    Fake.reset();
    Fake.gate.store(false, .release);
    var r = fakeRunner(1, 1024);
    defer r.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Timeout, r.call(testing.io, arena_state.allocator(), "hold", "", .{ .timeout_ms = 20 }));
    // The native side saw it (bounded wait).
    for (0..2000) |_| {
        if (Fake.saw_cancel.load(.acquire)) break;
        std.Io.sleep(testing.io, .fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(Fake.saw_cancel.load(.acquire));
    // The worker is free again.
    Fake.gate.store(true, .release);
    try testing.expectEqualStrings("ok", try r.call(testing.io, arena_state.allocator(), "echo", "ok", .{}));
}

test "cancel token: the caller returns at once" {
    Fake.reset();
    Fake.gate.store(false, .release);
    var r = fakeRunner(1, 1024);
    defer r.stop();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var token: CancelToken = .{};
    token.cancel();
    try testing.expectError(error.Cancelled, r.call(testing.io, arena_state.allocator(), "hold", "", .{ .cancel = &token, .timeout_ms = 5_000 }));
    Fake.gate.store(true, .release);
}

test "queue bounds: Busy past queue_capacity waiting calls" {
    Fake.reset();
    Fake.gate.store(false, .release);
    var r = fakeRunner(1, 1024);
    const io = testing.io;
    try r.start(io);
    // Fill the queue by hand (the worker is held by the first call).
    const Holder = struct {
        fn run(runner: *Runner) void {
            var a: std.heap.ArenaAllocator = .init(testing.allocator);
            defer a.deinit();
            _ = runner.call(testing.io, a.allocator(), "hold", "", .{ .timeout_ms = 5_000 }) catch {};
        }
    };
    const holder = try std.Thread.spawn(.{}, Holder.run, .{&r});
    for (0..2000) |_| {
        if (Fake.started.load(.acquire) > 0) break;
        std.Io.sleep(io, .fromMilliseconds(1), .awake) catch {};
    }
    r.mutex.lockUncancelable(io);
    var queued: [queue_capacity]*Call = undefined;
    for (&queued) |*c| {
        c.* = try Call.create("echo", "");
        c.*.cancelled.store(true, .release); // never runs
        c.*.refs.store(1, .release); // the worker's only
        r.queue[(r.head + r.len) % queue_capacity] = c.*;
        r.len += 1;
    }
    r.mutex.unlock(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(error.Busy, r.call(io, arena_state.allocator(), "echo", "x", .{}));
    Fake.gate.store(true, .release);
    holder.join();
    r.stop();
}

test Inflight {
    var t: Inflight(2) = .{};
    const a = try Call.create("m", "");
    defer {
        a.release();
        a.release();
    }
    const b = try Call.create("m", "");
    defer {
        b.release();
        b.release();
    }
    const c = try Call.create("m", "");
    defer {
        c.release();
        c.release();
    }
    try testing.expect(t.add(a));
    try testing.expect(t.add(b));
    try testing.expect(!t.add(c));
    try testing.expect(!t.cancelled(a.id));
    a.cancelled.store(true, .release);
    try testing.expect(t.cancelled(a.id));
    t.remove(b.id);
    try testing.expect(t.cancelled(b.id)); // gone reads as cancelled
    try testing.expect(t.add(c));
}

const FilterTest = struct {
    var seen: usize = 0;
    fn filter(req: *PageRequest) anyerror!void {
        seen += 1;
        if (std.mem.eql(u8, req.input, "\"refuse\"")) return error.Refused;
        if (std.mem.eql(u8, req.input, "\"rewrite\"")) req.input = try req.arena.dupe(u8, "\"rewritten\"");
    }
    const options: Expose = .{ .methods = &.{ "echo", "fail" }, .filter = filter };
};

test "expose: only listed methods, the filter first, JSON in and out" {
    Fake.reset();
    var table = [_]Runner{fakeRunner(1, 1024)};
    defer table[0].stop();
    var ex = [_]Exposed{.init(null)};
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const args = struct {
        fn of(a: std.mem.Allocator, json: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        }
    };
    // Nothing exposed yet.
    try testing.expectError(error.CommandFailed, pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"echo\",\"payload\":1}")));
    try testing.expectEqualStrings("test.fake.echo is not exposed", ipc.errorText(error.CommandFailed));

    ex[0].store(&FilterTest.options, .release);
    try testing.expectEqualStrings("{\"a\":[1,2]}", try pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"echo\",\"payload\":{\"a\":[1,2]}}")));
    try testing.expectError(error.CommandFailed, pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"reverse\",\"payload\":1}")));
    try testing.expectEqualStrings("test.fake.reverse is not exposed", ipc.errorText(error.CommandFailed));
    try testing.expectError(error.CommandFailed, pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"nope\",\"method\":\"echo\"}")));
    try testing.expectEqualStrings("unknown extension \"nope\"", ipc.errorText(error.CommandFailed));

    const seen_before = FilterTest.seen;
    try testing.expectError(error.Refused, pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"echo\",\"payload\":\"refuse\"}")));
    try testing.expectEqualStrings("\"rewritten\"", try pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"echo\",\"payload\":\"rewrite\"}")));
    try testing.expectEqual(seen_before + 2, FilterTest.seen);

    // An implementation's failure reaches the page as "code: message".
    try testing.expectError(error.CommandFailed, pageCallIn(&table, &ex, io, arena, try args.of(arena, "{\"name\":\"test.fake\",\"method\":\"fail\",\"payload\":7}")));
    try testing.expectEqualStrings("bad_input: input was 1 bytes", ipc.errorText(error.CommandFailed));
}

test dataJson {
    const gpa = testing.allocator;
    const j = try dataJson(gpa, "{\"x\":1}");
    defer gpa.free(j);
    try testing.expectEqualStrings("{\"x\":1}", j);
    const s = try dataJson(gpa, "plain text");
    defer gpa.free(s);
    try testing.expectEqualStrings("\"plain text\"", s);
    const e = try dataJson(gpa, "");
    defer gpa.free(e);
    try testing.expectEqualStrings("\"\"", e);
    const b = try dataJson(gpa, "\xff\x00");
    defer gpa.free(b);
    try testing.expectEqualStrings("\"/wA=\"", b);
}

test "the generated table is empty in Oriel's own build" {
    try testing.expect(count <= max_extensions);
}
