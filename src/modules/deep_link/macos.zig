//! macOS backend for deep links.
//!
//! Pending PLAN.md Milestone 7 step 3 (.app bundles with CFBundleURLTypes).
//! Stubs are provided so code compiles cleanly across platforms.

const std = @import("std");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

pub fn setDeclaredSchemes(_: []const []const u8) void {}

pub fn onOpen(_: *const fn (url: []const u8) void) void {}

pub fn current() ?[]const u8 {
    return null;
}

pub fn setColdStartUrl(_: []const u8) void {}

pub fn deliver(_: []const u8) void {}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "deep_link",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "not implemented on macOS yet (pending Milestone 7 step 3 .app bundles)", .{}),
    };
}
