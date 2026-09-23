const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Every module and plugin is enabled by default; the smoke test checks them all.
    const dep = b.dependency("oriel", .{ .target = target, .optimize = optimize });

    _ = oriel.addApp(b, dep, .{
        .name = "oriel-smoke",
        .root_source_file = b.path("main.zig"),
        // A static page: no npm, no dev server, embedded as-is.
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
