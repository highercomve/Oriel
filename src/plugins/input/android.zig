//! Synthetic input on Android, where apps can't type into other apps:
//! the same API, so one app source builds everywhere. Every
//! call fails with `error.Unsupported`, and `check` reports it as
//! unavailable (apps fall back to a manual copy/paste flow).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const target = @import("../../core/target.zig");

pub fn keyCombo(combo: []const u8) !void {
    _ = combo;
    return error.Unsupported;
}

pub fn typeText(text: []const u8) !void {
    _ = text;
    return error.Unsupported;
}

pub fn copy() !void {
    return error.Unsupported;
}

pub fn paste() !void {
    return error.Unsupported;
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "input", .ok = false, .detail = "apps can't type into other apps on " ++ target.name };
}
