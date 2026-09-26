//! GGML, llama.cpp, and whisper.cpp build configuration for Oriel.
//!
//! Compiles ggml base and ggml-cpu (single shared ggml library), plus
//! llama.cpp and/or whisper.cpp when their corresponding feature is enabled.
//!
//! With `ggml_cuda`, the CUDA backend is built separately by nvcc into
//! `libggml-cuda.so`, which the app loads at runtime (`whisper.loadGpuBackends`,
//! `llama.loadGpuBackends`). It stays a separate library because nvcc's host
//! code uses GCC's libstdc++ while Zig builds C++ against libc++; the ggml
//! backend interface between them is plain C. The library resolves ggml's
//! own symbols from the executable (`rdynamic`, set by `addApp`).
//!
//! With `ggml_vulkan`, the Vulkan backend (any GPU vendor) is built the same
//! way into `libggml-vulkan.so`: its shaders are compiled to SPIR-V with
//! `glslc` by ggml's own generator (vulkan-shaders-gen, built for the host)
//! and embedded. The library links the Vulkan loader, so on a machine without
//! one it doesn't load and ggml stays on the CPU.

const std = @import("std");

pub const CudaOptions = struct {
    /// CUDA toolkit root (contains bin/nvcc and lib64).
    path: []const u8,
    /// nvcc `-arch` value: "native" (the GPUs in this machine), "sm_89",
    /// "all-major", ...; or a comma-separated list of compute capabilities
    /// ("75,86,89,120"): machine code for each, plus PTX for the newest so
    /// later GPUs can still run it.
    arch: []const u8,
    /// Link cuBLAS statically: the library then needs only the NVIDIA
    /// driver (libcuda.so.1), not a CUDA toolkit on the user's machine.
    static: bool = false,
};

/// nvcc arguments selecting the GPU architectures (see `CudaOptions.arch`).
fn cudaArchArgs(b: *std.Build, arch: []const u8) []const []const u8 {
    if (std.mem.indexOfScalar(u8, arch, ',') == null and !isComputeCapability(arch)) {
        return b.allocator.dupe([]const u8, &.{b.fmt("-arch={s}", .{arch})}) catch @panic("OOM");
    }
    var args: std.ArrayList([]const u8) = .empty;
    var ptx: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, arch, ", ");
    while (it.next()) |cc| {
        if (!isComputeCapability(cc)) std.debug.panic("-Dcuda_arch: \"{s}\" is not a compute capability (e.g. 89, 120a)", .{cc});
        args.append(b.allocator, b.fmt("-gencode=arch=compute_{s},code=sm_{s}", .{ cc, cc })) catch @panic("OOM");
        // Architecture-specific targets (120a: Blackwell's FP4 MMA) have no
        // forward-compatible PTX; the newest generic one provides it.
        if (std.ascii.isDigit(cc[cc.len - 1])) ptx = cc;
    }
    if (ptx) |cc| args.append(b.allocator, b.fmt("-gencode=arch=compute_{s},code=compute_{s}", .{ cc, cc })) catch @panic("OOM");
    return args.items;
}

/// "89", or "120a" / "100f" (architecture- and family-specific targets).
fn isComputeCapability(s: []const u8) bool {
    if (s.len < 2) return false;
    const digits = if (s[s.len - 1] == 'a' or s[s.len - 1] == 'f') s[0 .. s.len - 1] else s;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub const VulkanOptions = struct {
    /// The `glslc` shader compiler (shaderc).
    glslc: []const u8,
};

/// Which optional shader extensions `glslc` supports, as ggml's CMake finds
/// them: compile each feature test and look for "extension not supported".
fn vulkanFeatures(b: *std.Build, ggml_root: std.Build.LazyPath, glslc: []const u8) []const []const u8 {
    const tests = [_]struct { ext: []const u8, file: []const u8, define: []const u8 }{
        .{ .ext = "GL_KHR_cooperative_matrix", .file = "coopmat.comp", .define = "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT" },
        .{ .ext = "GL_NV_cooperative_matrix2", .file = "coopmat2.comp", .define = "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT" },
        .{ .ext = "GL_NV_cooperative_matrix_decode_vector", .file = "coopmat2_decode_vector.comp", .define = "GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_integer_dot_product", .file = "integer_dot.comp", .define = "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_bfloat16", .file = "bfloat16.comp", .define = "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_float_e2m1", .file = "float_e2m1.comp", .define = "GGML_VULKAN_FLOAT_E2M1_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_float_e4m3", .file = "float_e4m3.comp", .define = "GGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT" },
    };
    var defines: std.ArrayList([]const u8) = .empty;
    for (tests) |t| {
        const file = ggml_root.path(b, b.fmt("src/ggml-vulkan/vulkan-shaders/feature-tests/{s}", .{t.file})).getPath(b);
        const result = std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ glslc, "-o", "-", "-fshader-stage=compute", "--target-env=vulkan1.3", file },
        }) catch |err| std.debug.panic("-Dggml_vulkan: running {s} failed ({s}); install shaderc or pass -Dglslc", .{ glslc, @errorName(err) });
        const unsupported = std.mem.indexOf(u8, result.stderr, b.fmt("extension not supported: {s}", .{t.ext})) != null;
        if (!unsupported) defines.append(b.allocator, t.define) catch @panic("OOM");
    }
    return defines.items;
}

/// ggml's Metal backend, compiled into the executable. The kernel sources
/// are embedded by tools/metal_embed.zig (GGML_METAL_EMBED_LIBRARY, as
/// ggml's CMake does), so neither Xcode's `metal` compiler nor a .metallib
/// is needed: ggml compiles them for the GPU at startup.
fn addMetalBackend(b: *std.Build, oriel: *std.Build.Module, ggml_root: std.Build.LazyPath, cpp_flags: []const []const u8, metal_defs: []const []const u8) void {
    const metal_dir = ggml_root.path(b, "src/ggml-metal");
    oriel.addIncludePath(metal_dir);
    oriel.addCSourceFiles(.{
        .root = metal_dir,
        .files = &.{ "ggml-metal.cpp", "ggml-metal-device.cpp", "ggml-metal-common.cpp", "ggml-metal-ops.cpp", "ggml-metal-tuning.cpp" },
        .flags = cpp_flags,
    });
    // Objective-C with manual retain/release, like upstream (no ARC).
    const objc_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{ "-fno-objc-arc", "-D_DARWIN_C_SOURCE", "-fno-sanitize=undefined" }, metal_defs }) catch @panic("OOM");
    oriel.addCSourceFiles(.{
        .root = metal_dir,
        .files = &.{ "ggml-metal-device.m", "ggml-metal-context.m" },
        .flags = objc_flags,
    });
    const embed_tool = b.addExecutable(.{
        .name = "metal_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/metal_embed.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(embed_tool);
    run.addDirectoryArg(ggml_root.path(b, "src"));
    oriel.addAssemblyFile(run.addOutputFileArg("ggml-metal-embed.s"));
    oriel.linkFramework("Foundation", .{});
    oriel.linkFramework("Metal", .{});
    oriel.linkFramework("MetalKit", .{});
}

pub fn addGgml(
    b: *std.Build,
    oriel: *std.Build.Module,
    features: anytype,
    cuda: ?CudaOptions,
    vulkan: ?VulkanOptions,
    metal: bool,
) void {
    if (!features.llama and !features.whisper) return;

    const llama_dep = if (features.llama) b.lazyDependency("llama", .{}) else null;
    const whisper_dep = if (features.whisper) b.lazyDependency("whisper", .{}) else null;

    if (features.llama and llama_dep == null) return;
    if (features.whisper and whisper_dep == null) return;

    // Link C++ runtime for ggml/llama/whisper
    oriel.link_libcpp = true;

    // Generated version headers
    const write_files = b.addWriteFiles();
    _ = write_files.add("ggml-version.h",
        \\#pragma once
        \\#define GGML_VERSION "0.23.0"
        \\#define GGML_COMMIT "b10809"
        \\
    );
    if (features.llama) {
        _ = write_files.add("llama-version.h",
            \\#pragma once
            \\#define LLAMA_VERSION "b10809"
            \\#define LLAMA_COMMIT "64a155d"
            \\
        );
    }
    oriel.addIncludePath(write_files.getDirectory());

    // Single ggml tree: pick llama if available, else whisper
    const ggml_dep = llama_dep orelse whisper_dep.?;
    const ggml_root = ggml_dep.path("ggml");

    oriel.addIncludePath(ggml_root.path(b, "include"));
    oriel.addIncludePath(ggml_root.path(b, "src"));
    oriel.addIncludePath(ggml_root.path(b, "src/ggml-cpu"));
    oriel.addIncludePath(ggml_root.path(b, "src/ggml-cpu/amx"));

    // Zig's Debug builds trap on C undefined behaviour; ggml does pointer
    // arithmetic on NULL on purpose (ggml_graph_nbytes sizes a graph that
    // way), so its sanitizer checks are off.
    // _XOPEN_SOURCE hides the BSD types (u_int, ...) that <sys/sysctl.h>
    // needs on macOS unless _DARWIN_C_SOURCE is set too (as ggml's CMake does).
    const darwin: []const []const u8 = if (oriel.resolved_target.?.result.os.tag.isDarwin()) &.{"-D_DARWIN_C_SOURCE"} else &.{};
    // GGML_USE_METAL makes ggml-backend-reg.cpp register the Metal device.
    const metal_defs: []const []const u8 = if (metal) &.{ "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY" } else &.{};
    const c_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{ "-std=c11", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU", "-fno-sanitize=undefined" }, darwin, metal_defs }) catch @panic("OOM");
    const cpp_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{ "-std=c++17", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU", "-fno-sanitize=undefined" }, darwin, metal_defs }) catch @panic("OOM");

    // GGML base sources
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src"),
        .files = &.{
            "ggml.c",
            "ggml-alloc.c",
            "ggml-quants.c",
        },
        .flags = c_flags,
    });
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src"),
        .files = &.{
            "ggml.cpp",
            "ggml-backend.cpp",
            "ggml-backend-meta.cpp",
            "ggml-opt.cpp",
            "ggml-threading.cpp",
            "gguf.cpp",
            "ggml-backend-dl.cpp",
            "ggml-backend-reg.cpp",
        },
        .flags = cpp_flags,
    });

    // GGML CPU backend sources
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src/ggml-cpu"),
        .files = &.{
            "ggml-cpu.c",
            "quants.c",
        },
        .flags = c_flags,
    });
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src/ggml-cpu"),
        .files = &.{
            "binary-ops.cpp",
            "ggml-cpu.cpp",
            "hbm.cpp",
            "iqp.cpp",
            "ops.cpp",
            "repack.cpp",
            "traits.cpp",
            "unary-ops.cpp",
            "vec.cpp",
            "amx/amx.cpp",
            "amx/mmq.cpp",
        },
        .flags = cpp_flags,
    });

    // Arch-specific CPU sources
    const target_arch = oriel.resolved_target.?.result.cpu.arch;
    if (target_arch == .x86_64) {
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/x86/quants.c"},
            .flags = c_flags,
        });
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/x86/repack.cpp"},
            .flags = cpp_flags,
        });
    } else if (target_arch.isArm() or target_arch.isAARCH64()) {
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/arm/quants.c"},
            .flags = c_flags,
        });
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/arm/repack.cpp"},
            .flags = cpp_flags,
        });
    }

    if (cuda) |opts| b.addNamedLazyPath("libggml-cuda", addCudaBackend(b, ggml_root, opts));
    if (vulkan) |opts| b.addNamedLazyPath("libggml-vulkan", addVulkanBackend(b, oriel, ggml_root, write_files.getDirectory(), opts));
    if (metal) addMetalBackend(b, oriel, ggml_root, cpp_flags, metal_defs);

    // llama.cpp sources
    if (features.llama) {
        const l = llama_dep.?;
        oriel.addIncludePath(l.path("include"));
        oriel.addIncludePath(l.path("src"));
        oriel.addIncludePath(l.path("src/models"));

        oriel.addCSourceFiles(.{
            .root = l.path("src"),
            .files = &(llama_core_sources ++ llama_model_sources),
            .flags = cpp_flags,
        });
    }

    // whisper.cpp sources
    if (features.whisper) {
        const w = whisper_dep.?;
        oriel.addIncludePath(w.path("include"));
        oriel.addIncludePath(w.path("src"));

        const whisper_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{
            "-std=c++17",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-DGGML_USE_CPU",
            "-fno-sanitize=undefined",
            "-DWHISPER_VERSION=\"1.9.4\"",
            "-DWHISPER_BUILD_COMMIT=\"v1.9.4\"",
        }, darwin }) catch @panic("OOM");

        oriel.addCSourceFiles(.{
            .root = w.path("src"),
            .files = &.{"whisper.cpp"},
            .flags = whisper_flags,
        });
    }
}

/// Compile ggml-cuda with nvcc (one cached step per source) and link it into
/// a loadable backend module. Returns the path of `libggml-cuda.so`.
fn addCudaBackend(b: *std.Build, ggml_root: std.Build.LazyPath, opts: CudaOptions) std.Build.LazyPath {
    const nvcc = b.pathJoin(&.{ opts.path, "bin", "nvcc" });
    const link = b.addSystemCommand(&.{ nvcc, "-shared", "-o" });
    const lib = link.addOutputFileArg("libggml-cuda.so");
    for (cuda_sources) |src| {
        const cc = b.addSystemCommand(&.{
            nvcc,                    "-std=c++17",        "-O3",
            "-use_fast_math",        "-extended-lambda",  "-compress-mode=size",
            "-Xcompiler",            "-fPIC -Wno-pedantic", "-DNDEBUG",
            // Build as a dynamically loaded backend (exports ggml_backend_init).
            "-DGGML_BACKEND_DL",     "-DGGML_BACKEND_BUILD", "-DGGML_BACKEND_SHARED",
            "-DGGML_SHARED",         "-DGGML_CUDA_USE_GRAPHS", "-DGGML_SCHED_MAX_COPIES=4",
        });
        cc.addArgs(cudaArchArgs(b, opts.arch));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "include"));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "src"));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "src/ggml-cuda"));
        cc.addArg("-c");
        cc.addFileArg(ggml_root.path(b, b.fmt("src/ggml-cuda/{s}", .{src})));
        cc.addArg("-o");
        const obj = cc.addOutputFileArg(b.fmt("{s}.o", .{std.fs.path.stem(src)}));
        link.addFileArg(obj);
    }
    // cudart is linked statically by nvcc; the driver stays dynamic.
    if (opts.static) {
        // Only the kernels ggml calls are kept, but cuBLASLt's are large.
        link.addArgs(cudaArchArgs(b, opts.arch));
        link.addArgs(&.{ "-lcublas_static", "-lcublasLt_static", "-lculibos", "-lcuda" });
    } else {
        link.addArgs(&.{ "-lcublas", "-lcublasLt", "-lcuda" });
    }
    return lib;
}

/// Generate the Vulkan shaders (one cached step per .comp source, as ggml's
/// CMake does) and build `libggml-vulkan.so` from them and ggml-vulkan.cpp.
/// Returns the library's path.
fn addVulkanBackend(
    b: *std.Build,
    oriel: *std.Build.Module,
    ggml_root: std.Build.LazyPath,
    version_headers: std.Build.LazyPath,
    opts: VulkanOptions,
) std.Build.LazyPath {
    const vk_dir = ggml_root.path(b, "src/ggml-vulkan");
    const shaders_dir = vk_dir.path(b, "vulkan-shaders");
    var defines: std.ArrayList([]const u8) = .empty;
    for (vulkanFeatures(b, ggml_root, opts.glslc)) |f| defines.append(b.allocator, b.fmt("-D{s}", .{f})) catch @panic("OOM");

    const gen = b.addExecutable(.{
        .name = "vulkan-shaders-gen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        }),
    });
    gen.root_module.addCSourceFile(.{
        .file = shaders_dir.path(b, "vulkan-shaders-gen.cpp"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ &.{"-std=c++17"}, defines.items }) catch @panic("OOM"),
    });

    const header_name = "ggml-vulkan-shaders.hpp";
    const header = b.addRunArtifact(gen);
    header.addArg("--output-dir");
    _ = header.addOutputDirectoryArg("spv");
    header.addArg("--target-hpp");
    const header_file = header.addOutputFileArg(header_name);

    const lib = b.addLibrary(.{
        .name = "ggml-vulkan",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = oriel.resolved_target.?,
            .optimize = oriel.optimize.?,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    // ggml's own symbols come from the executable (rdynamic), like CUDA's.
    lib.linker_allow_shlib_undefined = true;
    const m = lib.root_module;
    m.linkSystemLibrary("vulkan", .{});
    m.addIncludePath(header_file.dirname());
    m.addIncludePath(version_headers);
    m.addIncludePath(ggml_root.path(b, "include"));
    m.addIncludePath(ggml_root.path(b, "src"));
    m.addIncludePath(vk_dir);
    const flags = std.mem.concat(b.allocator, []const u8, &.{ &.{
        "-std=c++17",           "-D_GNU_SOURCE",       "-DNDEBUG",
        "-fno-sanitize=undefined",
        // Build as a dynamically loaded backend (exports ggml_backend_init).
        "-DGGML_BACKEND_DL",    "-DGGML_BACKEND_BUILD", "-DGGML_BACKEND_SHARED",
        "-DGGML_SHARED",        "-DGGML_SCHED_MAX_COPIES=4",
    }, defines.items }) catch @panic("OOM");
    m.addCSourceFile(.{ .file = vk_dir.path(b, "ggml-vulkan.cpp"), .flags = flags });
    // The header must exist before any source that includes it compiles.
    lib.step.dependOn(&header.step);

    for (vulkan_shader_sources) |src| {
        const run = b.addRunArtifact(gen);
        run.addArgs(&.{ "--glslc", opts.glslc, "--source" });
        run.addFileArg(shaders_dir.path(b, src));
        run.addArg("--output-dir");
        _ = run.addOutputDirectoryArg("spv");
        // Only its basename is used (the #include in the generated source).
        run.addArgs(&.{ "--target-hpp", header_name, "--target-cpp" });
        const cpp = run.addOutputFileArg(b.fmt("{s}.cpp", .{src}));
        // Shaders #include the .glsl files next to them.
        for (vulkan_shader_includes) |inc| run.addFileInput(shaders_dir.path(b, inc));
        m.addCSourceFile(.{ .file = cpp, .flags = flags });
    }
    return lib.getEmittedBin();
}

const cuda_sources = [_][]const u8{
    "acc.cu",
    "add-id.cu",
    "allreduce.cu",
    "arange.cu",
    "argmax.cu",
    "argsort.cu",
    "binbcast.cu",
    "clamp.cu",
    "col2im-1d.cu",
    "concat.cu",
    "conv2d.cu",
    "conv2d-dw.cu",
    "conv2d-transpose.cu",
    "convert.cu",
    "conv-transpose-1d.cu",
    "count-equal.cu",
    "cpy.cu",
    "cross-entropy-loss.cu",
    "cumsum.cu",
    "diag.cu",
    "diagmask.cu",
    "dsv4-hc.cu",
    "fattn.cu",
    "fattn-tile.cu",
    "fill.cu",
    "fwht.cu",
    "gated_delta_net.cu",
    "getrows.cu",
    "ggml-cuda.cu",
    "gla.cu",
    "im2col.cu",
    "lightning-indexer.cu",
    "mean.cu",
    "mmf.cu",
    "mmid.cu",
    "mmq.cu",
    "mmvf.cu",
    "mmvq.cu",
    "moe-weighted-reduction.cu",
    "norm.cu",
    "opt-step-adamw.cu",
    "opt-step-sgd.cu",
    "out-prod.cu",
    "pad.cu",
    "pad_reflect_1d.cu",
    "pool1d.cu",
    "pool2d.cu",
    "quantize.cu",
    "roll.cu",
    "rope.cu",
    "scale.cu",
    "set.cu",
    "set-rows.cu",
    "snake.cu",
    "softcap.cu",
    "softmax.cu",
    "solve_tri.cu",
    "ssm-conv.cu",
    "ssm-scan.cu",
    "sum.cu",
    "sumrows.cu",
    "top-k.cu",
    "topk-moe.cu",
    "tri.cu",
    "tsembd.cu",
    "unary.cu",
    "upscale.cu",
    "wkv.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_32.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_32.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_32-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_32-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_64-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_8.cu",
    "template-instances/fattn-tile-instance-dkq112-dv112.cu",
    "template-instances/fattn-tile-instance-dkq128-dv128.cu",
    "template-instances/fattn-tile-instance-dkq192-dv128.cu",
    "template-instances/fattn-tile-instance-dkq256-dv256.cu",
    "template-instances/fattn-tile-instance-dkq320-dv256.cu",
    "template-instances/fattn-tile-instance-dkq40-dv40.cu",
    "template-instances/fattn-tile-instance-dkq512-dv512.cu",
    "template-instances/fattn-tile-instance-dkq576-dv512.cu",
    "template-instances/fattn-tile-instance-dkq64-dv64.cu",
    "template-instances/fattn-tile-instance-dkq72-dv72.cu",
    "template-instances/fattn-tile-instance-dkq80-dv80.cu",
    "template-instances/fattn-tile-instance-dkq96-dv96.cu",
    "template-instances/mmf-instance-ncols_10.cu",
    "template-instances/mmf-instance-ncols_11.cu",
    "template-instances/mmf-instance-ncols_12.cu",
    "template-instances/mmf-instance-ncols_13.cu",
    "template-instances/mmf-instance-ncols_14.cu",
    "template-instances/mmf-instance-ncols_15.cu",
    "template-instances/mmf-instance-ncols_16.cu",
    "template-instances/mmf-instance-ncols_1.cu",
    "template-instances/mmf-instance-ncols_2.cu",
    "template-instances/mmf-instance-ncols_3.cu",
    "template-instances/mmf-instance-ncols_4.cu",
    "template-instances/mmf-instance-ncols_5.cu",
    "template-instances/mmf-instance-ncols_6.cu",
    "template-instances/mmf-instance-ncols_7.cu",
    "template-instances/mmf-instance-ncols_8.cu",
    "template-instances/mmf-instance-ncols_9.cu",
    "template-instances/mmq-instance-iq1_s.cu",
    "template-instances/mmq-instance-iq2_s.cu",
    "template-instances/mmq-instance-iq2_xs.cu",
    "template-instances/mmq-instance-iq2_xxs.cu",
    "template-instances/mmq-instance-iq3_s.cu",
    "template-instances/mmq-instance-iq3_xxs.cu",
    "template-instances/mmq-instance-iq4_nl.cu",
    "template-instances/mmq-instance-iq4_xs.cu",
    "template-instances/mmq-instance-mxfp4.cu",
    "template-instances/mmq-instance-nvfp4.cu",
    "template-instances/mmq-instance-q1_0.cu",
    "template-instances/mmq-instance-q2_0.cu",
    "template-instances/mmq-instance-q2_k.cu",
    "template-instances/mmq-instance-q3_k.cu",
    "template-instances/mmq-instance-q4_0.cu",
    "template-instances/mmq-instance-q4_1.cu",
    "template-instances/mmq-instance-q4_k.cu",
    "template-instances/mmq-instance-q5_0.cu",
    "template-instances/mmq-instance-q5_1.cu",
    "template-instances/mmq-instance-q5_k.cu",
    "template-instances/mmq-instance-q6_k.cu",
    "template-instances/mmq-instance-q8_0.cu",
    "template-instances/fattn-vec-instance-f16-f16.cu",
    "template-instances/fattn-vec-instance-q4_0-q4_0.cu",
    "template-instances/fattn-vec-instance-q8_0-q8_0.cu",
    "template-instances/fattn-vec-instance-bf16-bf16.cu",
};

const llama_core_sources = [_][]const u8{
    "llama.cpp",
    "llama-adapter.cpp",
    "llama-arch.cpp",
    "llama-batch.cpp",
    "llama-chat.cpp",
    "llama-context.cpp",
    "llama-cparams.cpp",
    "llama-grammar.cpp",
    "llama-graph.cpp",
    "llama-hparams.cpp",
    "llama-impl.cpp",
    "llama-io.cpp",
    "llama-kv-cache.cpp",
    "llama-kv-cache-dsa.cpp",
    "llama-kv-cache-dsa-iswa.cpp",
    "llama-kv-cache-dsv4.cpp",
    "llama-kv-cache-iswa.cpp",
    "llama-kv-cache-msa.cpp",
    "llama-memory.cpp",
    "llama-memory-hybrid.cpp",
    "llama-memory-hybrid-idx.cpp",
    "llama-memory-hybrid-iswa.cpp",
    "llama-memory-recurrent.cpp",
    "llama-mmap.cpp",
    "llama-model-loader.cpp",
    "llama-model-saver.cpp",
    "llama-model.cpp",
    "llama-quant.cpp",
    "llama-sampler.cpp",
    "llama-vocab.cpp",
    "unicode.cpp",
    "unicode-data.cpp",
};

const llama_model_sources = [_][]const u8{
    "models/afmoe.cpp",
    "models/apertus.cpp",
    "models/arcee.cpp",
    "models/arctic.cpp",
    "models/arwkv7.cpp",
    "models/baichuan.cpp",
    "models/bailingmoe.cpp",
    "models/bailingmoe2.cpp",
    "models/bailingmoe3.cpp",
    "models/bert.cpp",
    "models/bitnet.cpp",
    "models/bloom.cpp",
    "models/chameleon.cpp",
    "models/chatglm.cpp",
    "models/clip.cpp",
    "models/codeshell.cpp",
    "models/cogvlm.cpp",
    "models/cohere2.cpp",
    "models/cohere2moe.cpp",
    "models/command-r.cpp",
    "models/dbrx.cpp",
    "models/deci.cpp",
    "models/deepseek.cpp",
    "models/deepseek2.cpp",
    "models/deepseek2ocr.cpp",
    "models/deepseek32.cpp",
    "models/deepseek4.cpp",
    "models/delta-net-base.cpp",
    "models/dflash.cpp",
    "models/dots1.cpp",
    "models/dots3note.cpp",
    "models/dream.cpp",
    "models/eagle3.cpp",
    "models/ernie4-5.cpp",
    "models/ernie4-5-moe.cpp",
    "models/eurobert.cpp",
    "models/exaone.cpp",
    "models/exaone-moe.cpp",
    "models/exaone4.cpp",
    "models/falcon.cpp",
    "models/falcon-h1.cpp",
    "models/gemma.cpp",
    "models/gemma-embedding.cpp",
    "models/gemma2.cpp",
    "models/gemma3.cpp",
    "models/gemma3n.cpp",
    "models/gemma4.cpp",
    "models/gemma4-assistant.cpp",
    "models/glm-dsa.cpp",
    "models/glm4.cpp",
    "models/glm4-moe.cpp",
    "models/gpt2.cpp",
    "models/gptneox.cpp",
    "models/granite.cpp",
    "models/granite-hybrid.cpp",
    "models/granite-moe.cpp",
    "models/granite-swa.cpp",
    "models/granite-switch.cpp",
    "models/grok.cpp",
    "models/grovemoe.cpp",
    "models/hunyuan-dense.cpp",
    "models/hunyuan-moe.cpp",
    "models/hunyuan-vl.cpp",
    "models/hy-v3.cpp",
    "models/internlm2.cpp",
    "models/jais.cpp",
    "models/jais2.cpp",
    "models/jamba.cpp",
    "models/jina-bert-v2.cpp",
    "models/jina-bert-v3.cpp",
    "models/kimi-k3.cpp",
    "models/kimi-linear.cpp",
    "models/laguna.cpp",
    "models/lfm2.cpp",
    "models/lfm2moe.cpp",
    "models/llada.cpp",
    "models/llada-moe.cpp",
    "models/llama.cpp",
    "models/llama-embed.cpp",
    "models/llama4.cpp",
    "models/maincoder.cpp",
    "models/mamba.cpp",
    "models/mamba-base.cpp",
    "models/mamba2.cpp",
    "models/mellum.cpp",
    "models/mimo2.cpp",
    "models/minicpm.cpp",
    "models/minicpm3.cpp",
    "models/minimax-01.cpp",
    "models/minimax-m2.cpp",
    "models/minimax-m3.cpp",
    "models/mistral3.cpp",
    "models/mistral4.cpp",
    "models/modern-bert.cpp",
    "models/mpt.cpp",
    "models/muse-glimmer.cpp",
    "models/nanbeige.cpp",
    "models/nemotron.cpp",
    "models/nemotron-h.cpp",
    "models/nemotron-h-moe.cpp",
    "models/neo-bert.cpp",
    "models/nomic-bert.cpp",
    "models/nomic-bert-moe.cpp",
    "models/olmo.cpp",
    "models/olmo2.cpp",
    "models/olmoe.cpp",
    "models/openai-moe.cpp",
    "models/openelm.cpp",
    "models/orion.cpp",
    "models/paddleocr.cpp",
    "models/pangu-embed.cpp",
    "models/phi2.cpp",
    "models/phi3.cpp",
    "models/phimoe.cpp",
    "models/plamo.cpp",
    "models/plamo2.cpp",
    "models/plamo3.cpp",
    "models/plm.cpp",
    "models/pockettts.cpp",
    "models/qwen.cpp",
    "models/qwen2.cpp",
    "models/qwen2moe.cpp",
    "models/qwen2vl.cpp",
    "models/qwen3.cpp",
    "models/qwen35.cpp",
    "models/qwen35moe.cpp",
    "models/qwen3moe.cpp",
    "models/qwen3next.cpp",
    "models/qwen3tts.cpp",
    "models/qwen3vl.cpp",
    "models/qwen3vlmoe.cpp",
    "models/qwen4exp.cpp",
    "models/refact.cpp",
    "models/rnd1.cpp",
    "models/rwkv6.cpp",
    "models/rwkv6-base.cpp",
    "models/rwkv6qwen2.cpp",
    "models/rwkv7.cpp",
    "models/rwkv7-base.cpp",
    "models/seed-oss.cpp",
    "models/smallthinker.cpp",
    "models/smollm3.cpp",
    "models/stablelm.cpp",
    "models/starcoder.cpp",
    "models/starcoder2.cpp",
    "models/step35.cpp",
    "models/t5.cpp",
    "models/t5encoder.cpp",
    "models/talkie.cpp",
    "models/wavtokenizer-dec.cpp",
    "models/xverse.cpp",
};

/// The .comp sources vulkan-shaders-gen compiles (ggml's CMake globs them).
const vulkan_shader_sources = [_][]const u8{
    "acc.comp",
    "add1.comp",
    "add.comp",
    "add_id.comp",
    "arange.comp",
    "argmax.comp",
    "argsort.comp",
    "argsort_large.comp",
    "col2im_1d.comp",
    "concat.comp",
    "contig_copy.comp",
    "conv2d_dw.comp",
    "conv2d_mm.comp",
    "conv3d_mm.comp",
    "conv_transpose_1d.comp",
    "copy.comp",
    "copy_from_quant.comp",
    "copy_to_quant.comp",
    "copy_transpose_02.comp",
    "copy_transpose.comp",
    "count_equal.comp",
    "count_experts.comp",
    "cross_entropy_loss_back.comp",
    "cross_entropy_loss.comp",
    "cumsum.comp",
    "cumsum_multipass1.comp",
    "cumsum_multipass2.comp",
    "dequant_f32.comp",
    "dequant_iq1_m.comp",
    "dequant_iq1_s.comp",
    "dequant_iq2_s.comp",
    "dequant_iq2_xs.comp",
    "dequant_iq2_xxs.comp",
    "dequant_iq3_s.comp",
    "dequant_iq3_xxs.comp",
    "dequant_iq4_nl.comp",
    "dequant_iq4_xs.comp",
    "dequant_mxfp4.comp",
    "dequant_nvfp4.comp",
    "dequant_q1_0.comp",
    "dequant_q2_0.comp",
    "dequant_q2_k.comp",
    "dequant_q3_k.comp",
    "dequant_q4_0.comp",
    "dequant_q4_1.comp",
    "dequant_q4_k.comp",
    "dequant_q5_0.comp",
    "dequant_q5_1.comp",
    "dequant_q5_k.comp",
    "dequant_q6_k.comp",
    "dequant_q8_0.comp",
    "dequant_tq2_0.comp",
    "diag.comp",
    "diag_mask_inf.comp",
    "div.comp",
    "fill.comp",
    "flash_attn_cm1.comp",
    "flash_attn_cm2.comp",
    "flash_attn.comp",
    "flash_attn_mask_opt.comp",
    "flash_attn_split_k_reduce.comp",
    "fwht.comp",
    "gated_delta_net.comp",
    "geglu.comp",
    "geglu_erf.comp",
    "geglu_quick.comp",
    "get_rows_back.comp",
    "get_rows.comp",
    "get_rows_quant.comp",
    "gla.comp",
    "group_norm.comp",
    "im2col_3d.comp",
    "im2col.comp",
    "l2_norm.comp",
    "lightning_indexer.comp",
    "log.comp",
    "mul.comp",
    "mul_mat_split_k_reduce.comp",
    "mul_mat_vec.comp",
    "mul_mat_vec_iq1_m.comp",
    "mul_mat_vec_iq1_s.comp",
    "mul_mat_vec_iq2_s.comp",
    "mul_mat_vec_iq2_xs.comp",
    "mul_mat_vec_iq2_xxs.comp",
    "mul_mat_vec_iq3_s.comp",
    "mul_mat_vec_iq3_xxs.comp",
    "mul_mat_vec_nc.comp",
    "mul_mat_vec_p021.comp",
    "mul_mat_vec_q2_k.comp",
    "mul_mat_vec_q3_k.comp",
    "mul_mat_vec_q4_k.comp",
    "mul_mat_vec_q5_k.comp",
    "mul_mat_vec_q6_k.comp",
    "mul_mat_vecq.comp",
    "mul_mat_vec_tq2_0.comp",
    "mul_mm_cm2.comp",
    "mul_mm.comp",
    "mul_mmq.comp",
    "multi_add.comp",
    "norm.comp",
    "opt_step_adamw.comp",
    "opt_step_sgd.comp",
    "out_prod.comp",
    "pad.comp",
    "pad_reflect_1d.comp",
    "pool1d.comp",
    "pool2d.comp",
    "quantize_q8_1.comp",
    "reglu.comp",
    "repeat_back.comp",
    "repeat.comp",
    "rms_norm_back.comp",
    "rms_norm.comp",
    "rms_norm_partials.comp",
    "roll.comp",
    "rope_multi.comp",
    "rope_neox.comp",
    "rope_norm.comp",
    "rope_vision.comp",
    "scale.comp",
    "silu_back.comp",
    "snake.comp",
    "soft_max_back.comp",
    "soft_max.comp",
    "soft_max_large1.comp",
    "soft_max_large2.comp",
    "soft_max_large3.comp",
    "solve_tri.comp",
    "ssm_conv.comp",
    "ssm_scan.comp",
    "sub.comp",
    "sum_rows.comp",
    "swiglu_clamp.comp",
    "swiglu.comp",
    "swiglu_oai.comp",
    "timestep_embedding.comp",
    "topk_argsort.comp",
    "topk_moe.comp",
    "topk_nary_search.comp",
    "topk_radix_select.comp",
    "tri.comp",
    "unary.comp",
    "upscale.comp",
    "wkv6.comp",
    "wkv7.comp",
};

/// Files the shaders #include.
const vulkan_shader_includes = [_][]const u8{
    "dequant_funcs_cm2.glsl",
    "dequant_funcs.glsl",
    "dequant_head.glsl",
    "dot_product_funcs.glsl",
    "fa_types.glsl",
    "flash_attn_base.glsl",
    "flash_attn_dequant.glsl",
    "flash_attn_mmq_funcs.glsl",
    "generic_binary_head.glsl",
    "generic_head.glsl",
    "generic_unary_head.glsl",
    "glu_head.glsl",
    "glu_main.glsl",
    "mul_mat_vec_base.glsl",
    "mul_mat_vec_iface.glsl",
    "mul_mat_vecq_funcs.glsl",
    "mul_mm_funcs.glsl",
    "mul_mm_id_funcs.glsl",
    "mul_mmq_funcs.glsl",
    "mul_mmq_shmem_types.glsl",
    "rope_funcs.glsl",
    "rope_head.glsl",
    "rope_params.glsl",
    "soft_max_large_common.glsl",
    "sum_rows.glsl",
    "types.glsl",
    "utils.glsl",
};
