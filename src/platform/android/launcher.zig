//! liboriel_exec.so: runs the app's `main` in a process of its own.
//!
//! Android starts apps from app_process64, so an app that runs itself as a
//! helper (GhostPen's `--llm-helper`, `--whisper-helper`) has no executable
//! of its own to start. This small program ships next to liboriel.so (named
//! like a library so the APK installs it, extracted and runnable), and io.zig
//! hands its path to the app as the executable path. It loads liboriel.so
//! from its own directory and calls `oriel_exec_main` (entry.zig) with its
//! arguments: one copy of the app's code, in the app process and here.

const std = @import("std");

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
extern "c" fn readlink(path: [*:0]const u8, buf: [*]u8, size: usize) isize;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const RTLD_NOW = 2;

fn fail(comptime fmt: []const u8, args: anytype) c_int {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "oriel launcher: " ++ fmt ++ "\n", args) catch "oriel launcher: failed\n";
    _ = write(2, msg.ptr, msg.len);
    return 127;
}

pub export fn main(argc: c_int, argv: [*:null]?[*:0]u8) callconv(.c) c_int {
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = readlink("/proc/self/exe", &self_buf, self_buf.len - 1);
    if (n <= 0) return fail("can't find myself", .{});
    self_buf[@intCast(n)] = 0;
    const self: [:0]const u8 = self_buf[0..@intCast(n) :0];
    const dir = std.fs.path.dirname(self) orelse return fail("no directory in {s}", .{self});

    // Libraries the app loads by name at runtime (GPU backends) are next to
    // liboriel.so: put the directory on the search path, once.
    const ld = if (getenv("LD_LIBRARY_PATH")) |p| std.mem.sliceTo(p, 0) else "";
    if (std.mem.indexOf(u8, ld, dir) == null) {
        var path_buf: [std.fs.max_path_bytes * 2]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}{s}{s}", .{ dir, if (ld.len > 0) ":" else "", ld }) catch return fail("path too long", .{});
        if (setenv("LD_LIBRARY_PATH", path.ptr, 1) == 0) {
            _ = execv(self.ptr, @ptrCast(argv));
            // execv failed: go on without it.
        }
    }

    var lib_buf: [std.fs.max_path_bytes]u8 = undefined;
    const lib = std.fmt.bufPrintZ(&lib_buf, "{s}/liboriel.so", .{dir}) catch return fail("path too long", .{});
    const handle = dlopen(lib.ptr, RTLD_NOW) orelse
        return fail("can't load {s}: {s}", .{ lib, if (dlerror()) |e| std.mem.sliceTo(e, 0) else "?" });
    const sym = dlsym(handle, "oriel_exec_main") orelse return fail("{s} has no oriel_exec_main", .{lib});
    const exec_main: *const fn (c_int, [*:null]?[*:0]u8) callconv(.c) c_int = @ptrCast(@alignCast(sym));
    return exec_main(argc, argv);
}
