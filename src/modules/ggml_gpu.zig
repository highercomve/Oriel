//! GPU backends for ggml (shared by the whisper and llama modules).
//!
//! CUDA is a separate library next to the executable (built with
//! `-Dggml_cuda`, installed by `addApp`), loaded at runtime; Metal (macOS)
//! is compiled in and registers itself. Without a usable GPU, ggml keeps
//! running on the CPU backend.

const std = @import("std");

const c = @cImport({
    @cInclude("ggml-backend.h");
});

/// Load the GPU backend libraries (`libggml-cuda.so`, ...) found in the
/// executable's directory. Only that directory is searched, never the current
/// directory. Call once, before loading a model. Returns the number of GPU
/// devices available afterwards; 0 means the models run on the CPU.
pub fn load(io: std.Io) usize {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (std.process.executableDirPath(io, buf[0 .. buf.len - 1])) |n| {
        buf[n] = 0;
        c.ggml_backend_load_all_from_path(@ptrCast(&buf));
    } else |err| {
        std.log.warn("ggml: cannot find the executable directory ({s}); CPU only", .{@errorName(err)});
    }
    return gpuCount();
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
