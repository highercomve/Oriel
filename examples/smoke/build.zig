const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Every module and plugin is enabled by default; the smoke test checks them all.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .deep_link = true,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "oriel-smoke",
        .root_source_file = b.path("main.zig"),
        .icon = b.path("web/icon.png"),
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
            .id = "dev.oriel.Smoke",
            .name = "Oriel Smoke",
            .summary = "Oriel framework smoke test",
            .description = "Smoke-test app checking modules and security inside a webview.",
            .categories = "Utility;Development;",
            .version = "0.1.0",
            .url_schemes = &.{"smoke-scheme"},
        },
    });
}
