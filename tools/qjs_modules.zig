//! Build tool: an app's JavaScript modules (its built frontend's .js files)
//! compiled to QuickJS bytecode for the native renderer, embedded beside
//! them (embed_assets' extra directory): the engine reads `<path>.qjsbc`
//! instead of parsing and compiling the module, when its source is the
//! same (qjs_shim.c checks the header).
//!
//! Usage: qjs_modules <src_dir> <out_dir>
//!
//! Each output: "OQJSMOD1", the source's FNV-1a 64 hash and length (u64,
//! little-endian), then the bytecode. A file that doesn't compile as a
//! module is skipped.
//!
//! Its style sheets (.css) too, parsed as the runtime's addSheet keeps them
//! (sheet-compiler.js, from the runtime's css.js): `<path>.sheet`,
//! "OQJSSHT1", the sheet's hash and length, then the rules as JSON; the
//! first window reads them instead of parsing (host.sheetCache).

const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;

extern fn oriel_qjs_compile_module(code: [*]const u8, len: usize, name: [*:0]const u8, out: *?[*]u8, out_len: *usize) c_int;
extern fn oriel_qjs_compile_sheet(compiler: [*]const u8, compiler_len: usize, css: [*]const u8, len: usize, out: *?[*]u8, out_len: *usize) c_int;
extern fn free(p: ?*anyopaque) void;

pub const magic = "OQJSMOD1";
pub const sheet_magic = "OQJSSHT1";
const sheet_compiler = @import("sheet_compiler").source;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3) {
        std.debug.print("usage: qjs_modules <src_dir> <out_dir>\n", .{});
        std.process.exit(2);
    }
    var src = Dir.cwd().openDir(io, argv[1], .{ .iterate = true }) catch |err| {
        std.debug.print("qjs_modules: cannot open {s}: {s} (was the frontend built?)\n", .{ argv[1], @errorName(err) });
        std.process.exit(1);
    };
    defer src.close(io);
    try Dir.cwd().createDirPath(io, argv[2]);
    var out = try Dir.cwd().openDir(io, argv[2], .{});
    defer out.close(io);

    var walker = try src.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.path);
        if (std.ascii.eqlIgnoreCase(ext, ".css")) {
            try compileSheet(io, gpa, src, out, entry.path);
            continue;
        }
        if (!std.ascii.eqlIgnoreCase(ext, ".js") and !std.ascii.eqlIgnoreCase(ext, ".mjs")) continue;
        // The module's name as the engine gives it: its asset path, '/'.
        const name = try gpa.dupeZ(u8, entry.path);
        defer gpa.free(name);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, name, '\\', '/');
        const code = try src.readFileAlloc(io, entry.path, gpa, .limited(256 * 1024 * 1024));
        defer gpa.free(code);
        var bc: ?[*]u8 = null;
        var bc_len: usize = 0;
        if (oriel_qjs_compile_module(code.ptr, code.len, name.ptr, &bc, &bc_len) != 0) continue;
        defer free(bc);
        var header: [24]u8 = undefined;
        @memcpy(header[0..8], magic);
        std.mem.writeInt(u64, header[8..16], fnv1a(code), .little);
        std.mem.writeInt(u64, header[16..24], code.len, .little);
        const dest = try std.fmt.allocPrint(gpa, "{s}.qjsbc", .{name});
        defer gpa.free(dest);
        if (std.fs.path.dirname(dest)) |dir| try out.createDirPath(io, dir);
        const data = try gpa.alloc(u8, header.len + bc_len);
        defer gpa.free(data);
        @memcpy(data[0..header.len], &header);
        @memcpy(data[header.len..], bc.?[0..bc_len]);
        try out.writeFile(io, .{ .sub_path = dest, .data = data });
    }
}

/// `<path>.sheet` for one style sheet; skipped (the window parses it) if
/// it doesn't parse.
fn compileSheet(io: std.Io, gpa: std.mem.Allocator, src: Dir, out: Dir, path: []const u8) !void {
    const css = try src.readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(css);
    var json: ?[*]u8 = null;
    var json_len: usize = 0;
    if (oriel_qjs_compile_sheet(sheet_compiler.ptr, sheet_compiler.len, css.ptr, css.len, &json, &json_len) != 0) return;
    defer free(json);
    var header: [24]u8 = undefined;
    @memcpy(header[0..8], sheet_magic);
    std.mem.writeInt(u64, header[8..16], fnv1a(css), .little);
    std.mem.writeInt(u64, header[16..24], css.len, .little);
    const dest = try std.fmt.allocPrint(gpa, "{s}.sheet", .{path});
    defer gpa.free(dest);
    if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, dest, '\\', '/');
    if (std.fs.path.dirname(dest)) |dir| try out.createDirPath(io, dir);
    const data = try gpa.alloc(u8, header.len + json_len);
    defer gpa.free(data);
    @memcpy(data[0..header.len], &header);
    @memcpy(data[header.len..], json.?[0..json_len]);
    try out.writeFile(io, .{ .sub_path = dest, .data = data });
}

pub fn fnv1a(s: []const u8) u64 {
    var h: u64 = 1469598103934665603;
    for (s) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}
