//! Tray on Android (no system tray): the same API, so
//! one app source builds everywhere. `Tray.create` fails with
//! `error.Unsupported`; apps already handle a missing tray (no watcher on
//! Linux, Explorer not running on Windows).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const target = @import("../../core/target.zig");
pub const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;

pub const Tray = struct {
    pub fn create(gpa: std.mem.Allocator, options: Options) !*Tray {
        _ = gpa;
        _ = options;
        return error.Unsupported;
    }
    pub fn deinit(self: *Tray) void {
        _ = self;
    }
    pub fn setMenu(self: *Tray, items: []const MenuItem) !void {
        _ = self;
        _ = items;
    }
    pub fn setChecked(self: *Tray, id: []const u8, checked: bool) void {
        _ = self;
        _ = id;
        _ = checked;
    }
    pub fn isChecked(self: *Tray, id: []const u8) ?bool {
        _ = self;
        _ = id;
        return null;
    }
    pub fn setTooltip(self: *Tray, tooltip: []const u8) !void {
        _ = self;
        _ = tooltip;
    }
    pub fn setTitle(self: *Tray, title: []const u8) !void {
        _ = self;
        _ = title;
    }
    pub fn setIcon(self: *Tray, icon: Icon) !void {
        _ = self;
        _ = icon;
    }
};

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "tray", .ok = true, .detail = "no system tray on " ++ target.name ++ " (stub)" };
}
