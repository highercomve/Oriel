//! The sampler for the OS the app is built for, behind one interface:
//! `Sampler.init(gpa, io)`, `sample(io, arena)`, `commandLine(io, arena,
//! pid)`, `cpuModel()`, `cpuCount()`, plus `systemInfo(io, arena, model,
//! threads)` and `terminate(pid)`. Each fills the same telemetry.zig shapes, with what its OS
//! can tell.

const std = @import("std");
const builtin = @import("builtin");
const tm = @import("telemetry.zig");

pub const SystemSample = tm.SystemSample;
pub const SystemInfo = tm.SystemInfo;

const backend = switch (builtin.os.tag) {
    .linux => @import("sampler_linux.zig"),
    .windows => @import("sampler_windows.zig"),
    .macos => @import("sampler_macos.zig"),
    else => @import("sampler_none.zig"),
};

pub const Sampler = backend.Sampler;
pub const systemInfo = backend.systemInfo;
/// Ask a process to end politely (SIGTERM; on Windows, WM_CLOSE to its windows).
pub const terminate = backend.terminate;

test {
    _ = backend;
}
