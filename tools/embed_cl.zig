//! Build tool: embed ggml-opencl's kernels as C++ raw strings, like
//! ggml/src/ggml-opencl/kernels/embed_kernel.py (no Python needed).
//!
//!     embed_cl <kernels dir> <output dir>
//!
//! Writes `<name>.cl.h` for every `<name>.cl`: each line becomes `R"(line)"`,
//! which ggml-opencl.cpp `#include`s inside a string initializer.

const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: embed_cl <kernels dir> <output dir>\n", .{});
        return 2;
    }
    const cwd = std.Io.Dir.cwd();
    var in_dir = try cwd.openDir(io, args[1], .{ .iterate = true });
    defer in_dir.close(io);
    try cwd.createDirPath(io, args[2]);
    var out_dir = try cwd.openDir(io, args[2], .{});
    defer out_dir.close(io);

    var it = in_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".cl")) continue;
        const src = try in_dir.readFileAlloc(io, entry.name, gpa, .limited(8 << 20));
        defer gpa.free(src);
        const out = try embed(gpa, src);
        defer gpa.free(out);
        const name = try std.fmt.allocPrint(gpa, "{s}.h", .{entry.name});
        defer gpa.free(name);
        try out_dir.writeFile(io, .{ .sub_path = name, .data = out });
    }
    return 0;
}

/// Python's `for i in file: write('R"({})"\n'.format(i))`: every line keeps
/// its newline inside the raw string.
fn embed(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = src;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (nl) |i| rest[0 .. i + 1] else rest;
        if (std.mem.indexOf(u8, line, ")\"") != null) return error.RawStringDelimiterInKernel;
        try out.appendSlice(gpa, "R\"(");
        try out.appendSlice(gpa, line);
        try out.appendSlice(gpa, ")\"\n");
        rest = rest[line.len..];
    }
    return out.toOwnedSlice(gpa);
}

test embed {
    const gpa = std.testing.allocator;
    const out = try embed(gpa, "kernel void f() {\n}\n");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("R\"(kernel void f() {\n)\"\nR\"(}\n)\"\n", out);
}
