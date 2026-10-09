//! GPU backends for ggml (shared by the whisper and llama modules).
//!
//! CUDA and Vulkan are separate libraries next to the executable (built with
//! `-Dggml_cuda` / `-Dggml_vulkan`, installed by `addApp`), loaded at
//! runtime; Metal (macOS) is compiled in and registers itself. On Windows,
//! Vulkan is compiled in and registered here when vulkan-1.dll is present.
//! Without a usable GPU, ggml keeps running on the CPU backend.
//!
//! Android (`loadAndroid`): the NPU or GPU backend that passes a self-test
//! against the CPU, in this order: Hexagon (Snapdragon NPU,
//! libggml-hexagon.so shipped in the APK with -Dggml_hexagon_prebuilt),
//! OpenCL (compiled in with -Dggml_opencl, Adreno GPUs only), Vulkan
//! (compiled in with -Dggml_vulkan, any GPU). A device whose name matches
//! `$ORIEL_GGML_BLOCKLIST` (comma-separated substrings) is skipped, and
//! `ORIEL_GGML_CPU=1` keeps everything on the CPU.

const std = @import("std");
const options = @import("build_options");

const c = @cImport({
    // Zig defines _FORTIFY_SOURCE in optimized builds; translate-c can't
    // read the NDK's fortified <stdio.h> (Android release builds failed).
    // The C code itself is compiled with its own flags.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("ggml.h");
    @cInclude("ggml-alloc.h");
    @cInclude("ggml-backend.h");
});

const is_android = @import("builtin").abi.isAndroid();
/// Android -Dggml_opencl: ggml-opencl is in liboriel.so.
const opencl_static = @hasDecl(options, "ggml_opencl_static") and options.ggml_opencl_static;
const cl = if (opencl_static) struct {
    extern fn ggml_backend_opencl_reg() c.ggml_backend_reg_t;
    /// src/modules/ggml_opencl_loader.c: libOpenCL.so found and loaded.
    extern fn oriel_opencl_loader_available() c_int;
} else struct {};

/// Windows -Dggml_vulkan: ggml-vulkan is in the executable.
const vulkan_static = @hasDecl(options, "ggml_vulkan_static") and options.ggml_vulkan_static;
const vk = if (vulkan_static) struct {
    extern fn ggml_backend_vk_reg() c.ggml_backend_reg_t;
    /// src/modules/ggml_vulkan_loader.c: vulkan-1.dll found and loaded.
    extern fn oriel_vulkan_loader_available() c_int;
    /// Around the instance creation: without implicit (presentation) layers.
    extern fn oriel_vulkan_layers_begin() void;
    extern fn oriel_vulkan_layers_end() void;
} else struct {};

/// The GPU backend libraries, in order of preference. The first one that
/// registers a GPU wins: CUDA and Vulkan would both drive an NVIDIA card,
/// and ggml would then split a model across the "two" devices.
const libraries = [_][]const u8{ "libggml-cuda.so", "libggml-vulkan.so" };

/// Load the GPU backend libraries found in the executable's directory
/// (`libggml-cuda.so`, else `libggml-vulkan.so`). Only that directory is
/// searched, never the current directory. Call before loading a model; safe
/// from several threads (serialized: ggml's backend registry isn't
/// thread-safe, and on Windows the Vulkan instance is created here).
/// Returns the number of GPU devices available afterwards; 0 means the
/// models run on the CPU.
/// Whether this CPU has the ARM extensions ggml was compiled for
/// (`-Dggml_arm`): false means running a model would crash with SIGILL.
/// The whisper and llama modules check it before loading a model.
pub fn cpuSupported() bool {
    const builtin = @import("builtin");
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .linux) return true;
    const level = if (@hasDecl(options, "ggml_arm")) @tagName(options.ggml_arm) else "baseline";
    if (std.mem.eql(u8, level, "baseline")) return true;
    // <asm/hwcap.h>: FPHP, ASIMDHP, ASIMDDP; HWCAP2_I8MM.
    const hwcap = std.c.getauxval(16); // AT_HWCAP
    const need: c_ulong = (1 << 9) | (1 << 10) | (1 << 20);
    if (hwcap & need != need) return false;
    if (std.mem.eql(u8, level, "i8mm")) return std.c.getauxval(26) & (1 << 13) != 0; // AT_HWCAP2
    return true;
}

pub fn load(io: std.Io) usize {
    load_mutex.lockUncancelable(io);
    defer load_mutex.unlock(io);
    if (is_android) return loadAndroid();
    // Windows has no loadable backends (Vulkan is compiled in).
    const n = if (@import("builtin").os.tag == .windows) gpuCount() else loadLibraries(io);
    if (vulkan_static and n == 0 and !vulkan_registered) {
        if (vk.oriel_vulkan_loader_available() != 0) {
            // Creates the instance and enumerates the Vulkan devices; none
            // usable leaves the CPU.
            vk.oriel_vulkan_layers_begin();
            const reg = vk.ggml_backend_vk_reg();
            vk.oriel_vulkan_layers_end();
            c.ggml_backend_register(reg);
            vulkan_registered = true;
        } else std.log.info("ggml: no Vulkan loader (vulkan-1.dll); CPU only", .{});
        return gpuCount();
    }
    return n;
}

/// Registered once: ggml keeps a list, and a second registration would
/// list the same GPUs twice. Guarded by `load_mutex`.
var vulkan_registered = false;
var load_mutex: std.Io.Mutex = .init;

fn loadLibraries(io: std.Io) usize {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = testLibDir(&dir_buf) orelse std.process.executableDirPath(io, &dir_buf) catch |err| {
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

/// Unit tests: `zig build test -Dggml_vulkan` (or -Dggml_cuda) installs the
/// library in zig-out/lib and points $ORIEL_GGML_LIB_DIR there.
fn testLibDir(buf: []u8) ?usize {
    if (!@import("builtin").is_test or @import("builtin").os.tag == .windows) return null;
    const dir = std.mem.span(std.c.getenv("ORIEL_GGML_LIB_DIR") orelse return null);
    if (dir.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    return dir.len;
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

/// A device that takes work off the CPU. Android GPUs are integrated
/// (Vulkan reports them as IGPU).
fn isGpu(dev: c.ggml_backend_dev_t) bool {
    const t = c.ggml_backend_dev_type(dev);
    return t == c.GGML_BACKEND_DEVICE_TYPE_GPU or (is_android and t == c.GGML_BACKEND_DEVICE_TYPE_IGPU);
}

/// Number of registered GPU devices.
pub fn gpuCount() usize {
    var n: usize = 0;
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (isGpu(dev)) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Android
// ---------------------------------------------------------------------------

var android_loaded = false;
var android_backend: ?[]const u8 = null;

/// The backend `load` chose on Android ("Hexagon", "OpenCL", "Vulkan"), or
/// null for the CPU.
pub fn backendName() ?[]const u8 {
    return android_backend;
}

fn loadAndroid() usize {
    if (android_loaded) return gpuCount();
    android_loaded = true;
    if (std.c.getenv("ORIEL_GGML_CPU")) |v| if (v[0] == '1') {
        std.log.info("ggml: ORIEL_GGML_CPU=1: CPU only", .{});
        return 0;
    };
    // Snapdragon NPU: the APK has libggml-hexagon.so only when built with it.
    if (c.ggml_backend_load("libggml-hexagon.so")) |reg| {
        if (regPasses(reg, null)) {
            android_backend = "Hexagon";
            return gpuCount();
        }
        c.ggml_backend_unload(reg);
    }
    if (opencl_static and cl.oriel_opencl_loader_available() != 0) {
        const reg = cl.ggml_backend_opencl_reg();
        // ggml's OpenCL kernels are written for Adreno: other GPUs use Vulkan.
        if (reg != null and regPasses(reg, "Adreno")) {
            c.ggml_backend_register(reg);
            android_backend = "OpenCL";
            return gpuCount();
        }
    }
    if (vulkan_static and vk.oriel_vulkan_loader_available() != 0) {
        const reg = vk.ggml_backend_vk_reg();
        if (reg != null and regPasses(reg, null)) {
            c.ggml_backend_register(reg);
            vulkan_registered = true;
            android_backend = "Vulkan";
            return gpuCount();
        }
    }
    std.log.info("ggml: no usable GPU or NPU; CPU only", .{});
    return 0;
}

/// Whether the registration's first GPU is usable: not blocklisted, named
/// like `require` if given, and computing a matrix product like the CPU.
fn regPasses(reg: c.ggml_backend_reg_t, require: ?[]const u8) bool {
    for (0..c.ggml_backend_reg_dev_count(reg)) |i| {
        const dev = c.ggml_backend_reg_dev_get(reg, i) orelse continue;
        if (!isGpu(dev)) continue;
        const name = std.mem.span(@as([*:0]const u8, c.ggml_backend_dev_description(dev) orelse "GPU"));
        if (require) |r| if (std.mem.indexOf(u8, name, r) == null) {
            std.log.info("ggml: {s} ({s}) skipped: not {s}", .{ name, std.mem.span(c.ggml_backend_reg_name(reg)), r });
            return false;
        };
        if (blocked(name)) {
            std.log.info("ggml: {s} is in $ORIEL_GGML_BLOCKLIST", .{name});
            return false;
        }
        const ok = selfTest(dev);
        std.log.info("ggml: {s} ({s}) self-test {s}", .{ name, std.mem.span(c.ggml_backend_reg_name(reg)), if (ok) "passed" else "FAILED: CPU instead" });
        return ok;
    }
    return false;
}

fn blocked(name: []const u8) bool {
    const list = std.c.getenv("ORIEL_GGML_BLOCKLIST") orelse return false;
    return blockedBy(std.mem.span(list), name);
}

fn blockedBy(list: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |entry| {
        const needle = std.mem.trim(u8, entry, " ");
        if (needle.len > 0 and std.ascii.indexOfIgnoreCase(name, needle) != null) return true;
    }
    return false;
}

test blockedBy {
    try std.testing.expect(blockedBy("mali-g57, PowerVR", "Mali-G57 MC2"));
    try std.testing.expect(!blockedBy("Mali-G57", "Adreno (TM) 740"));
    try std.testing.expect(!blockedBy("", "Adreno"));
}

/// A 64x32 * 32x16 matrix product on `dev`, compared with the same product
/// computed here: drivers that load but compute garbage (it happens on
/// mobile GPUs) are caught before a model runs on them.
pub fn selfTest(dev: c.ggml_backend_dev_t) bool {
    const k = 32;
    const m = 64;
    const n = 16;
    var a: [m * k]f32 = undefined;
    var b: [n * k]f32 = undefined;
    for (&a, 0..) |*v, i| v.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 7)) - 3)) * 0.25;
    for (&b, 0..) |*v, i| v.* = @as(f32, @floatFromInt(@as(i32, @intCast(i % 5)) - 2)) * 0.5;

    const backend = c.ggml_backend_dev_init(dev, null) orelse return false;
    defer c.ggml_backend_free(backend);
    const ctx = c.ggml_init(.{ .mem_size = 16 * c.ggml_tensor_overhead() + c.ggml_graph_overhead(), .mem_buffer = null, .no_alloc = true }) orelse return false;
    defer c.ggml_free(ctx);
    // ggml_mul_mat(A[k,m], B[k,n]) = [m,n]: each row of A dotted with each row of B.
    const ta = c.ggml_new_tensor_2d(ctx, c.GGML_TYPE_F32, k, m);
    const tb = c.ggml_new_tensor_2d(ctx, c.GGML_TYPE_F32, k, n);
    const tc = c.ggml_mul_mat(ctx, ta, tb);
    const buf = c.ggml_backend_alloc_ctx_tensors(ctx, backend) orelse return false;
    defer c.ggml_backend_buffer_free(buf);
    c.ggml_backend_tensor_set(ta, &a, 0, @sizeOf(@TypeOf(a)));
    c.ggml_backend_tensor_set(tb, &b, 0, @sizeOf(@TypeOf(b)));
    const graph = c.ggml_new_graph(ctx);
    c.ggml_build_forward_expand(graph, tc);
    if (c.ggml_backend_graph_compute(backend, graph) != c.GGML_STATUS_SUCCESS) return false;
    var out: [m * n]f32 = undefined;
    c.ggml_backend_tensor_get(tc, &out, 0, @sizeOf(@TypeOf(out)));
    for (0..n) |j| for (0..m) |i| {
        var want: f32 = 0;
        for (0..k) |x| want += a[i * k + x] * b[j * k + x];
        // f16 accumulation on some GPUs: a loose tolerance.
        if (!(@abs(out[j * m + i] - want) <= 0.05 + 0.01 * @abs(want))) return false;
    };
    return true;
}

/// Description of the first GPU device (e.g. "NVIDIA GeForce RTX 4070",
/// "Adreno (TM) 740"), or null when there is none. Counts what `gpuCount`
/// counts, so Android's integrated GPUs too. Points into ggml's static
/// device data.
pub fn gpuName() ?[:0]const u8 {
    for (0..c.ggml_backend_dev_count()) |i| {
        const dev = c.ggml_backend_dev_get(i) orelse continue;
        if (!isGpu(dev)) continue;
        const desc: ?[*:0]const u8 = c.ggml_backend_dev_description(dev);
        return if (desc) |d| std.mem.span(d) else "GPU";
    }
    return null;
}

test "GPU count and name agree" {
    // Linux/Windows: the test binary has no libggml-cuda.so next to it and
    // load() isn't called, so nothing is registered. macOS: the built-in
    // Metal backend (default on) registers the GPU by itself.
    const n = gpuCount();
    try std.testing.expectEqual(n == 0, gpuName() == null);
    // (Unless a GPU library was installed for the tests and a test loaded it.)
    const test_lib = if (@import("builtin").os.tag == .windows) false else std.c.getenv("ORIEL_GGML_LIB_DIR") != null;
    if (@import("builtin").os.tag != .macos and !test_lib) try std.testing.expectEqual(@as(usize, 0), n);
}

test "selfTest passes on the CPU" {
    const cpu = c.ggml_backend_dev_by_type(c.GGML_BACKEND_DEVICE_TYPE_CPU) orelse return error.SkipZigTest;
    try std.testing.expect(selfTest(cpu));
}
