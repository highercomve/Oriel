//! GPU backends for ggml (shared by the whisper and llama modules).
//!
//! CUDA and Vulkan are separate libraries next to the executable (built with
//! `-Dggml_cuda` / `-Dggml_vulkan`, installed by `addApp`), loaded at
//! runtime; Metal (macOS) is compiled in and registers itself. Without a
//! usable GPU, ggml keeps running on the CPU backend.

const std = @import("std");

const c = @cImport({
    @cInclude("ggml-backend.h");
});

/// The GPU backend libraries, in order of preference. The first one that
/// registers a GPU wins: CUDA and Vulkan would both drive an NVIDIA card,
/// and ggml would then split a model across the "two" devices.
const libraries = [_][]const u8{ "libggml-cuda.so", "libggml-vulkan.so" };

/// Load the GPU backend libraries found in the executable's directory
/// (`libggml-cuda.so`, else `libggml-vulkan.so`). Only that directory is
/// searched, never the current directory. Call once, before loading a model.
/// Returns the number of GPU devices available afterwards; 0 means the
/// models run on the CPU.
pub fn load(io: std.Io) usize {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &dir_buf) catch |err| {
        std.log.warn("ggml: cannot find the executable directory ({s}); CPU only", .{@errorName(err)});
        return gpuCount();
    };
    for (libraries) |name| {
        if (gpuCount() > 0) break;
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}{c}{s}", .{ dir_buf[0..n], std.fs.path.sep, name }) catch continue;
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        pin(path);
        // Logs and returns null when it can't load (no driver, no Vulkan loader).
        _ = c.ggml_backend_load(path.ptr);
    }
    return gpuCount();
}

/// Keep a backend library mapped for the life of the process. When its
/// backend finds no device, ggml unloads it again, but a Zig-built library
/// (libggml-vulkan.so) leaves its C++ static destructors registered with
/// atexit (no `__cxa_finalize` on unload): exit would then jump into
/// unmapped code. Pinned, ggml's dlclose leaves it in place. If it can't be
/// opened (e.g. no Vulkan loader), neither can ggml, and nothing stays.
fn pin(path: [:0]const u8) void {
    if (@import("builtin").os.tag == .windows) return;
    _ = std.c.dlopen(path.ptr, .{ .NOW = true, .NODELETE = true });
}

/// Number of registered GPU devices.
pub fn gpuCount() usize {
    var n: usize = 0;
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (c.ggml_backend_dev_type(dev) == c.GGML_BACKEND_DEVICE_TYPE_GPU) n += 1;
    }
    return n;
}

/// Description of the first GPU device (e.g. "NVIDIA GeForce RTX 4070"), or
/// null when there is none. Points into ggml's static device data.
pub fn gpuName() ?[:0]const u8 {
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (c.ggml_backend_dev_type(dev) != c.GGML_BACKEND_DEVICE_TYPE_GPU) continue;
        const desc: ?[*:0]const u8 = c.ggml_backend_dev_description(dev);
        return if (desc) |d| std.mem.span(d) else "GPU";
    }
    return null;
}

test "GPU count and name agree" {
    // Linux/Windows: the test binary has no libggml-cuda.so next to it, so
    // nothing is registered. macOS: the built-in Metal backend (default on)
    // registers the GPU by itself.
    const n = gpuCount();
    try std.testing.expectEqual(n == 0, gpuName() == null);
    if (@import("builtin").os.tag != .macos) try std.testing.expectEqual(@as(usize, 0), n);
}
