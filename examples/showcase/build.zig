const std = @import("std");
const oriel = @import("oriel");

/// Oriel Showcase: every feature Oriel has, in one app that builds for
/// Linux, Windows, macOS, Android and iOS. Dictation (whisper or the
/// system recognizer, live, files), windows, events, the clipboard,
/// notifications, dialogs, the store and SQLite, deep links, keyboard
/// shortcuts, and per platform: the tray, menus and typing into other apps
/// (desktop), the Quick Settings tile, notification actions and the
/// keyboard (Android), background audio (iOS).
///
///   zig build run                                desktop
///   zig build -Dtarget=aarch64-linux-android     zig-out/jniLibs/arm64-v8a/liboriel.so (docs/android.md)
///   zig build -Dtarget=x86_64-linux-android      zig-out/jniLibs/x86_64/liboriel.so (emulator)
///   zig build -Dtarget=aarch64-ios -Dapple_sdk=… zig-out/ios/Oriel Showcase.app (docs/ios.md)
///   zig build -Dtarget=aarch64-ios-simulator …   for the simulator
///   -Dggml_vulkan -Dggml_opencl                  whisper on the GPU (Linux, Windows, Android)
///   -Dggml_arm=i8mm                              faster CPU kernels (Armv8.6/v9 phones only)
const ArmLevel = enum { baseline, dotprod, i8mm };

pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const android = target.result.abi.isAndroid();
    const ios = target.result.os.tag == .ios;
    const desktop = !android and !ios;
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        // Desktop only: a tray icon, the window menu, typing into other apps.
        .tray = desktop,
        .menu = desktop,
        .input = desktop,
        // System-wide hotkeys on the desktop, in-app shortcuts on Android
        // (Meta+/ lists them); iOS has neither.
        .global_shortcut = !ios,
        .updater = false,
        .media_server = false,
        .fs_watch = false,
        .sql = true, // Data: notes in SQLite
        .deep_link = true, // oriel-showcase://note/<text>
        .dialog = true, // open and save files, transcribe a recording
        // The Dictate tab: whisper on the microphone. GPU backends:
        // -Dggml_vulkan (any GPU), -Dggml_opencl (Adreno); without them, the CPU.
        .whisper = true,
        // The Chat tab: llama.cpp (oriel.chat), same GPU backends as whisper.
        .llama = true,
        .audio_capture = true,
        .ggml_vulkan = b.option(bool, "ggml_vulkan", "Run whisper on the GPU through Vulkan") orelse false,
        .ggml_opencl = b.option(bool, "ggml_opencl", "Run whisper on Adreno GPUs through OpenCL") orelse false,
        // Desktop Linux with an NVIDIA GPU: builds ggml's CUDA backend with
        // nvcc into libggml-cuda.so, installed next to the executable by
        // addApp. Needs the CUDA toolkit (-Dcuda_path, default $CUDA_PATH or
        // /opt/cuda). With CUDA and Vulkan both built, CUDA is tried first.
        .ggml_cuda = b.option(bool, "ggml_cuda", "Run whisper and chat on NVIDIA GPUs through CUDA (Linux)") orelse false,
        .cuda_path = b.option([]const u8, "cuda_path", "CUDA toolkit root for -Dggml_cuda (default: $CUDA_PATH or /opt/cuda)"),
        .cuda_arch = b.option([]const u8, "cuda_arch", "nvcc -arch value, or compute capabilities like 75,86,89,120 (default: native)"),
        .cuda_static = b.option(bool, "cuda_static", "Link cuBLAS statically: needs only the NVIDIA driver at runtime (default: false)") orelse false,
        // ARM extensions for whisper's CPU kernels (Oriel's -Dggml_arm).
        .ggml_arm = b.option(ArmLevel, "ggml_arm", "ARM extensions for whisper on the CPU: baseline, dotprod (Android default), i8mm") orelse
            if (target.result.abi.isAndroid() and target.result.cpu.arch == .aarch64) ArmLevel.dotprod else .baseline,
    });

    _ = oriel.addApp(b, dep, .{
        .name = "oriel-showcase",
        .root_source_file = b.path("src/main.zig"),
        .frontend = .{
            .dir = "web",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "dev.oriel.Showcase",
            .name = "Oriel Showcase",
            .summary = "Everything Oriel does, on every platform",
            .description = "Dictation, windows, the clipboard, notifications, files, storage, deep links and shortcuts: one app for Linux, Windows, macOS, Android and iOS.",
            .categories = "Utility;Development;",
            .version = "0.1.0",
            .url_schemes = &.{"oriel-showcase"},
        },
        .permissions = .{
            .notifications = "",
            .microphone = "Dictation turns what you say into text, on this device.",
        },
        // iOS: keep dictating when the app goes to the background.
        .ios = .{ .background_audio = true },
        // Android: dictate anywhere from a Quick Settings tile and a keyboard.
        .android = .{ .tile = "Dictate anywhere", .input_method = "Oriel dictation" },
    });
}
