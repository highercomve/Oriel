//! Build tool: embed ggml's Metal kernel sources in the executable, as
//! ggml's CMake does with GGML_METAL_EMBED_LIBRARY (so no `metal` compiler
//! or .metallib file is needed; ggml compiles the sources at startup).
//!
//!     metal_embed <ggml/src dir> <out.s>
//!
//! For each `ggml-metal/kernels/<kind>.metal`: prepend kernels/common.h
//! (and dequantize.h / quantize.h when the kernel includes them), drop the
//! internal includes and `#pragma once`, inline ../ggml-common.h at its
//! `__embed_ggml-common.h__` sentinel and ggml-metal-impl.h at its include,
//! then emit `_ggml_metallib_<kind>_{start,end}` around the bytes.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: metal_embed <ggml/src dir> <out.s>\n", .{});
        return 2;
    }
    const src_dir = args[1];
    const cwd = std.Io.Dir.cwd();

    const read = struct {
        fn file(a: std.mem.Allocator, i: std.Io, parts: []const []const u8) ![]u8 {
            const path = try std.fs.path.join(a, parts);
            return std.Io.Dir.cwd().readFileAlloc(i, path, a, .limited(16 << 20));
        }
    }.file;
    const ggml_common = try read(arena, io, &.{ src_dir, "ggml-common.h" });
    const impl = try read(arena, io, &.{ src_dir, "ggml-metal", "ggml-metal-impl.h" });
    const k_common = try read(arena, io, &.{ src_dir, "ggml-metal", "kernels", "common.h" });
    const k_dequant = try read(arena, io, &.{ src_dir, "ggml-metal", "kernels", "dequantize.h" });
    const k_quant = try read(arena, io, &.{ src_dir, "ggml-metal", "kernels", "quantize.h" });

    const kernels_path = try std.fs.path.join(arena, &.{ src_dir, "ggml-metal", "kernels" });
    var kernels = try cwd.openDir(io, kernels_path, .{ .iterate = true });
    defer kernels.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = kernels.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".metal")) try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(".section __DATA,__ggml_metallib\n");
    for (names.items) |name| {
        const kind = name[0 .. name.len - ".metal".len];
        const src = try read(arena, io, &.{ kernels_path, name });
        const text = try embedText(arena, src, k_common, k_dequant, k_quant, ggml_common, impl);
        // Symbols must be C identifiers ('-' is not allowed).
        const sym = try arena.dupe(u8, kind);
        for (sym) |*ch| if (ch.* == '-') {
            ch.* = '_';
        };
        try w.print(".globl _ggml_metallib_{s}_start\n_ggml_metallib_{s}_start:\n", .{ sym, sym });
        var i: usize = 0;
        while (i < text.len) : (i += 32) {
            try w.writeAll(".byte ");
            for (text[i..@min(i + 32, text.len)], 0..) |byte, j| {
                if (j > 0) try w.writeByte(',');
                try w.print("{d}", .{byte});
            }
            try w.writeByte('\n');
        }
        try w.print(".globl _ggml_metallib_{s}_end\n_ggml_metallib_{s}_end:\n", .{ sym, sym });
    }
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.written() });
    return 0;
}

/// The self-contained source of one kernel (see the file comment).
fn embedText(a: std.mem.Allocator, src: []const u8, k_common: []const u8, k_dequant: []const u8, k_quant: []const u8, ggml_common: []const u8, impl: []const u8) ![]u8 {
    var joined: std.Io.Writer.Allocating = .init(a);
    try joined.writer.writeAll(k_common);
    if (std.mem.indexOf(u8, src, "#include \"dequantize.h\"") != null) try joined.writer.writeAll(k_dequant);
    if (std.mem.indexOf(u8, src, "#include \"quantize.h\"") != null) try joined.writer.writeAll(k_quant);
    try joined.writer.writeAll(src);

    var out: std.Io.Writer.Allocating = .init(a);
    var lines = std.mem.splitScalar(u8, joined.written(), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "#include \"common.h\"") != null or
            std.mem.indexOf(u8, line, "#include \"dequantize.h\"") != null or
            std.mem.indexOf(u8, line, "#include \"quantize.h\"") != null or
            std.mem.indexOf(u8, line, "#pragma once") != null) continue;
        if (!first) try out.writer.writeByte('\n');
        first = false;
        if (std.mem.indexOf(u8, line, "__embed_ggml-common.h__") != null) {
            try out.writer.writeAll(ggml_common);
        } else if (std.mem.indexOf(u8, line, "#include \"ggml-metal-impl.h\"") != null) {
            try out.writer.writeAll(impl);
        } else {
            try out.writer.writeAll(line);
        }
    }
    return out.written();
}

test embedText {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const got = try embedText(
        arena.allocator(),
        "#include \"common.h\"\n#include \"dequantize.h\"\nkernel void k();\n",
        "#pragma once\n#include \"ggml-metal-impl.h\"\ncommon;\n",
        "#pragma once\n__embed_ggml-common.h__\ndequant;\n",
        "quant;\n",
        "GGML_COMMON",
        "IMPL",
    );
    try std.testing.expectEqualStrings("IMPL\ncommon;\nGGML_COMMON\ndequant;\nkernel void k();\n", got);
}
