//! Thin Zig wrapper for whisper.cpp.
//!
//! Provides system info reporting, default context parameters,
//! and model loading with error handling.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cInclude("whisper.h");
});

/// Return the backend system info string.
pub fn systemInfo() []const u8 {
    const ptr = c.whisper_print_system_info();
    return std.mem.span(ptr);
}

/// Return default context parameters.
pub fn contextDefaultParams() c.whisper_context_params {
    return c.whisper_context_default_params();
}

/// A loaded whisper context handle.
pub const Context = struct {
    handle: *c.whisper_context,

    pub fn deinit(self: Context) void {
        c.whisper_free(self.handle);
    }
};

/// Load a whisper model from the given filesystem path. Returns `error.ModelLoadFailed`
/// if the file does not exist or cannot be parsed.
pub fn loadModel(path: [:0]const u8, params: c.whisper_context_params) !Context {
    const handle = c.whisper_init_from_file_with_params(path.ptr, params) orelse return error.ModelLoadFailed;
    return .{ .handle = handle };
}

/// Suppress all ggml and whisper log output on stderr (process-wide, for good).
pub fn silenceLogs() void {
    const noop = struct {
        fn cb(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    c.whisper_log_set(noop, null);
    c.ggml_log_set(noop, null);
}

/// Smoke check for oriel checkAll: verifies whisper system info reporting.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const info = systemInfo();
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    return .{
        .module = "whisper",
        .ok = info.len > 0,
        .detail = try std.fmt.allocPrint(gpa, "whisper.cpp: {s}", .{trimmed}),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "whisper check" {
    silenceLogs();
    const res = try check(std.testing.allocator, undefined);
    defer std.testing.allocator.free(res.detail);
    try std.testing.expect(res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.detail, "whisper.cpp: ") != null);
}

test "whisper system info, default params, and missing file error" {
    silenceLogs();
    const info = systemInfo();
    try std.testing.expect(info.len > 0);

    const params = contextDefaultParams();

    const res = loadModel("nonexistent_whisper_model_file.bin", params);
    try std.testing.expectError(error.ModelLoadFailed, res);
}
