const std = @import("std");
const oriel = @import("oriel");

/// Breakout: a canvas game with an HTML interface around it, for comparing
/// the native renderer with the WebView.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = b.option(bool, "native_ui", "Draw the page with native widgets instead of a WebView (experimental)") orelse false,
        // -Dnative_ui_prof: the native renderer logs its stage timings.
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-breakout",
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
            .id = "dev.oriel.Breakout",
            .name = "Breakout",
            .summary = "Breakout in a canvas, native renderer or WebView",
            .version = "0.1.0",
        },
    });
}
