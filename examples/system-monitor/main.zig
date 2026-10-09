const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const sampler_mod = @import("sampler.zig");

pub const std_options: std.Options = .{
    .logFn = oriel.log.logFn,
    .log_level = .debug,
};

var io: std.Io = undefined;
var sampler: sampler_mod.Sampler = undefined;
var sampler_initialized: bool = false;

pub const Commands = struct {
    pub const async_commands = .{ "sample" };

    /// Samples live CPU, memory, uptime and top process telemetry.
    pub fn sample(gpa: std.mem.Allocator, actual_io: std.Io) !sampler_mod.SystemSample {
        if (!sampler_initialized) {
            sampler = sampler_mod.Sampler.init(std.heap.smp_allocator, actual_io);
            sampler_initialized = true;
        }
        return sampler.sample(actual_io, gpa);
    }

    /// Sends SIGTERM to polite process termination (no SIGKILL).
    pub fn terminate_process(_: std.mem.Allocator, args: struct { pid: i32 }) bool {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
            std.posix.kill(args.pid, std.posix.SIG.TERM) catch |err| {
                std.log.warn("Failed to send SIGTERM to pid {d}: {s}", .{ args.pid, @errorName(err) });
                return false;
            };
            return true;
        }
        return false;
    }

    /// Copies text to clipboard via Oriel clipboard plugin.
    pub fn copy_to_clipboard(_: std.mem.Allocator, args: struct { text: []const u8 }) !bool {
        if (oriel.options.clipboard) {
            try oriel.clipboard.writeText(args.text);
            return true;
        }
        return false;
    }

    /// Returns runtime metadata (whether running in native_ui, platform name, arch).
    pub fn get_meta(_: std.mem.Allocator) struct {
        native_ui: bool,
        os: []const u8,
        arch: []const u8,
        app_name: []const u8,
    } {
        return .{
            .native_ui = oriel.options.native_ui,
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .app_name = "Oriel System Monitor",
        };
    }
};

pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    sampler = sampler_mod.Sampler.init(std.heap.smp_allocator, io);
    sampler_initialized = true;

    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.SystemMonitor",
        .title = "Oriel System Monitor",
        .width = 1140,
        .height = 760,
        .min_width = 860,
        .min_height = 540,
        .assets = app.assets,
        .dev = app.dev,
    });
}
