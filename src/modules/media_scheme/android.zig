//! Media scheme on Android: the files below the root at
//! `https://app.localhost/media/<path>` (the app's own origin), served by the
//! Kotlin runtime straight from the WebView's request interception
//! (OrielMedia.kt): Range requests for seeking, nothing read into memory, no
//! port.

const std = @import("std");
const open = @import("../media/open.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

/// Where the page finds the root's files: `<base_url><path>`.
pub const base_url = "https://app.localhost/media/";

/// Serve the files below `path` (replacing any previous root). Any thread.
pub fn setRoot(path: []const u8, policy: open.SymlinkPolicy) !void {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;
    try call(path, policy == .refuse_all);
}

/// Stop serving `/media/` (requests get 404).
pub fn clearRoot() void {
    call("", false) catch {};
}

fn call(path: []const u8, refuse_all: bool) !void {
    const Ctx = struct {
        path: []const u8,
        refuse_all: bool,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "setMediaRoot", "([BZ)V", .{ c.path, c.refuse_all });
        }
    };
    var ctx: Ctx = .{ .path = path, .refuse_all = refuse_all };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
}
