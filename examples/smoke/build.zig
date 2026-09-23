const std = @import("std");
const ziguri = @import("ziguri");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Every module and plugin is enabled by default; the smoke test checks them all.
    const dep = b.dependency("ziguri", .{ .target = target, .optimize = optimize });

    _ = ziguri.addApp(b, dep, .{
        .name = "ziguri-smoke",
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
