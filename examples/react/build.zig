const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Only the modules this app uses; the rest aren't compiled or linked.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .sql = true,
        .tray = true,
        .updater = false,
        .media_server = false,
        .fs_watch = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = false,
    });

    // zig build        production build (vite build, embedded)
    // zig build run    run it
    // zig build dev    Vite dev server + hot reload
    // zig build types  regenerate frontend/src/oriel.ts
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-react-notes",
        .root_source_file = b.path("src/main.zig"),
        .frontend = .{ .dir = "frontend" },
    });
}
