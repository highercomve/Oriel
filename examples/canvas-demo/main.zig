const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

var io: std.Io = undefined;

pub const Commands = struct {};
pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.CanvasDemo",
        .title = "Oriel canvas demo",
        .width = 480,
        .height = 400,
        .assets = app.assets,
        .dev = app.dev,
    });
}
