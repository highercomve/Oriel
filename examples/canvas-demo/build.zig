const std = @import("std");
const oriel = @import("oriel");

/// <canvas> in the native renderer: a page of drawings and a game loop.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = b.option(bool, "native_ui", "Draw the page with native widgets instead of a WebView (experimental)") orelse false,
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-canvas-demo",
        .root_source_file = b.path("main.zig"),
        .frontend = .{
            .dir = "web",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "dev.oriel.CanvasDemo",
            .name = "Oriel Canvas Demo",
            .summary = "A canvas page in the native renderer",
            .version = "0.1.0",
        },
    });
}
