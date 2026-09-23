//! Background clipboard access on Wayland (without window focus) via the
//! data-control protocols. Focused/X11 clipboard goes through GdkClipboard.

const std = @import("std");
const wayland = @import("wayland");
const Globals = @import("wayland_globals.zig").Globals;
const ziguri = @import("../ziguri.zig");

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    var globals: Globals = undefined;
    try globals.init(gpa);
    defer globals.deinit();

    // Prefer the standard ext- protocol, fall back to the wlroots one.
    var protocol: []const u8 = "none";
    if (try globals.bind(wayland.client.ext.DataControlManagerV1, 1)) |m| {
        protocol = "ext_data_control_manager_v1";
        m.destroy();
    } else if (try globals.bind(wayland.client.zwlr.DataControlManagerV1, 2)) |m| {
        protocol = "zwlr_data_control_manager_v1";
        m.destroy();
    }
    return .{
        .module = "clipboard",
        .ok = !std.mem.eql(u8, protocol, "none"),
        .detail = try std.fmt.allocPrint(gpa, "background clipboard via {s}", .{protocol}),
    };
}
