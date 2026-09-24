//! Thin Zig wrapper for llama.cpp.
//!
//! Provides backend initialization, system info reporting, default model parameters,
//! and model loading with error handling.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cInclude("llama.h");
});

/// Return a copy of the backend system info string (CPU features); the
/// caller frees it with `gpa`. The C function returns a pointer into a static
/// string it rebuilds on every call, so handing that out would dangle.
pub fn systemInfo(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, std.mem.span(c.llama_print_system_info()));
}

/// Initialize the llama backend.
pub fn initBackend() void {
    c.llama_backend_init();
}

/// Free the llama backend.
pub fn deinitBackend() void {
    c.llama_backend_free();
}

/// Return default model parameters.
pub fn modelDefaultParams() c.llama_model_params {
    return c.llama_model_default_params();
}

/// A loaded llama model handle.
pub const Model = struct {
    handle: *c.llama_model,

    pub fn deinit(self: Model) void {
        c.llama_model_free(self.handle);
    }
};

/// Load a model from the given filesystem path. Returns `error.ModelLoadFailed`
/// if the file does not exist or cannot be parsed.
pub fn loadModel(path: [:0]const u8, params: c.llama_model_params) !Model {
    const handle = c.llama_model_load_from_file(path.ptr, params) orelse return error.ModelLoadFailed;
    return .{ .handle = handle };
}

/// Suppress all ggml and llama log output on stderr (process-wide, for good).
pub fn silenceLogs() void {
    const noop = struct {
        fn cb(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    c.llama_log_set(noop, null);
    c.ggml_log_set(noop, null);
}

/// Smoke check for oriel checkAll: verifies backend init and CPU system info.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    initBackend();
    defer deinitBackend();

    const info = try systemInfo(gpa);
    defer gpa.free(info);
    const has_cpu = std.mem.indexOf(u8, info, "CPU") != null;
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    return .{
        .module = "llama",
        .ok = has_cpu,
        .detail = try std.fmt.allocPrint(gpa, "llama.cpp: {s}", .{trimmed}),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "llama check" {
    silenceLogs();
    const res = try check(std.testing.allocator, undefined);
    defer std.testing.allocator.free(res.detail);
    try std.testing.expect(res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.detail, "llama.cpp: ") != null);
}

test "llama backend init, system info, default params, and missing file error" {
    silenceLogs();
    initBackend();
    defer deinitBackend();

    const info = try systemInfo(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(info.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, info, "CPU") != null);

    const params = modelDefaultParams();

    const res = loadModel("nonexistent_model_file_that_does_not_exist.gguf", params);
    try std.testing.expectError(error.ModelLoadFailed, res);
}
