//! Where there's no sampler yet (Android, iOS, the BSDs): empty samples,
//! and the page says so.

const std = @import("std");
const builtin = @import("builtin");
const tm = @import("telemetry.zig");

pub const Sampler = struct {
    pub fn init(_: std.mem.Allocator, _: ?std.Io) Sampler {
        return .{};
    }

    pub fn deinit(_: *Sampler, _: std.Io) void {}

    pub fn cpuModel(_: *const Sampler) []const u8 {
        return "Host CPU";
    }

    pub fn cpuCount(_: *const Sampler) u32 {
        return @intCast(@max(1, std.Thread.getCpuCount() catch 1));
    }

    pub fn commandLine(_: *Sampler, _: std.Io, _: std.mem.Allocator, _: u32) []const u8 {
        return "";
    }

    pub fn sample(s: *Sampler, _: std.Io, _: std.mem.Allocator) !tm.SystemSample {
        return .{
            .cpu = .{
                .percent = 0,
                .user_percent = 0,
                .system_percent = 0,
                .iowait_percent = null,
                .cores = s.cpuCount(),
                .model = "Host CPU",
                .freq_mhz = 0,
                .temp_c = null,
                .load_avg = null,
                .per_core = &.{},
            },
            .mem = std.mem.zeroes(tm.MemInfo),
            .uptime_seconds = 0,
            .processes = &.{},
            .total_processes = 0,
            .threads_total = 0,
            .running = 0,
            .disks = &.{},
            .net = &.{},
            .sensors = &.{},
            .sample_time_ms = 0,
            .engine = "no telemetry on " ++ @tagName(builtin.os.tag) ++ " yet",
        };
    }
};

pub fn terminate(_: u32) bool {
    return false;
}

pub fn systemInfo(_: std.Io, _: std.mem.Allocator, cpu_model: []const u8, threads: u32) tm.SystemInfo {
    return .{
        .hostname = "",
        .os = @tagName(builtin.os.tag),
        .kernel = "",
        .arch = @tagName(builtin.cpu.arch),
        .board = "",
        .bios = "",
        .cpu_model = cpu_model,
        .threads = threads,
    };
}
