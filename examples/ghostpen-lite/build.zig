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
        .whisper = true,
        .audio_capture = true,
        // Live captions on the GPU: zig build -Dcuda (needs the CUDA toolkit).
        .ggml_cuda = b.option(bool, "cuda", "Run whisper on the GPU (builds libggml-cuda.so)") orelse false,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "ghostpen-lite",
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"),
        .frontend = .{
            .dir = "web",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "com.ghostpen.lite",
            .name = "GhostPen Lite",
            .summary = "Global hotkey text rewrite tool",
            .description = "GhostPen Lite is a lightweight desktop utility for rewriting text via global hotkey.",
            .categories = "Utility;",
            .version = "0.1.0",
            .license = "MIT",
        },
    });
}
