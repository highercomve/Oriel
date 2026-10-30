//! The video player on Android: OrielVideo.kt shows MediaPlayer on a
//! SurfaceView, with a MediaController and a close button, over the
//! window's WebView. Plain URLs (http(s), file, content) go to MediaPlayer;
//! the app's media URLs (`https://app.localhost/media/<path>`, which only
//! the WebView's request interception serves) are read in-process as
//! OrielMedia serves them: the media source through `NativeLib.mediaSize`
//! and `mediaRead` (src/modules/media_scheme/android.zig), else the root's
//! file. Back, Esc and the close button close it; OrielVideo reports those,
//! the end and errors as the "video" system event (`onSystemEvent`).

const std = @import("std");
const App = @import("../../core/App.zig");
const heap = @import("../../core/heap.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const common = @import("common.zig");

/// OrielRuntime.videoPlay's answers.
const shown = 0;
const no_activity = -1;
const not_found = -2;

pub fn play(window: ?*App.Window, options: common.Options) common.Error!void {
    const kind = try common.validate(options, common.android_rules);
    // Prepared before the main thread changes anything.
    const url = try heap.gpa.dupeZ(u8, options.url);
    errdefer heap.gpa.free(url);
    const Ctx = struct {
        window: i32,
        url: [:0]u8,
        title: []const u8,
        kind: i32,
        out: i32 = -3,
        fn run(c: *@This()) void {
            c.out = runtime.call(.int, "videoPlay", "(I[B[BI)I", .{ c.window, @as([]const u8, c.url), c.title, c.kind }) orelse -3;
            // The URL playing, for the events (main thread, as they are).
            if (c.out == shown) common.adopt(c.url);
        }
    };
    var ctx: Ctx = .{
        .window = if (window) |w| @intCast(w.handle.id) else -1,
        .url = url,
        .title = options.title,
        .kind = @intFromEnum(kind),
    };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return error.AppNotRunning;
    return switch (ctx.out) {
        shown => {},
        no_activity => error.NoWindow,
        not_found => error.Failed,
        else => error.Failed,
    };
}

pub fn close() void {
    const Ctx = struct {
        fn run(_: *@This()) void {
            // True when a player was showing; Kotlin doesn't report a close
            // Zig asked for.
            if (runtime.call(.boolean, "videoClose", "()Z", .{}) orelse false) common.closed();
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

/// What OrielVideo reports (the "video" system event, main thread).
pub const Report = union(enum) {
    /// The user closed it (button, back, Esc) or its Activity went away.
    closed,
    ended,
    /// It plays, but its sound can't be decoded here.
    audio_unsupported,
    @"error": []const u8,
};

/// "closed", "ended", "audio-unsupported" or "error\n<message>"; null for
/// anything else.
pub fn parseReport(data: []const u8) ?Report {
    if (std.mem.eql(u8, data, "closed")) return .closed;
    if (std.mem.eql(u8, data, "ended")) return .ended;
    if (std.mem.eql(u8, data, "audio-unsupported")) return .audio_unsupported;
    if (std.mem.startsWith(u8, data, "error\n")) return .{ .@"error" = data["error\n".len..] };
    if (std.mem.eql(u8, data, "error")) return .{ .@"error" = "playback failed" };
    return null;
}

/// The "video" system event (src/platform/android/android.zig).
pub fn onSystemEvent(data: []const u8) void {
    switch (parseReport(data) orelse return) {
        .closed => common.closed(),
        .ended => common.ended(),
        .audio_unsupported => common.audioUnsupported(),
        .@"error" => |m| common.failed(m),
    }
}

test parseReport {
    try std.testing.expectEqual(Report.closed, parseReport("closed").?);
    try std.testing.expectEqual(Report.ended, parseReport("ended").?);
    try std.testing.expectEqual(Report.audio_unsupported, parseReport("audio-unsupported").?);
    try std.testing.expectEqualStrings("MEDIA_ERROR_UNSUPPORTED (-1010)", parseReport("error\nMEDIA_ERROR_UNSUPPORTED (-1010)").?.@"error");
    try std.testing.expectEqualStrings("playback failed", parseReport("error").?.@"error");
    try std.testing.expect(parseReport("paused") == null);
}
