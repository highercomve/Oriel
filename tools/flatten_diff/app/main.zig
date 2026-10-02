//! The page tools/flatten_diff/run.sh writes (web/index.html), in the native
//! renderer: ORIEL_NUI_DUMP=1 prints its laid-out tree after it booted.
const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

pub const Commands = struct {};
pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.FlattenDiff",
        .title = "Oriel flatten diff",
        .width = 900,
        .height = 700,
        .assets = app.assets,
        .dev = app.dev,
    });
}
