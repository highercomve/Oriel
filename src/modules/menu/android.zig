//! Menu bar on Android (there is none): the same API, so one
//! app source builds everywhere. The platform's `setMenu` already returns
//! `error.NotSupported`.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const target = @import("../../core/target.zig");
pub const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

pub fn set(app: anytype, items: []const MenuItem, on_action: ActionCallback) !void {
    _ = app;
    _ = items;
    _ = on_action;
    return error.Unsupported;
}

pub fn check(_: std.mem.Allocator, _: anytype) !oriel.Check {
    return .{ .module = "menu", .ok = true, .detail = "no menu bar on " ++ target.name ++ " (stub)" };
}
