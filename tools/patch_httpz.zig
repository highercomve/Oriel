//! Build tool: copy http.zig's `src/` into the build cache with Oriel's
//! Windows fixes applied, for Windows targets only (Linux builds use the
//! dependency as-is).
//!
//! http.zig's blocking (Windows) server treats some Winsock errors as
//! `unreachable`. On shutdown it closes the listening socket and every open
//! connection to wake its threads; on Windows the blocked `accept` then fails
//! with WSA_OPERATION_ABORTED / WSAEINTR and the blocked `recv`s with
//! WSAENOTSOCK / WSAEINTR (and a `send` in flight likewise), which panicked
//! the app ("reached unreachable code") instead of ending those threads. The
//! patches map them to the errors the Linux code path already handles
//! (SocketNotListening, NotOpenForReading, BrokenPipe). Each patch must match
//! exactly once, so updating the dependency fails the build loudly instead of
//! silently dropping a fix.
//!
//! Usage: patch_httpz <httpz_src_dir> <out_dir>

const std = @import("std");
const Dir = std.Io.Dir;

pub const Patch = struct {
    file: []const u8,
    old: []const u8,
    new: []const u8,
};

pub const patches = [_]Patch{
    .{
        .file = "windows.zig",
        .old =
        \\pub const RecvError = error{
        \\    WouldBlock,
        ,
        .new =
        \\pub const RecvError = error{
        \\    WouldBlock,
        \\    NotOpenForReading,
        ,
    },
    .{
        .file = "windows.zig",
        .old =
        \\        .WSAESHUTDOWN => return 0,
        \\        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        \\        .WSAENOTSOCK => unreachable,
        ,
        .new =
        \\        .WSAESHUTDOWN => return 0,
        \\        // Another thread closed the socket (server shutdown).
        \\        .WSAEINTR, .WSAENOTSOCK => return error.NotOpenForReading,
        \\        .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        ,
    },
    .{
        .file = "windows.zig",
        .old =
        \\        .WSAEMSGSIZE => return error.MessageTooBig,
        \\        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        \\        .WSAENOTSOCK => unreachable,
        ,
        .new =
        \\        .WSAEMSGSIZE => return error.MessageTooBig,
        \\        // Another thread closed the socket (server shutdown).
        \\        .WSAEINTR, .WSAENOTSOCK => return error.BrokenPipe,
        \\        .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        ,
    },
    .{
        .file = "posix.zig",
        .old =
        \\                    .WSAEINTR, .WSAENOTSOCK => return error.SocketNotListening,
        ,
        .new =
        \\                    // The listening socket was closed (server shutdown).
        \\                    .WSAEINTR, .WSAENOTSOCK, .WSA_OPERATION_ABORTED => return error.SocketNotListening,
        ,
    },
};

/// Apply every patch for `file` to `content`. Returns null when no patch
/// targets the file. Caller owns the result.
pub fn apply(gpa: std.mem.Allocator, file: []const u8, content: []const u8) !?[]u8 {
    var current: ?[]u8 = null;
    errdefer if (current) |c| gpa.free(c);
    for (patches) |p| {
        if (!std.mem.eql(u8, p.file, file)) continue;
        const src = current orelse content;
        const at = std.mem.indexOf(u8, src, p.old) orelse return error.PatchDoesNotApply;
        if (std.mem.indexOfPos(u8, src, at + 1, p.old) != null) return error.PatchAmbiguous;
        const next = try std.mem.concat(gpa, u8, &.{ src[0..at], p.new, src[at + p.old.len ..] });
        if (current) |c| gpa.free(c);
        current = next;
    }
    return current;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = init.minimal.args.vector;
    if (argv.len != 3) {
        std.debug.print("usage: patch_httpz <httpz_src_dir> <out_dir>\n", .{});
        std.process.exit(2);
    }
    const src_path = std.mem.span(argv[1]);
    const out_path = std.mem.span(argv[2]);

    var src = try Dir.cwd().openDir(io, src_path, .{ .iterate = true });
    defer src.close(io);
    try Dir.cwd().createDirPath(io, out_path);
    var out = try Dir.cwd().openDir(io, out_path, .{});
    defer out.close(io);

    var applied: usize = 0;
    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try out.createDirPath(io, entry.path),
            .file => {
                const content = try src.readFileAlloc(io, entry.path, gpa, .limited(16 << 20));
                defer gpa.free(content);
                const patched = apply(gpa, entry.path, content) catch |err| {
                    std.debug.print("patch_httpz: {s}: {s} (http.zig changed? update tools/patch_httpz.zig)\n", .{ entry.path, @errorName(err) });
                    std.process.exit(1);
                };
                defer if (patched) |p| gpa.free(p);
                if (patched != null) applied += 1;
                try out.writeFile(io, .{ .sub_path = entry.path, .data = patched orelse content });
            },
            else => {},
        }
    }
    if (applied != 2) {
        std.debug.print("patch_httpz: patched {d} files, expected 2\n", .{applied});
        std.process.exit(1);
    }
}

test "apply patches each target once and leaves other files alone" {
    const gpa = std.testing.allocator;
    const src =
        \\pub const RecvError = error{
        \\    WouldBlock,
        \\};
        \\        .WSAESHUTDOWN => return 0,
        \\        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        \\        .WSAENOTSOCK => unreachable,
        \\
    ;
    try std.testing.expectError(error.PatchDoesNotApply, apply(gpa, "windows.zig", src)); // no send() in src
    const send_src =
        \\        .WSAEMSGSIZE => return error.MessageTooBig,
        \\        .WSAEINTR, .WSAEINPROGRESS => unreachable,
        \\        .WSAEINVAL, .WSAEFAULT => unreachable,
        \\        .WSAENOTSOCK => unreachable,
        \\
    ;
    const both = try std.mem.concat(gpa, u8, &.{ src, send_src });
    defer gpa.free(both);
    const out = (try apply(gpa, "windows.zig", both)).?;
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "NotOpenForReading,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".WSAENOTSOCK => unreachable") == null);
    try std.testing.expectEqual(@as(?[]u8, null), try apply(gpa, "request.zig", src));
    try std.testing.expectError(error.PatchDoesNotApply, apply(gpa, "posix.zig", src));
}
