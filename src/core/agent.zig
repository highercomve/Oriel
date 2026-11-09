//! The dev agent: a control socket for coding agents and scripts, in
//! development builds only (`oriel dev`, `<name>-dev`). `oriel agent` and
//! its MCP server (`oriel agent mcp`) talk to it, so an agent can read what
//! a window shows, click and type in it, take a screenshot and read the
//! logs without driving the desktop.
//!
//! Production builds never contain it: `internal.run` starts it only when
//! `config.app.dev` is set (comptime), so nothing here is analyzed or
//! linked otherwise, and the packaging steps refuse a binary that has
//! `marker` in it (`package_tool check-no-agent`).
//!
//! Protocol: a Unix socket at `<runtime dir>/oriel-agent/<app id>.sock`
//! (the directory 0700, the socket 0600), one JSON request per line:
//!
//!     {"id": 1, "method": "snapshot", "params": {"window": "main"}}
//!
//! and one JSON reply per line, `{"id": 1, "result": ...}` or
//! `{"id": 1, "error": "..."}`. Page methods (`page_methods`) run in the
//! window's page through `agent_runtime.js`, whose answer comes back as the
//! `oriel:agent:reply` IPC command; the rest run here.

const std = @import("std");
const builtin = @import("builtin");
const App = @import("App.zig");
const heap = @import("heap.zig");
const internal = @import("internal.zig");
const ipc = @import("ipc.zig");
const platform = @import("../platform/platform.zig");
const target = @import("target.zig");
const build_opts = @import("build_options");

const log = std.log.scoped(.oriel_agent);

/// In every binary that contains the agent, and in no other: packaging
/// fails when it finds it (tools/package/main.zig `check-no-agent`). `ping`
/// returns it, which keeps it in the binary.
pub const marker = @import("agent_marker.zig").marker;

/// The agent runs in development builds on Linux and macOS desktops.
pub fn enabled(comptime config: App.Config) bool {
    return config.app.dev != null and (target.is_desktop_linux or builtin.os.tag == .macos);
}

/// Methods `agent_runtime.js` runs in the page.
const page_methods = [_][]const u8{ "snapshot", "click", "hover", "fill", "type", "press", "scroll", "text", "wait_for", "logs", "eval", "invoke", "reload", "info" };

const page_method_list = blk: {
    var out: []const u8 = "";
    for (page_methods, 0..) |m, i| out = out ++ (if (i == 0) "" else ", ") ++ m;
    break :blk out;
};

const runtime_js = @embedFile("agent_runtime.js");

const max_line = 8 << 20;
const max_connections = 8;
const default_timeout_ms = 10_000;

var io_: std.Io = undefined;
var app_id_buf: [256]u8 = undefined;
var app_id_len: usize = 0;
var dir_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var dir_len: usize = 0;
var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
var path_len: usize = 0;
var server: ?std.Io.net.Server = null;
var connections: std.atomic.Value(u32) = .init(0);
var stopping: std.atomic.Value(bool) = .init(false);
var shot_counter: std.atomic.Value(u32) = .init(0);

fn appId() []const u8 {
    return app_id_buf[0..app_id_len];
}

fn socketPath() []const u8 {
    return path_buf[0..path_len];
}

pub fn socketDir() []const u8 {
    return dir_buf[0..dir_len];
}

// ---------------------------------------------------------------------------
// Start and stop
// ---------------------------------------------------------------------------

/// Listen on the app's socket and serve it on a thread of its own. On the
/// main thread, before the loop (it reads the environment). A failure only
/// logs: the app runs without the agent.
pub fn start(io: std.Io, app_id: []const u8) void {
    io_ = io;
    if (app_id.len > app_id_buf.len) return;
    @memcpy(app_id_buf[0..app_id.len], app_id);
    app_id_len = app_id.len;
    resolvePaths() catch |err| {
        log.warn("dev agent off: no socket path ({s})", .{@errorName(err)});
        return;
    };
    listen() catch |err| {
        log.warn("dev agent off: cannot listen on {s} ({s})", .{ socketPath(), @errorName(err) });
        return;
    };
    ipc.agent_dispatch = &reply;
    @import("log.zig").agent_tap = &tapLog;
    internal.registerShutdownHook(&stop);
    const t = std.Thread.spawn(.{}, acceptLoop, .{}) catch |err| {
        log.warn("dev agent off: {s}", .{@errorName(err)});
        stop();
        return;
    };
    t.detach();
    log.info("dev agent on {s} (oriel agent --help)", .{socketPath()});
}

/// Close the socket and remove its file. Connections in flight end when
/// their reads fail.
fn stop() void {
    if (stopping.swap(true, .acq_rel)) return;
    ipc.agent_dispatch = null;
    @import("log.zig").agent_tap = null;
    if (server) |*s| {
        // Unblocks accept (Linux: shutdown wakes a blocked accept).
        _ = std.c.shutdown(s.socket.handle, 2);
        s.deinit(io_);
        server = null;
    }
    var z: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(z[0..path_len], socketPath());
    z[path_len] = 0;
    _ = std.c.unlink(@ptrCast(&z));
}

/// `$XDG_RUNTIME_DIR/oriel-agent`, else `$TMPDIR` (macOS: per user) or
/// `/tmp`, as `oriel-agent-<uid>`; the CLI looks in the same place
/// (cli/agent.zig `socketDir`).
fn resolvePaths() !void {
    const uid = std.c.getuid();
    const dir = if (std.c.getenv("XDG_RUNTIME_DIR")) |d|
        try std.fmt.bufPrint(&dir_buf, "{s}/oriel-agent", .{std.mem.span(d)})
    else if (std.c.getenv("TMPDIR")) |d|
        try std.fmt.bufPrint(&dir_buf, "{s}/oriel-agent-{d}", .{ std.mem.trimEnd(u8, std.mem.span(d), "/"), uid })
    else
        try std.fmt.bufPrint(&dir_buf, "/tmp/oriel-agent-{d}", .{uid});
    dir_len = dir.len;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.sock", .{ dir, appId() });
    path_len = path.len;
}

fn listen() !void {
    var dz: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(dz[0..dir_len], socketDir());
    dz[dir_len] = 0;
    if (std.c.mkdir(@ptrCast(&dz), 0o700) != 0 and std.posix.errno(-1) != .EXIST) return error.CannotCreateDir;
    // Someone else's directory (a shared /tmp) must not hold our socket.
    const owner = try dirOwner(@ptrCast(&dz));
    if (owner.uid != std.c.getuid() or !owner.is_dir) return error.UnsafeDir;
    if (owner.mode & 0o077 != 0) _ = std.c.chmod(@ptrCast(&dz), 0o700);

    const addr = try std.Io.net.UnixAddress.init(socketPath());
    // One that answers is a running copy of this app: leave it be.
    if (addr.connect(io_)) |s| {
        s.close(io_);
        return error.AnotherInstanceListens;
    } else |_| {}
    var z: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
    @memcpy(z[0..path_len], socketPath());
    z[path_len] = 0;
    _ = std.c.unlink(@ptrCast(&z)); // a stale socket from a crashed run
    server = try addr.listen(io_, .{});
    _ = std.c.chmod(@ptrCast(&z), 0o600);
}

const Owner = struct { uid: std.c.uid_t, mode: u32, is_dir: bool };

/// Who owns `path` (not following a symlink there).
fn dirOwner(path: [*:0]const u8) !Owner {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        if (std.c.statx(std.c.AT.FDCWD, path, std.c.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &sx) != 0) return error.CannotCreateDir;
        return .{ .uid = sx.uid, .mode = sx.mode & 0o7777, .is_dir = (sx.mode & linux.S.IFMT) == linux.S.IFDIR };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.CannotCreateDir;
    return .{ .uid = st.uid, .mode = @intCast(st.mode & 0o7777), .is_dir = (st.mode & std.c.S.IFMT) == std.c.S.IFDIR };
}

fn acceptLoop() void {
    while (!stopping.load(.acquire)) {
        var s = server orelse return;
        const stream = s.accept(io_) catch |err| {
            if (stopping.load(.acquire)) return;
            log.debug("accept: {s}", .{@errorName(err)});
            std.Io.sleep(io_, .fromMilliseconds(50), .awake) catch {};
            continue;
        };
        if (connections.fetchAdd(1, .acq_rel) >= max_connections) {
            _ = connections.fetchSub(1, .acq_rel);
            stream.close(io_);
            continue;
        }
        const t = std.Thread.spawn(.{}, serve, .{stream}) catch {
            _ = connections.fetchSub(1, .acq_rel);
            stream.close(io_);
            continue;
        };
        t.detach();
    }
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

fn serve(stream: std.Io.net.Stream) void {
    defer _ = connections.fetchSub(1, .acq_rel);
    defer stream.close(io_);
    const gpa = heap.gpa;
    const in_buf = gpa.alloc(u8, max_line) catch return;
    defer gpa.free(in_buf);
    var out_buf: [64 * 1024]u8 = undefined;
    var reader = stream.reader(io_, in_buf);
    var writer = stream.writer(io_, &out_buf);
    while (!stopping.load(.acquire)) {
        const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                writeError(&writer.interface, null, "request longer than 8 MiB") catch return;
                return;
            },
            else => return,
        } orelse return;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        handleLine(arena_state.allocator(), line, &writer.interface) catch return;
        writer.interface.flush() catch return;
    }
}

const Request = struct {
    id: std.json.Value = .null,
    method: []const u8,
    params: std.json.Value = .null,
};

fn handleLine(arena: std.mem.Allocator, line: []const u8, w: *std.Io.Writer) !void {
    const req = std.json.parseFromSliceLeaky(Request, arena, line, .{ .ignore_unknown_fields = true }) catch {
        return writeError(w, null, "bad request: expected {\"id\":..,\"method\":\"..\",\"params\":{..}}");
    };
    const result = call(arena, req.method, req.params) catch |err| {
        const text = switch (err) {
            error.OutOfMemory => "out of memory",
            else => failure orelse @errorName(err),
        };
        failure = null;
        return writeError(w, req.id, text);
    };
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(req.id, .{}, w);
    try w.writeAll(",\"result\":");
    try w.writeAll(result);
    try w.writeAll("}\n");
}

fn writeError(w: *std.Io.Writer, id: ?std.json.Value, text: []const u8) !void {
    try w.writeAll("{\"id\":");
    try std.json.Stringify.value(id orelse .null, .{}, w);
    try w.writeAll(",\"error\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.writeAll("}\n");
    try w.flush();
}

/// The text of the error `call` returns (`error.Failed`), per thread.
threadlocal var failure: ?[]const u8 = null;

fn fail(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{ Failed, OutOfMemory } {
    failure = try std.fmt.allocPrint(arena, fmt, args);
    return error.Failed;
}

fn call(arena: std.mem.Allocator, method: []const u8, params: std.json.Value) ![]const u8 {
    if (std.mem.eql(u8, method, "ping")) return ping(arena);
    if (std.mem.eql(u8, method, "windows")) return windowsList(arena);
    if (std.mem.eql(u8, method, "app_logs")) return appLogs(arena, params);
    if (std.mem.eql(u8, method, "screenshot")) return screenshot(arena, params);
    if (std.mem.eql(u8, method, "quit")) {
        App.runOnMain(@as(u8, 0), struct {
            fn f(code: u8) void {
                App.quit(code);
            }
        }.f);
        return "true";
    }
    for (page_methods) |m| if (std.mem.eql(u8, m, method)) return pageCall(arena, method, params);
    return fail(arena, "unknown method \"{s}\" (methods: ping, windows, app_logs, screenshot, quit, {s})", .{ method, page_method_list });
}

fn ping(arena: std.mem.Allocator) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .app = appId(),
        .pid = std.c.getpid(),
        .platform = target.name,
        .renderer = if (build_opts.native_ui) "native" else "webview",
        .agent = marker,
    }, .{});
}

fn windowsList(arena: std.mem.Allocator) ![]const u8 {
    const Info = struct { label: []const u8, title: []const u8, width: c_int, height: c_int };
    var list: std.ArrayList(Info) = .empty;
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |w| {
        try list.append(arena, .{
            .label = try arena.dupe(u8, w.label),
            .title = try arena.dupe(u8, w.options.title),
            .width = w.options.width,
            .height = w.options.height,
        });
    }
    return std.json.Stringify.valueAlloc(arena, list.items, .{});
}

fn windowExists(label: []const u8) bool {
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |w| if (std.mem.eql(u8, w.label, label)) return true;
    return false;
}

fn stringParam(params: std.json.Value, name: []const u8) ?[]const u8 {
    if (params != .object) return null;
    const v = params.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn intParam(params: std.json.Value, name: []const u8) ?i64 {
    if (params != .object) return null;
    const v = params.object.get(name) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn boolParam(params: std.json.Value, name: []const u8) bool {
    if (params != .object) return false;
    const v = params.object.get(name) orelse return false;
    return v == .bool and v.bool;
}

fn windowParam(arena: std.mem.Allocator, params: std.json.Value) ![:0]const u8 {
    const label = stringParam(params, "window") orelse "main";
    if (!windowExists(label)) return fail(arena, "no window \"{s}\" (see the windows method)", .{label});
    return arena.dupeZ(u8, label);
}

// ---------------------------------------------------------------------------
// Pending replies (page calls, screenshots)
// ---------------------------------------------------------------------------

const Slot = struct {
    id: u32 = 0,
    event: std.Io.Event = .unset,
    ok: bool = false,
    /// heap.gpa-owned JSON, once answered.
    value: ?[]u8 = null,
};

var slots: [32]Slot = @splat(.{});
var slots_mutex: std.Io.Mutex = .init;
var next_id: std.atomic.Value(u32) = .init(1);

fn lockSlots() void {
    std.Io.Threaded.mutexLock(&slots_mutex);
}

fn unlockSlots() void {
    std.Io.Threaded.mutexUnlock(&slots_mutex);
}

fn reserve() ?u32 {
    lockSlots();
    defer unlockSlots();
    for (&slots) |*s| if (s.id == 0) {
        var id = next_id.fetchAdd(1, .monotonic);
        if (id == 0) id = next_id.fetchAdd(1, .monotonic);
        s.* = .{ .id = id };
        return id;
    };
    return null;
}

fn slotOf(id: u32) ?*Slot {
    for (&slots) |*s| if (s.id == id) return s;
    return null;
}

/// Give back `id`'s slot (answered or not); a late answer then finds none.
fn release(id: u32) void {
    lockSlots();
    defer unlockSlots();
    const s = slotOf(id) orelse return;
    if (s.value) |v| heap.gpa.free(v);
    s.* = .{};
}

/// Answer `id`: `value_json` is copied. Any thread; an unknown id (timed
/// out, released) is dropped.
pub fn complete(id: u32, ok: bool, value_json: []const u8) void {
    const copy = heap.gpa.dupe(u8, value_json) catch null;
    lockSlots();
    defer unlockSlots();
    const s = slotOf(id) orelse {
        if (copy) |c| heap.gpa.free(c);
        return;
    };
    if (s.event.isSet()) {
        if (copy) |c| heap.gpa.free(c);
        return;
    }
    s.ok = ok and copy != null;
    s.value = copy orelse heap.gpa.dupe(u8, "\"out of memory\"") catch null;
    s.event.set(io_);
}

/// Wait for `id`'s answer, then release its slot. The JSON is in `arena`.
fn await_(arena: std.mem.Allocator, id: u32, timeout_ms: u32, what: []const u8) ![]const u8 {
    defer release(id);
    const s = blk: {
        lockSlots();
        defer unlockSlots();
        break :blk slotOf(id).?;
    };
    // The slot stays ours (only `release` frees it), so `s` stays valid.
    const deadline = std.Io.Clock.awake.now(io_).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    while (!s.event.isSet()) {
        const now = std.Io.Clock.awake.now(io_).nanoseconds;
        if (now >= deadline) return fail(arena, "{s}: no answer within {d} ms (is the window showing the app's own page, and done loading?)", .{ what, timeout_ms });
        const left: u64 = @intCast(@min(deadline - now, 100 * std.time.ns_per_ms));
        io_.futexWaitTimeout(std.Io.Event, &s.event, .waiting, .{ .duration = .{ .raw = .fromNanoseconds(left), .clock = .awake } }) catch {};
    }
    lockSlots();
    defer unlockSlots();
    const value = s.value orelse "null";
    if (!s.ok) {
        const parsed = std.json.parseFromSliceLeaky([]const u8, arena, value, .{}) catch value;
        return fail(arena, "{s}", .{parsed});
    }
    return arena.dupe(u8, value);
}

/// `oriel:agent:reply` from agent_runtime.js (ipc.agent_dispatch).
fn reply(arena: std.mem.Allocator, request: ipc.Request) anyerror![]u8 {
    const Args = struct { id: u32, ok: bool, value: std.json.Value = .null };
    const args = try std.json.parseFromValueLeaky(Args, arena, request.args, .{ .ignore_unknown_fields = true });
    const json = try std.json.Stringify.valueAlloc(arena, args.value, .{});
    complete(args.id, args.ok, json);
    return arena.dupe(u8, "null");
}

fn pageCall(arena: std.mem.Allocator, method: []const u8, params: std.json.Value) ![]const u8 {
    const label = try windowParam(arena, params);
    const id = reserve() orelse return fail(arena, "too many calls in flight", .{});
    var timeout: u32 = @intCast(std.math.clamp(intParam(params, "timeout_ms") orelse default_timeout_ms, 100, 120_000));
    if (std.mem.eql(u8, method, "wait_for")) timeout +|= 2000; // the page's own timeout first
    errdefer release(id);
    var script: std.Io.Writer.Allocating = .init(arena);
    const w = &script.writer;
    try w.writeAll(runtime_js);
    try w.print("\n;window.__oriel_agent.run({d},", .{id});
    try std.json.Stringify.value(method, .{}, w);
    try w.writeByte(',');
    try std.json.Stringify.value(params, .{}, w);
    try w.writeAll(");\n");
    const z = try script.toOwnedSliceSentinel(0);
    platform.evalJsByLabel(label, z);
    return await_(arena, id, timeout, method);
}

// ---------------------------------------------------------------------------
// Screenshots
// ---------------------------------------------------------------------------

const shot = if (target.is_desktop_linux and !build_opts.native_ui) @import("../platform/linux/agent_shot.zig") else struct {
    pub const supported = false;
};

fn screenshot(arena: std.mem.Allocator, params: std.json.Value) ![]const u8 {
    const label = try windowParam(arena, params);
    if (!shot.supported) return fail(arena, "screenshot isn't supported on {s}{s} yet", .{ target.name, if (build_opts.native_ui) " with -Dnative_ui" else "" });
    const path = if (stringParam(params, "path")) |p|
        try arena.dupeZ(u8, p)
    else
        try std.fmt.allocPrintSentinel(arena, "{s}/{s}-{s}-{d}.png", .{ socketDir(), appId(), label, shot_counter.fetchAdd(1, .monotonic) }, 0);
    const id = reserve() orelse return fail(arena, "too many calls in flight", .{});
    shot.take(id, label, path, boolParam(params, "full_page")) catch |err| {
        release(id);
        return err;
    };
    return await_(arena, id, 10_000, "screenshot");
}

// ---------------------------------------------------------------------------
// The app's own log (std.log through oriel.log.logFn)
// ---------------------------------------------------------------------------

const log_capacity = 1000;
var log_lines: [log_capacity]?[]u8 = @splat(null);
var log_seq: u64 = 0;
var log_mutex: std.Io.Mutex = .init;

/// One formatted line from log.zig (it holds its own lock). Dropped when
/// memory runs out.
pub fn tapLog(line: []const u8) void {
    const copy = heap.gpa.dupe(u8, std.mem.trimEnd(u8, line, "\n")) catch return;
    std.Io.Threaded.mutexLock(&log_mutex);
    defer std.Io.Threaded.mutexUnlock(&log_mutex);
    log_seq += 1;
    const i: usize = @intCast(log_seq % log_capacity);
    if (log_lines[i]) |old| heap.gpa.free(old);
    log_lines[i] = copy;
}

fn appLogs(arena: std.mem.Allocator, params: std.json.Value) ![]const u8 {
    const since: u64 = @intCast(@max(0, intParam(params, "since") orelse 0));
    const Entry = struct { seq: u64, text: []const u8 };
    var entries: std.ArrayList(Entry) = .empty;
    std.Io.Threaded.mutexLock(&log_mutex);
    defer std.Io.Threaded.mutexUnlock(&log_mutex);
    const first = @max(since + 1, if (log_seq > log_capacity) log_seq - log_capacity + 1 else 1);
    var seq = first;
    while (seq <= log_seq) : (seq += 1) {
        const line = log_lines[@intCast(seq % log_capacity)] orelse continue;
        try entries.append(arena, .{ .seq = seq, .text = try arena.dupe(u8, line) });
    }
    return std.json.Stringify.valueAlloc(arena, .{ .entries = entries.items, .last = log_seq }, .{});
}

test "the runtime script is one expression statement" {
    try std.testing.expect(std.mem.startsWith(u8, runtime_js, "// The page half"));
    try std.testing.expect(std.mem.indexOf(u8, runtime_js, "oriel:agent:reply") != null);
}

test "slots: an answer reaches its waiter once, late answers are dropped" {
    io_ = std.testing.io;
    const id = reserve().?;
    complete(id, true, "{\"a\":1}");
    complete(id, true, "{\"a\":2}"); // dropped: already answered
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const v = try await_(arena_state.allocator(), id, 1000, "test");
    try std.testing.expectEqualStrings("{\"a\":1}", v);
    complete(id, true, "{}"); // released: dropped, nothing leaks
    for (slots) |s| try std.testing.expectEqual(@as(u32, 0), s.id);
}

test "slots: an error answer becomes the call's error text" {
    io_ = std.testing.io;
    const id = reserve().?;
    complete(id, false, "\"no element matches \\\"#x\\\"\"");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Failed, await_(arena_state.allocator(), id, 1000, "test"));
    try std.testing.expectEqualStrings("no element matches \"#x\"", failure.?);
    failure = null;
}

test "slots: no answer times out and frees the slot" {
    io_ = std.testing.io;
    const id = reserve().?;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.Failed, await_(arena_state.allocator(), id, 100, "test"));
    failure = null;
    for (slots) |s| try std.testing.expectEqual(@as(u32, 0), s.id);
}

test "log tap keeps the newest lines" {
    defer {
        for (&log_lines) |*l| if (l.*) |x| {
            heap.gpa.free(x);
            l.* = null;
        };
        log_seq = 0;
    }
    var i: usize = 0;
    while (i < log_capacity + 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        tapLog(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const json = try appLogs(arena_state.allocator(), .null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"line 4\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"line 5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"line 1004\"") != null);
}
