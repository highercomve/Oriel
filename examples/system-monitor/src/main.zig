const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");
const sampler_mod = @import("sampler.zig");
const tm = @import("telemetry.zig");

pub const std_options: std.Options = .{
    .logFn = oriel.log.logFn,
    .log_level = .debug,
};

var io: std.Io = undefined;
var sampler: sampler_mod.Sampler = undefined;
var sampler_initialized: bool = false;
/// Samples run on the command pool: a manual refresh can overlap the timer's.
var sampler_lock: std.Io.Mutex = .init;

pub const Commands = struct {
    pub const async_commands = .{ "sample", "system_info", "command_line" };

    /// Samples live CPU (per core), memory, disks, network, sensors and the
    /// busiest processes; those matching the page's `filter` first, so an
    /// idle one it searches for is among the rows sent.
    pub fn sample(gpa: std.mem.Allocator, actual_io: std.Io, args: struct { filter: []const u8 = "", application_id: u64 = 0 }) !sampler_mod.SystemSample {
        sampler_lock.lockUncancelable(actual_io);
        defer sampler_lock.unlock(actual_io);
        if (!sampler_initialized) {
            sampler = sampler_mod.Sampler.init(std.heap.smp_allocator, actual_io);
            sampler_initialized = true;
        }
        sampler.filter = std.mem.trim(u8, args.filter[0..@min(args.filter.len, tm.max_filter)], " \t");
        defer sampler.filter = "";
        if (@hasField(sampler_mod.Sampler, "application_id")) sampler.application_id = args.application_id;
        defer if (@hasField(sampler_mod.Sampler, "application_id")) {
            sampler.application_id = 0;
        };
        return sampler.sample(actual_io, gpa);
    }

    /// A process's whole command line (samples send the first part).
    pub fn command_line(gpa: std.mem.Allocator, actual_io: std.Io, args: struct { pid: u32 }) []const u8 {
        sampler_lock.lockUncancelable(actual_io);
        defer sampler_lock.unlock(actual_io);
        if (!sampler_initialized) return "";
        return sampler.commandLine(actual_io, gpa, args.pid);
    }

    /// The machine: host, OS, kernel, board, BIOS, CPU (read once by the page).
    pub fn system_info(gpa: std.mem.Allocator, actual_io: std.Io) sampler_mod.SystemInfo {
        sampler_lock.lockUncancelable(actual_io);
        defer sampler_lock.unlock(actual_io);
        const model = if (sampler_initialized) sampler.cpuModel() else "Host CPU";
        return sampler_mod.systemInfo(actual_io, gpa, gpa.dupe(u8, model) catch "Host CPU", if (sampler_initialized) sampler.cpuCount() else 1);
    }

    /// Asks a process to end politely: SIGTERM on Linux and macOS, WM_CLOSE
    /// to its windows on Windows (never SIGKILL or TerminateProcess).
    pub fn terminate_process(_: std.mem.Allocator, args: struct { pid: i32 }) bool {
        if (args.pid <= 0) return false;
        const ok = sampler_mod.terminate(@intCast(args.pid));
        if (!ok) std.log.warn("Failed to ask pid {d} to end", .{args.pid});
        return ok;
    }

    /// Copies text to clipboard via Oriel clipboard plugin.
    pub fn copy_to_clipboard(_: std.mem.Allocator, args: struct { text: []const u8 }) !bool {
        if (oriel.clipboard.available) {
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

    if (oriel.options.zig_ui) @import("oriel_monitor.zig").configure(io);

    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .app = app.build,
        .window = .{ .title = "Oriel System Monitor", .width = 1280, .height = 900, .min_width = 860, .min_height = 540 },
    });
}
