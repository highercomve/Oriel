//! macOS backend: not implemented yet (NSStatusItem + NSMenu is the plan,
//! PLAN.md Milestone 7 step 2). `Tray.create` fails with error.NotSupported,
//! so apps that set up a tray still run without one.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;

pub const Tray = struct {
    pub fn create(_: std.mem.Allocator, _: Options) !*Tray {
        return error.NotSupported;
    }

    // `create` never returns a Tray, so these can't be reached; they keep the
    // API identical to the other backends.
    pub fn deinit(_: *Tray) void {}

    pub fn setMenu(_: *Tray, _: []const MenuItem) !void {
        return error.NotSupported;
    }

    pub fn setChecked(_: *Tray, _: []const u8, _: bool) void {}

    pub fn isChecked(_: *Tray, _: []const u8) ?bool {
        return null;
    }

    pub fn setTooltip(_: *Tray, _: []const u8) !void {
        return error.NotSupported;
    }

    pub fn setTitle(_: *Tray, _: []const u8) !void {
        return error.NotSupported;
    }

    pub fn setIcon(_: *Tray, _: Icon) !void {
        return error.NotSupported;
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "tray",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "not implemented on macOS yet", .{}),
    };
}
