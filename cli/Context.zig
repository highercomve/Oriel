//! What every command gets: allocator, I/O, environment and output streams,
//! plus helpers for finding and running other programs.

const std = @import("std");
const builtin = @import("builtin");
const Context = @This();

gpa: std.mem.Allocator,
io: std.Io,
environ: *const std.process.Environ.Map,
/// Normal output (stdout).
out: *std.Io.Writer,
/// Errors, warnings and progress (stderr).
err: *std.Io.Writer,

/// The Zig binary to use: `$ORIEL_ZIG`, else `zig` from PATH.
pub fn zig(ctx: Context) []const u8 {
    if (ctx.environ.get("ORIEL_ZIG")) |z| if (z.len > 0) return z;
    return "zig";
}

/// Oriel needs Zig 0.16.x: `0.16.0`, `0.16.1-dev.12+abc` → true.
pub fn zigVersionOk(version: []const u8) bool {
    return std.mem.startsWith(u8, version, "0.16.");
}

/// Flush both streams, so our output appears before a child's.
pub fn flush(ctx: Context) void {
    ctx.out.flush() catch {};
    ctx.err.flush() catch {};
}

/// Full path of `name` in `$PATH` (or `name` itself if it contains a path
/// separator and is executable). On Windows the PATHEXT extensions are
/// tried too, so `npm` finds `npm.cmd`. Caller owns the result.
pub fn findExecutable(ctx: Context, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const separators = if (builtin.os.tag == .windows) "/\\" else "/";
    if (std.mem.indexOfAny(u8, name, separators) != null) {
        return try ctx.withExtension(name) orelse null;
    }
    const path = ctx.environ.get("PATH") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        const full = try std.fs.path.join(ctx.gpa, &.{ dir, name });
        defer ctx.gpa.free(full);
        if (try ctx.withExtension(full)) |found| return found;
    }
    return null;
}

/// `path` if it is executable, else (Windows) `path` + the first PATHEXT
/// extension that is. On Windows a file only runs with a PATHEXT extension,
/// so an extensionless `npm` (the POSIX shell script next to `npm.cmd`) is
/// skipped. Caller owns the result.
fn withExtension(ctx: Context, path: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (builtin.os.tag != .windows) {
        return if (isExecutable(ctx.io, path)) try ctx.gpa.dupe(u8, path) else null;
    }
    const exts = ctx.environ.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD";
    if (hasExtension(path, exts) and isExecutable(ctx.io, path)) return try ctx.gpa.dupe(u8, path);
    var it = std.mem.tokenizeScalar(u8, exts, ';');
    while (it.next()) |ext| {
        const full = try std.mem.concat(ctx.gpa, u8, &.{ path, ext });
        if (isExecutable(ctx.io, full)) return full;
        ctx.gpa.free(full);
    }
    return null;
}

/// Whether `path` ends in one of the `;`-separated extensions (any case).
fn hasExtension(path: []const u8, exts: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, exts, ';');
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return false;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    // Windows has no execute bit: any file found (with a PATHEXT extension) runs.
    if (builtin.os.tag == .windows) return true;
    cwd.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

/// Run a program with our stdin/stdout/stderr and wait for it. Returns its
/// exit code (128 + signal number if it was killed), or null if it could
/// not be started (the reason is printed).
pub fn run(ctx: Context, argv: []const []const u8, cwd: ?[]const u8) ?u8 {
    ctx.flush();
    var child = std.process.spawn(ctx.io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    }) catch |e| {
        ctx.err.print("error: could not run '{s}': {s}\n", .{ argv[0], spawnErrorText(e) }) catch {};
        return null;
    };
    const term = child.wait(ctx.io) catch |e| {
        child.kill(ctx.io);
        ctx.err.print("error: waiting for '{s}': {s}\n", .{ argv[0], @errorName(e) }) catch {};
        return null;
    };
    return exitCode(term);
}

pub fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 +| @as(u8, @truncate(@intFromEnum(sig))),
        .unknown => 1,
    };
}

pub fn spawnErrorText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "not found (is it installed and on PATH?)",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        else => @errorName(e),
    };
}

/// Output of a finished program.
pub const Captured = struct {
    /// Exit code (see `exitCode`).
    code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(c: Captured, gpa: std.mem.Allocator) void {
        gpa.free(c.stdout);
        gpa.free(c.stderr);
    }

    /// Stdout without surrounding whitespace.
    pub fn text(c: Captured) []const u8 {
        return std.mem.trim(u8, c.stdout, " \t\r\n");
    }
};

/// Run a program quietly and collect its output (stdin is /dev/null, at most
/// 1 MiB per stream, killed after `timeout_ms`). Null if it could not be
/// started or did not finish. Caller frees with `Captured.deinit`.
pub fn capture(ctx: Context, argv: []const []const u8, timeout_ms: u32) ?Captured {
    const result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
        .timeout = .{ .duration = .{
            .raw = .{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms },
            .clock = .awake,
        } },
    }) catch return null;
    return .{ .code = exitCode(result.term), .stdout = result.stdout, .stderr = result.stderr };
}

test zigVersionOk {
    try std.testing.expect(zigVersionOk("0.16.0"));
    try std.testing.expect(zigVersionOk("0.16.1-dev.3+abcdef"));
    try std.testing.expect(!zigVersionOk("0.15.2"));
    try std.testing.expect(!zigVersionOk("0.1.6"));
}

test "findExecutable searches PATH" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    // On Windows a program needs a PATHEXT extension instead of an execute bit.
    const windows = builtin.os.tag == .windows;
    const tool_file = if (windows) "bin/tool.exe" else "bin/tool";
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = tool_file, .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/data", .data = "x" });
    const bin = try tmp.dir.realPathFileAlloc(io, "bin", gpa);
    defer gpa.free(bin);
    const sep = std.fs.path.delimiter;
    const path = try std.fmt.allocPrint(gpa, "/nonexistent{c}{c}{s}", .{ sep, sep, bin });
    defer gpa.free(path);
    try env.put("PATH", path);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const ctx: Context = .{ .gpa = gpa, .io = io, .environ = &env, .out = &discard.writer, .err = &discard.writer };
    const found = (try ctx.findExecutable("tool")).?;
    defer gpa.free(found);
    const expected = try std.fs.path.join(gpa, &.{ bin, if (windows) "tool.exe" else "tool" });
    defer gpa.free(expected);
    // (Windows: the extension is PATHEXT's spelling, e.g. `tool.EXE`.)
    if (windows) try std.testing.expect(std.ascii.eqlIgnoreCase(expected, found)) else try std.testing.expectEqualStrings(expected, found);
    if (windows) {
        // Given with its extension, in any case, it resolves to the same file.
        const found_ext = (try ctx.findExecutable("TOOL.EXE")).?;
        defer gpa.free(found_ext);
        try std.testing.expect(std.ascii.eqlIgnoreCase(expected, found_ext));
    }
    try std.testing.expectEqual(null, try ctx.findExecutable("data")); // not executable (Windows: no PATHEXT extension)
    try std.testing.expectEqual(null, try ctx.findExecutable("missing"));
    try std.testing.expectEqualStrings("zig", ctx.zig());
    try env.put("ORIEL_ZIG", "/opt/zig/zig");
    try std.testing.expectEqualStrings("/opt/zig/zig", ctx.zig());
}
