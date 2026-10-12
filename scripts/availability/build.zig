//! A stand-in app for scripts/test-availability.sh: it asks for desktop-only
//! modules the way an app does (b.dependency options are intent), for any
//! target. `zig build check` type-checks main.zig; `-Dunguarded` adds a use
//! of oriel.tray outside its guard, which must fail where there's no tray.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .tray = true,
        .menu = true,
        .input = true,
        .global_shortcut = true,
        .fs_watch = true,
        .system_ai = true,
        .sql = false,
    });
    const opts = b.addOptions();
    opts.addOption(bool, "unguarded", b.option(bool, "unguarded", "Use oriel.tray without the guard") orelse false);
    const exe = b.addExecutable(.{
        .name = "availability",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oriel", .module = dep.module("oriel") },
                .{ .name = "fixture_options", .module = opts.createModule() },
            },
        }),
    });
    // Not installed: type-checked only (no codegen, no SDK needed).
    b.step("check", "Type-check the stand-in app").dependOn(&exe.step);
}
