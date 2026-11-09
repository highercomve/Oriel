//! `oriel agent`: drive a running development build (`oriel dev`) from the
//! terminal or from a coding agent: read what a window shows, click, type,
//! take screenshots, read logs. It talks to the dev agent the app runs
//! (src/core/agent.zig) over its Unix socket; production builds have no
//! such socket.
//!
//!     oriel agent snapshot             what the main window shows, with refs
//!     oriel agent click e5             click a ref from the snapshot
//!     oriel agent fill e4 "Ada"        set a field
//!     oriel agent screenshot           PNG of the window
//!     oriel agent mcp                  the same as MCP tools, on stdio

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("Context.zig");
const project = @import("project.zig");
const deep_link = @import("deep_link.zig");

pub const Command = struct {
    pub const summary = "Drive the running dev build: snapshot, click, type, screenshot, logs (and an MCP server)";
    pub const forward = "args";
    pub const usage =
        \\Usage: oriel agent <command> [args] [--app <id>] [--window <label>]
        \\
        \\Drives the app `oriel dev` is running (development builds only; Linux,
        \\macOS) without touching the mouse or keyboard: the app answers on a
        \\socket of its own.
        \\
        \\Read:
        \\  snapshot [--interactive] [--selector <css>]
        \\                         The window's content as an outline of roles, names,
        \\                         values and states; each element has a ref (e12)
        \\  text [<target>]        The visible text (of the page or one element)
        \\  screenshot [--out <file.png>] [--full]
        \\                         PNG of the window (--full: the whole page)
        \\  logs [--since <n>] [--page | --app-log]
        \\                         The page's console and the app's own log (std.log)
        \\  windows                The open windows
        \\  info                   URL, title, size and focus of the window's page
        \\
        \\Act (a <target> is a ref from the snapshot, "text=Save",
        \\"role=button[name=Save]" or a CSS selector):
        \\  click <target> [--double]
        \\  fill <target> <value>  Replace a field's value (inputs, selects, checkboxes)
        \\  type <text> [--target <target>]
        \\                         Type at the caret, key by key
        \\  press <key> [--target <target>]
        \\                         Enter, Escape, Tab, Control+a, ...
        \\  hover <target>
        \\  scroll [--target <target>] [--dx <px>] [--dy <px>]
        \\  wait <target> [--hidden] [--timeout <ms>]
        \\                         Until it is visible (or gone)
        \\  eval <expression>      Run JavaScript in the page; prints the result
        \\  invoke <command> [<json args>]
        \\                         Call one of the app's Zig commands
        \\  reload                 Reload the page
        \\  quit                   Quit the app
        \\
        \\More:
        \\  apps                   Running dev builds this user can drive
        \\  call <method> [<json params>]
        \\                         Send a raw request (see docs/agent.md)
        \\  mcp                    Serve the commands as MCP tools on stdio:
        \\                         claude mcp add oriel -- oriel agent mcp
        \\
        \\Options:
        \\  --app <id>             Which app (default: this project's, else the only one)
        \\  --window <label>       Which window (default: main)
        \\
    ;
    args: []const []const u8 = &.{},
};

const max_reply = 32 << 20;

pub fn run(ctx: Context, cmd: Command) !u8 {
    if (cmd.args.len == 0 or isHelp(cmd.args[0])) {
        try ctx.out.writeAll(Command.usage);
        return if (cmd.args.len == 0) 2 else 0;
    }
    if (comptime !supported) {
        try ctx.err.writeAll("error: oriel agent works with Linux and macOS dev builds\n");
        return 1;
    }
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts = Options{};
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < cmd.args.len) : (i += 1) {
        const a = cmd.args[i];
        const value = struct {
            fn next(args: []const []const u8, idx: *usize) ?[]const u8 {
                if (idx.* + 1 >= args.len) return null;
                idx.* += 1;
                return args[idx.*];
            }
        }.next;
        if (isHelp(a)) {
            try ctx.out.writeAll(Command.usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--app")) {
            opts.app = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--window")) {
            opts.window = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--target")) {
            opts.target = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--selector")) {
            opts.selector = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--out")) {
            opts.out = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--since")) {
            opts.since = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--timeout")) {
            opts.timeout = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--dx")) {
            opts.dx = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--dy")) {
            opts.dy = value(cmd.args, &i) orelse return missing(ctx, a);
        } else if (std.mem.eql(u8, a, "--interactive")) {
            opts.interactive = true;
        } else if (std.mem.eql(u8, a, "--full")) {
            opts.full = true;
        } else if (std.mem.eql(u8, a, "--double")) {
            opts.double = true;
        } else if (std.mem.eql(u8, a, "--hidden")) {
            opts.hidden = true;
        } else if (std.mem.eql(u8, a, "--page")) {
            opts.source = .page;
        } else if (std.mem.eql(u8, a, "--app-log")) {
            opts.source = .app;
        } else {
            try pos.append(arena, a);
        }
    }

    if (pos.items.len == 0) {
        try ctx.out.writeAll(Command.usage);
        return 2;
    }
    const sub = pos.items[0];
    const rest = pos.items[1..];
    if (std.mem.eql(u8, sub, "mcp")) return mcp(ctx, arena);
    if (std.mem.eql(u8, sub, "apps")) return listApps(ctx, arena);
    // The app writes the PNG: a relative path would be relative to its
    // directory, not ours.
    if (opts.out) |o| if (!std.fs.path.isAbsolute(o)) {
        const cwd = try std.process.currentPathAlloc(ctx.io, arena);
        opts.out = try std.fs.path.join(arena, &.{ cwd, o });
    };

    const req = buildRequest(arena, sub, rest, opts) catch |err| switch (err) {
        error.Usage => {
            try ctx.err.print("error: wrong arguments for `{s}`\nRun 'oriel agent --help' for usage.\n", .{sub});
            return 2;
        },
        error.BadJson => {
            try ctx.err.writeAll("error: the JSON argument doesn't parse\n");
            return 2;
        },
        else => return err,
    };

    const sock = resolveSocket(ctx, arena, opts.app) catch |err| return reportResolve(ctx, err);

    if (std.mem.eql(u8, req.method, "logs_both")) {
        const page = try request(ctx.io, arena, sock, "logs", req.params);
        const app = try request(ctx.io, arena, sock, "app_logs", req.params);
        try printLogs(ctx, arena, app, "app");
        try printLogs(ctx, arena, page, "page");
        return 0;
    }
    const reply = try request(ctx.io, arena, sock, req.method, req.params);
    return printReply(ctx, arena, req.method, reply);
}

const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;

const Options = struct {
    app: ?[]const u8 = null,
    window: ?[]const u8 = null,
    target: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    out: ?[]const u8 = null,
    since: ?[]const u8 = null,
    timeout: ?[]const u8 = null,
    dx: ?[]const u8 = null,
    dy: ?[]const u8 = null,
    interactive: bool = false,
    full: bool = false,
    double: bool = false,
    hidden: bool = false,
    source: enum { both, page, app } = .both,
};

fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "help");
}

fn missing(ctx: Context, flag: []const u8) !u8 {
    try ctx.err.print("error: {s} needs a value\n", .{flag});
    return 2;
}

const Req = struct { method: []const u8, params: std.json.Value };

/// The request for `oriel agent <sub> <pos...> <opts>`.
fn buildRequest(arena: std.mem.Allocator, sub: []const u8, pos: []const []const u8, opts: Options) !Req {
    var p: std.json.ObjectMap = .empty;
    if (opts.window) |w| try p.put(arena, "window", .{ .string = w });
    const eql = std.mem.eql;
    const method: []const u8 = if (eql(u8, sub, "snapshot")) blk: {
        if (opts.interactive) try p.put(arena, "interactive", .{ .bool = true });
        if (opts.selector) |s| try p.put(arena, "selector", .{ .string = s });
        break :blk "snapshot";
    } else if (eql(u8, sub, "click") or eql(u8, sub, "hover")) blk: {
        if (pos.len != 1) return error.Usage;
        try p.put(arena, "target", .{ .string = pos[0] });
        if (opts.double) try p.put(arena, "double", .{ .bool = true });
        break :blk sub;
    } else if (eql(u8, sub, "fill")) blk: {
        if (pos.len != 2) return error.Usage;
        try p.put(arena, "target", .{ .string = pos[0] });
        try p.put(arena, "value", .{ .string = pos[1] });
        break :blk "fill";
    } else if (eql(u8, sub, "type")) blk: {
        if (pos.len != 1) return error.Usage;
        try p.put(arena, "text", .{ .string = pos[0] });
        if (opts.target) |t| try p.put(arena, "target", .{ .string = t });
        break :blk "type";
    } else if (eql(u8, sub, "press")) blk: {
        if (pos.len != 1) return error.Usage;
        try p.put(arena, "key", .{ .string = pos[0] });
        if (opts.target) |t| try p.put(arena, "target", .{ .string = t });
        break :blk "press";
    } else if (eql(u8, sub, "scroll")) blk: {
        if (pos.len > 1) return error.Usage;
        if (opts.target orelse if (pos.len == 1) pos[0] else null) |t| try p.put(arena, "target", .{ .string = t });
        if (opts.dx) |v| try p.put(arena, "dx", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.Usage });
        if (opts.dy) |v| try p.put(arena, "dy", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.Usage });
        break :blk "scroll";
    } else if (eql(u8, sub, "text")) blk: {
        if (pos.len > 1) return error.Usage;
        if (pos.len == 1) try p.put(arena, "target", .{ .string = pos[0] });
        break :blk "text";
    } else if (eql(u8, sub, "wait")) blk: {
        if (pos.len != 1) return error.Usage;
        try p.put(arena, "target", .{ .string = pos[0] });
        if (opts.hidden) try p.put(arena, "state", .{ .string = "hidden" });
        if (opts.timeout) |v| try p.put(arena, "timeout_ms", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.Usage });
        break :blk "wait_for";
    } else if (eql(u8, sub, "eval")) blk: {
        if (pos.len != 1) return error.Usage;
        try p.put(arena, "expression", .{ .string = pos[0] });
        break :blk "eval";
    } else if (eql(u8, sub, "invoke")) blk: {
        if (pos.len < 1 or pos.len > 2) return error.Usage;
        try p.put(arena, "cmd", .{ .string = pos[0] });
        if (pos.len == 2) try p.put(arena, "args", std.json.parseFromSliceLeaky(std.json.Value, arena, pos[1], .{}) catch return error.BadJson);
        break :blk "invoke";
    } else if (eql(u8, sub, "screenshot")) blk: {
        if (pos.len > 0) return error.Usage;
        if (opts.out) |o| try p.put(arena, "path", .{ .string = o });
        if (opts.full) try p.put(arena, "full_page", .{ .bool = true });
        break :blk "screenshot";
    } else if (eql(u8, sub, "logs")) blk: {
        if (opts.since) |v| try p.put(arena, "since", .{ .integer = std.fmt.parseInt(i64, v, 10) catch return error.Usage });
        break :blk switch (opts.source) {
            .both => "logs_both",
            .page => "logs",
            .app => "app_logs",
        };
    } else if (eql(u8, sub, "windows") or eql(u8, sub, "info") or eql(u8, sub, "reload") or eql(u8, sub, "quit") or eql(u8, sub, "ping")) blk: {
        if (pos.len > 0) return error.Usage;
        break :blk sub;
    } else if (eql(u8, sub, "call")) blk: {
        if (pos.len < 1 or pos.len > 2) return error.Usage;
        if (pos.len == 2) {
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, pos[1], .{}) catch return error.BadJson;
            if (v != .object) return error.BadJson;
            var it = v.object.iterator();
            while (it.next()) |e| try p.put(arena, e.key_ptr.*, e.value_ptr.*);
        }
        break :blk pos[0];
    } else return error.Usage;
    return .{ .method = method, .params = .{ .object = p } };
}

fn printReply(ctx: Context, arena: std.mem.Allocator, method: []const u8, reply: Reply) !u8 {
    switch (reply) {
        .err => |e| {
            try ctx.err.print("error: {s}\n", .{e});
            return 1;
        },
        .ok => |v| {
            if (std.mem.eql(u8, method, "snapshot") and v == .object) {
                if (v.object.get("title")) |t| if (t == .string) try ctx.out.print("# {s}\n", .{t.string});
                if (v.object.get("url")) |u| if (u == .string) try ctx.out.print("# {s}\n", .{u.string});
                if (v.object.get("snapshot")) |s| if (s == .string) try ctx.out.print("{s}\n", .{s.string});
                return 0;
            }
            if (std.mem.eql(u8, method, "text") and v == .object) {
                if (v.object.get("text")) |t| if (t == .string) {
                    try ctx.out.print("{s}\n", .{t.string});
                    return 0;
                };
            }
            if (std.mem.eql(u8, method, "screenshot") and v == .object) {
                if (v.object.get("path")) |p| if (p == .string) {
                    try ctx.out.print("{s}\n", .{p.string});
                    return 0;
                };
            }
            if ((std.mem.eql(u8, method, "logs") or std.mem.eql(u8, method, "app_logs")) and v == .object) {
                try printLogs(ctx, arena, reply, null);
                return 0;
            }
            if (v == .string) {
                try ctx.out.print("{s}\n", .{v.string});
                return 0;
            }
            try std.json.Stringify.value(v, .{ .whitespace = .indent_2 }, ctx.out);
            try ctx.out.writeByte('\n');
            return 0;
        },
    }
}

fn printLogs(ctx: Context, arena: std.mem.Allocator, reply: Reply, label: ?[]const u8) !void {
    _ = arena;
    const v = switch (reply) {
        .err => |e| {
            try ctx.err.print("{s} logs: {s}\n", .{ label orelse "", e });
            return;
        },
        .ok => |v| v,
    };
    if (v != .object) return;
    const entries = v.object.get("entries") orelse return;
    if (entries != .array) return;
    for (entries.array.items) |e| {
        if (e != .object) continue;
        const text = e.object.get("text") orelse continue;
        if (text != .string) continue;
        const seq = if (e.object.get("seq")) |s| (if (s == .integer) s.integer else 0) else 0;
        const level = if (e.object.get("level")) |l| (if (l == .string) l.string else null) else null;
        if (label) |l| try ctx.out.print("[{s} {d}] ", .{ l, seq }) else try ctx.out.print("[{d}] ", .{seq});
        if (level) |l| try ctx.out.print("{s}: ", .{l});
        try ctx.out.print("{s}\n", .{text.string});
    }
    if (v.object.get("last")) |last| if (last == .integer) {
        if (label) |l| try ctx.out.print("# {s}: --since {d} for newer lines\n", .{ l, last.integer }) else try ctx.out.print("# --since {d} for newer lines\n", .{last.integer});
    };
}

// ---------------------------------------------------------------------------
// Finding the app
// ---------------------------------------------------------------------------

/// Where the apps' sockets are: the same rule as src/core/agent.zig
/// `resolvePaths`.
fn socketDir(ctx: Context, arena: std.mem.Allocator) ![]const u8 {
    if (ctx.environ.get("XDG_RUNTIME_DIR")) |d| if (d.len > 0) return std.fmt.allocPrint(arena, "{s}/oriel-agent", .{d});
    const uid = getuid();
    if (ctx.environ.get("TMPDIR")) |d| if (d.len > 0) return std.fmt.allocPrint(arena, "{s}/oriel-agent-{d}", .{ std.mem.trimEnd(u8, d, "/"), uid });
    return std.fmt.allocPrint(arena, "/tmp/oriel-agent-{d}", .{uid});
}

fn getuid() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getuid(),
        .macos => std.c.getuid(),
        else => 0,
    };
}

const ResolveError = error{ NoApps, AppNotRunning, SeveralApps } || std.mem.Allocator.Error;

var resolve_detail: []const u8 = "";

/// The socket of `--app`, else of this project's app, else the only
/// running one.
fn resolveSocket(ctx: Context, arena: std.mem.Allocator, app: ?[]const u8) ResolveError![]const u8 {
    const dir = try socketDir(ctx, arena);
    if (app) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.sock", .{ dir, id });
        if (!alive(ctx.io, path)) {
            resolve_detail = id;
            return error.AppNotRunning;
        }
        return path;
    }
    if (projectAppId(ctx, arena)) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.sock", .{ dir, id });
        if (alive(ctx.io, path)) return path;
    }
    const apps = try runningApps(ctx, arena, dir);
    if (apps.len == 0) return error.NoApps;
    if (apps.len > 1) {
        resolve_detail = try std.mem.join(arena, ", ", apps);
        return error.SeveralApps;
    }
    return std.fmt.allocPrint(arena, "{s}/{s}.sock", .{ dir, apps[0] });
}

fn reportResolve(ctx: Context, err: ResolveError) !u8 {
    switch (err) {
        error.NoApps => try ctx.err.writeAll("error: no dev build is running (start one with `oriel dev`; production builds have no agent)\n"),
        error.AppNotRunning => try ctx.err.print("error: {s} is not running a dev build (oriel agent apps lists the running ones)\n", .{resolve_detail}),
        error.SeveralApps => try ctx.err.print("error: several dev builds are running ({s}): pick one with --app <id>\n", .{resolve_detail}),
        error.OutOfMemory => return error.OutOfMemory,
    }
    return 1;
}

/// The app id in this project's build.zig (`.package.id`), if any.
fn projectAppId(ctx: Context, arena: std.mem.Allocator) ?[]const u8 {
    const cwd = std.process.currentPathAlloc(ctx.io, arena) catch return null;
    const root = (project.findRoot(arena, ctx.io, cwd) catch return null) orelse return null;
    const build_zig = std.fs.path.join(arena, &.{ root, "build.zig" }) catch return null;
    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, build_zig, arena, .limited(10 << 20)) catch return null;
    return deep_link.parseAppIdFromBuildZig(arena, text);
}

fn alive(io: std.Io, path: []const u8) bool {
    const addr = std.Io.net.UnixAddress.init(path) catch return false;
    const s = addr.connect(io) catch return false;
    s.close(io);
    return true;
}

/// Ids of the apps whose sockets answer.
fn runningApps(ctx: Context, arena: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".sock")) continue;
        const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, e.name });
        if (!alive(ctx.io, path)) continue;
        try out.append(arena, try arena.dupe(u8, e.name[0 .. e.name.len - ".sock".len]));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out.items;
}

fn listApps(ctx: Context, arena: std.mem.Allocator) !u8 {
    const dir = try socketDir(ctx, arena);
    const apps = try runningApps(ctx, arena, dir);
    if (apps.len == 0) {
        try ctx.out.writeAll("No dev build is running (oriel dev starts one).\n");
        return 0;
    }
    for (apps) |id| {
        const path = try std.fmt.allocPrint(arena, "{s}/{s}.sock", .{ dir, id });
        const r = request(ctx.io, arena, path, "ping", .null) catch {
            try ctx.out.print("{s}\n", .{id});
            continue;
        };
        const pid: i64 = switch (r) {
            .ok => |v| if (v == .object) if (v.object.get("pid")) |p| (if (p == .integer) p.integer else 0) else 0 else 0,
            .err => 0,
        };
        try ctx.out.print("{s}  (pid {d})\n", .{ id, pid });
    }
    return 0;
}

// ---------------------------------------------------------------------------
// The socket
// ---------------------------------------------------------------------------

const Reply = union(enum) { ok: std.json.Value, err: []const u8 };

/// One request on a fresh connection. Errors: the app went away.
fn request(io: std.Io, arena: std.mem.Allocator, sock: []const u8, method: []const u8, params: std.json.Value) !Reply {
    const addr = try std.Io.net.UnixAddress.init(sock);
    const stream = addr.connect(io) catch return .{ .err = "the app is not running any more" };
    defer stream.close(io);
    var wbuf: [16 * 1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try std.json.Stringify.value(.{ .id = 1, .method = method, .params = params }, .{}, &w.interface);
    try w.interface.writeByte('\n');
    try w.interface.flush();
    const rbuf = try arena.alloc(u8, max_reply);
    var r = stream.reader(io, rbuf);
    const maybe_line = r.interface.takeDelimiter('\n') catch return .{ .err = "the app closed the connection" };
    const line = maybe_line orelse return .{ .err = "the app closed the connection" };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return .{ .err = "the app's reply doesn't parse" };
    if (parsed != .object) return .{ .err = "unexpected reply" };
    if (parsed.object.get("error")) |e| return .{ .err = if (e == .string) e.string else "error" };
    return .{ .ok = parsed.object.get("result") orelse .null };
}

// ---------------------------------------------------------------------------
// MCP (stdio, newline-delimited JSON-RPC 2.0)
// ---------------------------------------------------------------------------

const protocol_version = "2025-06-18";

/// Each tool: its name, the agent method, and its input schema's
/// properties (every tool also takes `app` and `window`).
const Tool = struct { name: []const u8, method: []const u8, description: []const u8, properties: []const u8 = "", required: []const u8 = "" };

const target_prop =
    \\"target":{"type":"string","description":"A ref from oriel_snapshot (e12), \"text=Save\", \"role=button[name=Save]\" or a CSS selector"}
;

const tools = [_]Tool{
    .{ .name = "oriel_apps", .method = "", .description = "List the running Oriel dev builds (oriel dev) this user can drive. Call it first when unsure which app is running." },
    .{ .name = "oriel_snapshot", .method = "snapshot", .description = "What the window shows, as an outline of roles, names, values and states. Each element gets a ref (e12) to pass as `target` to the other tools. Take a new one after the page changes.", .properties =
    \\"interactive":{"type":"boolean","description":"Only elements you can act on"},"selector":{"type":"string","description":"Only the part under this CSS selector"}
    },
    .{ .name = "oriel_click", .method = "click", .description = "Click an element (pointer and mouse events, then click), as a user would.", .properties = target_prop ++
        \\,"double":{"type":"boolean"}
    , .required = "\"target\"" },
    .{ .name = "oriel_fill", .method = "fill", .description = "Replace a field's value: text inputs, textareas, contenteditable, selects (option value or text), checkboxes and radios (\"true\"/\"false\"). Fires input and change.", .properties = target_prop ++
        \\,"value":{"type":"string"}
    , .required = "\"target\",\"value\"" },
    .{ .name = "oriel_type", .method = "type", .description = "Type text at the caret, key by key (keydown, insert, keyup), into the target or the focused element.", .properties = target_prop ++
        \\,"text":{"type":"string"}
    , .required = "\"text\"" },
    .{ .name = "oriel_press", .method = "press", .description = "Press a key or chord on the target or the focused element: Enter, Escape, Tab, ArrowDown, Control+a, Meta+k.", .properties = target_prop ++
        \\,"key":{"type":"string"}
    , .required = "\"key\"" },
    .{ .name = "oriel_hover", .method = "hover", .description = "Move the pointer over an element (hover menus, tooltips).", .properties = target_prop, .required = "\"target\"" },
    .{ .name = "oriel_scroll", .method = "scroll", .description = "Scroll the page or an element by dx/dy pixels, or bring the target into view.", .properties = target_prop ++
        \\,"dx":{"type":"integer"},"dy":{"type":"integer"}
    },
    .{ .name = "oriel_wait_for", .method = "wait_for", .description = "Wait until the target is visible (or, state=hidden, gone).", .properties = target_prop ++
        \\,"state":{"type":"string","enum":["visible","hidden"]},"timeout_ms":{"type":"integer","description":"Default 5000"}
    , .required = "\"target\"" },
    .{ .name = "oriel_text", .method = "text", .description = "The visible text of the page or of one element.", .properties = target_prop },
    .{ .name = "oriel_screenshot", .method = "screenshot", .description = "A PNG of the window, rendered by the web view itself (works when the window is covered or on another workspace).", .properties =
    \\"full_page":{"type":"boolean","description":"The whole page, not just what fits the window"}
    },
    .{ .name = "oriel_logs", .method = "logs", .description = "The page's console messages and errors (from the agent's first call in this page) and the app's own log (std.log). Pass `since` (the `last` of a previous call) for newer lines only.", .properties =
    \\"since":{"type":"integer"},"source":{"type":"string","enum":["both","page","app"],"description":"Default both"}
    },
    .{ .name = "oriel_eval", .method = "eval", .description = "Evaluate a JavaScript expression in the page (awaits promises) and return its JSON value.", .properties =
    \\"expression":{"type":"string"}
    , .required = "\"expression\"" },
    .{ .name = "oriel_invoke", .method = "invoke", .description = "Call one of the app's Zig commands, as the page's oriel.invoke does.", .properties =
    \\"cmd":{"type":"string"},"args":{"description":"The command's arguments (an object)"}
    , .required = "\"cmd\"" },
    .{ .name = "oriel_windows", .method = "windows", .description = "The app's open windows (labels, titles, sizes)." },
    .{ .name = "oriel_info", .method = "info", .description = "The window's page: URL, title, ready state, size, focused element." },
    .{ .name = "oriel_reload", .method = "reload", .description = "Reload the window's page (refs from earlier snapshots go stale)." },
};

fn writeToolList(w: *std.Io.Writer) !void {
    try w.writeAll("{\"tools\":[");
    for (tools, 0..) |t, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try std.json.Stringify.value(t.name, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(t.description, .{}, w);
        try w.writeAll(",\"inputSchema\":{\"type\":\"object\",\"properties\":{");
        if (!std.mem.eql(u8, t.name, "oriel_apps")) {
            try w.writeAll(
                \\"app":{"type":"string","description":"App id (oriel_apps); default: the only running one"}
            );
            if (!std.mem.eql(u8, t.method, "windows")) try w.writeAll(
                \\,"window":{"type":"string","description":"Window label; default main"}
            );
            if (t.properties.len > 0) try w.writeByte(',');
        }
        try w.writeAll(t.properties);
        try w.writeAll("}");
        if (t.required.len > 0) try w.print(",\"required\":[{s}]", .{t.required});
        try w.writeAll("}}");
    }
    try w.writeAll("]}");
}

fn mcp(ctx: Context, _: std.mem.Allocator) !u8 {
    var in_buf: [1 << 20]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(ctx.io, &in_buf);
    while (true) {
        const line = stdin.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => continue,
            else => return 0,
        } orelse return 0;
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        try mcpMessage(ctx, arena_state.allocator(), line);
        try ctx.out.flush();
    }
}

fn mcpMessage(ctx: Context, arena: std.mem.Allocator, line: []const u8) !void {
    const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
        return rpcError(ctx.out, .null, -32700, "parse error");
    };
    if (msg != .object) return rpcError(ctx.out, .null, -32600, "invalid request");
    const id = msg.object.get("id") orelse return; // a notification
    const method_v = msg.object.get("method") orelse return; // a response to us
    if (method_v != .string) return rpcError(ctx.out, id, -32600, "invalid request");
    const method = method_v.string;
    const params = msg.object.get("params") orelse .null;
    const w = ctx.out;
    if (std.mem.eql(u8, method, "initialize")) {
        // Answer with the client's version when it is one we know.
        var version: []const u8 = protocol_version;
        if (params == .object) if (params.object.get("protocolVersion")) |v| if (v == .string) {
            for ([_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18" }) |known| if (std.mem.eql(u8, v.string, known)) {
                version = known;
            };
        };
        try rpcResultStart(w, id);
        try w.print("{{\"protocolVersion\":\"{s}\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"oriel-agent\",\"version\":\"{s}\"}},", .{ version, build_options.version });
        try w.writeAll("\"instructions\":");
        try std.json.Stringify.value(
            \\Drives a running Oriel dev build (`oriel dev`) from inside the app: no mouse, keyboard or desktop screenshots. Start with oriel_snapshot, act with oriel_click / oriel_fill / oriel_press using the refs it gives, check with oriel_snapshot, oriel_text or oriel_screenshot, and read oriel_logs for errors. After a Zig change `oriel dev` rebuilds and restarts the app: wait for oriel_apps to list it again.
        , .{}, w);
        try w.writeAll("}}\n");
        return;
    }
    if (std.mem.eql(u8, method, "ping")) {
        try rpcResultStart(w, id);
        try w.writeAll("{}}\n");
        return;
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        try rpcResultStart(w, id);
        try writeToolList(w);
        try w.writeAll("}\n");
        return;
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        if (params != .object) return rpcError(w, id, -32602, "missing params");
        const name = params.object.get("name") orelse return rpcError(w, id, -32602, "missing tool name");
        if (name != .string) return rpcError(w, id, -32602, "missing tool name");
        const args: std.json.Value = params.object.get("arguments") orelse .{ .object = .empty };
        return toolCall(ctx, arena, id, name.string, if (args == .object) args else .{ .object = .empty });
    }
    return rpcError(w, id, -32601, "method not found");
}

fn rpcResultStart(w: *std.Io.Writer, id: std.json.Value) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.writeAll(",\"result\":");
}

fn rpcError(w: *std.Io.Writer, id: std.json.Value, code: i32, message: []const u8) !void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try std.json.Stringify.value(id, .{}, w);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try std.json.Stringify.value(message, .{}, w);
    try w.writeAll("}}\n");
}

/// A tool result: text content (and an image), `isError` when it failed.
fn toolResult(w: *std.Io.Writer, id: std.json.Value, text: []const u8, is_error: bool, image_b64: ?[]const u8) !void {
    try rpcResultStart(w, id);
    try w.writeAll("{\"content\":[");
    if (image_b64) |img| {
        try w.writeAll("{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"");
        try w.writeAll(img);
        try w.writeAll("\"},");
    }
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text, .{}, w);
    try w.print("}}],\"isError\":{}}}}}\n", .{is_error});
}

fn toolCall(ctx: Context, arena: std.mem.Allocator, id: std.json.Value, name: []const u8, args: std.json.Value) !void {
    const w = ctx.out;
    const tool = for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) break t;
    } else return toolResult(w, id, try std.fmt.allocPrint(arena, "unknown tool {s}", .{name}), true, null);

    const dir = try socketDir(ctx, arena);
    if (std.mem.eql(u8, tool.name, "oriel_apps")) {
        const apps = try runningApps(ctx, arena, dir);
        const text = if (apps.len == 0) "No dev build is running. Start one with `oriel dev` in the app's directory." else try std.mem.join(arena, "\n", apps);
        return toolResult(w, id, text, false, null);
    }

    var params = args;
    const app: ?[]const u8 = if (params.object.get("app")) |a| (if (a == .string) a.string else null) else null;
    _ = params.object.orderedRemove("app");
    const sock = resolveSocket(ctx, arena, app) catch |err| {
        const text = switch (err) {
            error.NoApps => "No dev build is running. Start one with `oriel dev` (production builds have no agent).",
            error.AppNotRunning => try std.fmt.allocPrint(arena, "{s} is not running a dev build (see oriel_apps)", .{resolve_detail}),
            error.SeveralApps => try std.fmt.allocPrint(arena, "Several dev builds are running ({s}): pass `app`.", .{resolve_detail}),
            error.OutOfMemory => return error.OutOfMemory,
        };
        return toolResult(w, id, text, true, null);
    };

    if (std.mem.eql(u8, tool.method, "logs")) {
        const source = if (params.object.get("source")) |s| (if (s == .string) s.string else "both") else "both";
        _ = params.object.orderedRemove("source");
        var out: std.Io.Writer.Allocating = .init(arena);
        var failed = false;
        for ([_][]const u8{ "app", "page" }) |which| {
            if (!std.mem.eql(u8, source, "both") and !std.mem.eql(u8, source, which)) continue;
            const r = try request(ctx.io, arena, sock, if (std.mem.eql(u8, which, "app")) "app_logs" else "logs", params);
            switch (r) {
                .err => |e| {
                    failed = true;
                    try out.writer.print("{s} log: {s}\n", .{ which, e });
                },
                .ok => |v| {
                    try out.writer.print("{s} log:\n", .{which});
                    try std.json.Stringify.value(v, .{}, &out.writer);
                    try out.writer.writeByte('\n');
                },
            }
        }
        return toolResult(w, id, out.written(), failed, null);
    }

    const r = try request(ctx.io, arena, sock, tool.method, params);
    switch (r) {
        .err => |e| return toolResult(w, id, e, true, null),
        .ok => |v| {
            if (std.mem.eql(u8, tool.method, "snapshot") and v == .object) {
                const title = if (v.object.get("title")) |t| (if (t == .string) t.string else "") else "";
                const url = if (v.object.get("url")) |u| (if (u == .string) u.string else "") else "";
                const snap = if (v.object.get("snapshot")) |s| (if (s == .string) s.string else "") else "";
                return toolResult(w, id, try std.fmt.allocPrint(arena, "Page: {s} ({s})\n{s}", .{ title, url, snap }), false, null);
            }
            const text = try std.json.Stringify.valueAlloc(arena, v, .{});
            if (std.mem.eql(u8, tool.method, "screenshot") and v == .object) {
                if (v.object.get("path")) |p| if (p == .string) {
                    const png = std.Io.Dir.cwd().readFileAlloc(ctx.io, p.string, arena, .limited(32 << 20)) catch
                        return toolResult(w, id, text, false, null);
                    const enc = std.base64.standard.Encoder;
                    const b64 = try arena.alloc(u8, enc.calcSize(png.len));
                    _ = enc.encode(b64, png);
                    return toolResult(w, id, text, false, b64);
                };
            }
            return toolResult(w, id, text, false, null);
        },
    }
}

test "buildRequest maps commands to agent methods" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try buildRequest(a, "fill", &.{ "e4", "Ada" }, .{ .window = "settings" });
    try std.testing.expectEqualStrings("fill", r.method);
    try std.testing.expectEqualStrings("e4", r.params.object.get("target").?.string);
    try std.testing.expectEqualStrings("Ada", r.params.object.get("value").?.string);
    try std.testing.expectEqualStrings("settings", r.params.object.get("window").?.string);
    try std.testing.expectEqualStrings("wait_for", (try buildRequest(a, "wait", &.{"#x"}, .{ .hidden = true })).method);
    try std.testing.expectEqualStrings("logs_both", (try buildRequest(a, "logs", &.{}, .{})).method);
    try std.testing.expectError(error.Usage, buildRequest(a, "click", &.{}, .{}));
    try std.testing.expectError(error.BadJson, buildRequest(a, "invoke", &.{ "greet", "{" }, .{}));
    try std.testing.expectError(error.Usage, buildRequest(a, "nope", &.{}, .{}));
}

test "the MCP tool list is valid JSON" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeToolList(&out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(tools.len, parsed.value.object.get("tools").?.array.items.len);
}
