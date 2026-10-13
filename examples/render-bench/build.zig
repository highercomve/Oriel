const std = @import("std");
const oriel = @import("oriel");

/// Render speed of the three renderers on one page: `-Drenderer=webview`
/// (default), `native` (the page on native widgets) and `oriel` (compiled
/// .oriel views, no JavaScript). See README.md.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const Renderer = enum { webview, native, oriel };
    const renderer = b.option(Renderer, "renderer", "Renderer: webview, native, or oriel (.oriel views)") orelse .webview;
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = renderer != .webview,
        .zig_ui = renderer == .oriel,
        // -Dnative_ui_prof: the native renderer logs its stage timings.
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-render-bench",
        .root_source_file = b.path("main.zig"),
        // A static page: no npm, no dev server, embedded as-is.
        .frontend = .{
            .dir = if (renderer == .oriel) "views" else "web",
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
