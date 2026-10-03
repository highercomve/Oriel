const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

/// BREAKOUT_DEMO=<balls>: the page plays itself with that many balls and
/// logs its frame rate (for comparing the renderers).
var demo_balls: ?[]const u8 = null;

pub const Commands = struct {
    /// The demo's ball count, or null to play.
    pub fn demo(_: std.mem.Allocator) ?[]const u8 {
        return demo_balls;
    }

    /// A line from the page to the app's log (the demo's frame rates).
    pub fn log(_: std.mem.Allocator, args: struct { line: []const u8 }) void {
        std.log.info("breakout: {s}", .{args.line});
    }
};
pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    if (init.environ_map.get("BREAKOUT_DEMO")) |n| {
        if (n.len > 0) demo_balls = try init.arena.allocator().dupe(u8, n);
    }
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.Breakout",
        .title = "Breakout",
        .width = 900,
        .height = 700,
        .assets = app.assets,
        .dev = app.dev,
    });
}
