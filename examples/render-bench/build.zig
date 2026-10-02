const std = @import("std");
const oriel = @import("oriel");

/// Render speed of the two renderers on one page: `zig build` (WebView) and
/// `zig build -Dnative_ui` (native widgets). See README.md.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = b.option(bool, "native_ui", "Draw the page with native widgets instead of a WebView (experimental)") orelse false,
        // -Dnative_ui_prof: the native renderer logs its stage timings.
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
        // -Dnative_dom=false: the native renderer on linkedom instead of the
        // native DOM (docs/native-dom.md); unset, Oriel's default.
        .native_dom = b.option(bool, "native_dom", "With -Dnative_ui: the native DOM (default), or linkedom when false"),
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-render-bench",
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
        .package = .{
            .id = "dev.oriel.RenderBench",
            .name = "Oriel Render Bench",
            .summary = "WebView vs native renderer speed",
            .description = "Times building, updating and animating DOM content in Oriel's WebView and native renderers.",
            .categories = "Development;",
            .version = "0.1.0",
        },
    });
}
