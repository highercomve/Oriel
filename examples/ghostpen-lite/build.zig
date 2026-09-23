const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .global_shortcut = true,
        .input = true,
        .clipboard = true,
        .tray = true,
        .dialog = true,
        .notification = true,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "ghostpen-lite",
        .root_source_file = b.path("src/main.zig"),
        .frontend = .{
            .dir = "web",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
    });
}
