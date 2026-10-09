const std = @import("std");
const builtin = @import("builtin");

pub const CpuInfo = struct {
    percent: f32,
    cores: u32,
    model: []const u8,
};

pub const MemInfo = struct {
    total_bytes: u64,
    used_bytes: u64,
    available_bytes: u64,
    percent: f32,
};

pub const ProcessRow = struct {
    pid: u32,
    name: []const u8,
    state: []const u8,
    cpu_percent: f32,
    mem_rss_bytes: u64,
    mem_percent: f32,
};

pub const SystemSample = struct {
    cpu: CpuInfo,
    mem: MemInfo,
    uptime_seconds: u64,
    processes: []ProcessRow,
    total_processes: u32,
    sample_time_ms: f64,
    engine: []const u8,
};

pub const Sampler = struct {
    prev_cpu_total: u64 = 0,
    prev_cpu_idle: u64 = 0,
    prev_proc_ticks: std.AutoHashMap(u32, u64),
    curr_proc_ticks: std.AutoHashMap(u32, u64),
    cpu_cores: u32 = 1,
    cpu_model_buf: [128]u8 = undefined,
    cpu_model_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: ?std.Io) Sampler {
        var s = Sampler{
            .prev_proc_ticks = std.AutoHashMap(u32, u64).init(allocator),
            .curr_proc_ticks = std.AutoHashMap(u32, u64).init(allocator),
            .cpu_cores = @intCast(@max(1, std.Thread.getCpuCount() catch 1)),
        };
        if (io) |actual_io| {
            s.initCpuModel(actual_io);
            s.warmup(actual_io);
        }
        return s;
    }

    pub fn deinit(self: *Sampler) void {
        self.prev_proc_ticks.deinit();
        self.curr_proc_ticks.deinit();
    }

    fn initCpuModel(self: *Sampler, io: std.Io) void {
        if (builtin.os.tag == .linux) {
            var buf: [4096]u8 = undefined;
            const content = std.Io.Dir.cwd().readFile(io, "/proc/cpuinfo", &buf) catch return;
            var lines = std.mem.tokenizeScalar(u8, content, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "model name") or std.mem.startsWith(u8, line, "Hardware")) {
                    if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                        const model = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
                        const len = @min(model.len, self.cpu_model_buf.len);
                        @memcpy(self.cpu_model_buf[0..len], model[0..len]);
                        self.cpu_model_len = len;
                        return;
                    }
                }
            }
        }
    }

    fn warmup(self: *Sampler, io: std.Io) void {
        if (builtin.os.tag == .linux) {
            var stat_buf: [1024]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(io, "/proc/stat", &stat_buf)) |stat_content| {
                var lines = std.mem.tokenizeScalar(u8, stat_content, '\n');
                if (lines.next()) |cpu_line| {
                    var tokens = std.mem.tokenizeScalar(u8, cpu_line, ' ');
                    _ = tokens.next(); // "cpu"
                    var user: u64 = 0;
                    var nice: u64 = 0;
                    var system: u64 = 0;
                    var idle: u64 = 0;
                    var iowait: u64 = 0;
                    var irq: u64 = 0;
                    var softirq: u64 = 0;
                    var steal: u64 = 0;

                    if (tokens.next()) |t| user = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| nice = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| system = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| idle = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| iowait = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| irq = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| softirq = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| steal = std.fmt.parseInt(u64, t, 10) catch 0;

                    self.prev_cpu_total = user + nice + system + idle + iowait + irq + softirq + steal;
                    self.prev_cpu_idle = idle + iowait;
                }
            } else |_| {}

            if (std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true })) |dir_val| {
                var dir = dir_val;
                defer dir.close(io);
                var it = dir.iterate();
                var path_buf: [64]u8 = undefined;
                var proc_stat_buf: [1024]u8 = undefined;

                while (it.next(io) catch null) |entry| {
                    const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
                    const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
                    const stat_content = std.Io.Dir.cwd().readFile(io, stat_path, &proc_stat_buf) catch continue;

                    const close_paren = std.mem.lastIndexOfScalar(u8, stat_content, ')') orelse continue;
                    const rest = std.mem.trimStart(u8, stat_content[close_paren + 1 ..], " ");

                    var tok = std.mem.tokenizeScalar(u8, rest, ' ');
                    var idx: usize = 0;
                    while (idx < 11) : (idx += 1) _ = tok.next();
                    const utime_str = tok.next() orelse "0";
                    const stime_str = tok.next() orelse "0";
                    const utime = std.fmt.parseInt(u64, utime_str, 10) catch 0;
                    const stime = std.fmt.parseInt(u64, stime_str, 10) catch 0;

                    self.prev_proc_ticks.put(pid, utime + stime) catch {};
                }
            } else |_| {}
        }
    }

    fn parseKb(line: []const u8) u64 {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
        const rest = std.mem.trim(u8, line[colon + 1 ..], " \t");
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return std.fmt.parseInt(u64, rest[0..space], 10) catch 0;
    }

    pub fn sample(self: *Sampler, io: std.Io, arena: std.mem.Allocator) !SystemSample {
        const t0 = std.Io.Clock.Timestamp.now(io, .awake);

        var cpu_percent: f32 = 0.0;
        var cpu_total: u64 = 0;
        var cpu_idle: u64 = 0;
        var delta_total: u64 = 0;

        // 1. Read /proc/stat for aggregate CPU
        if (builtin.os.tag == .linux) {
            var stat_buf: [1024]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(io, "/proc/stat", &stat_buf)) |stat_content| {
                var lines = std.mem.tokenizeScalar(u8, stat_content, '\n');
                if (lines.next()) |cpu_line| {
                    var tokens = std.mem.tokenizeScalar(u8, cpu_line, ' ');
                    _ = tokens.next(); // "cpu"
                    var user: u64 = 0;
                    var nice: u64 = 0;
                    var system: u64 = 0;
                    var idle: u64 = 0;
                    var iowait: u64 = 0;
                    var irq: u64 = 0;
                    var softirq: u64 = 0;
                    var steal: u64 = 0;

                    if (tokens.next()) |t| user = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| nice = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| system = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| idle = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| iowait = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| irq = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| softirq = std.fmt.parseInt(u64, t, 10) catch 0;
                    if (tokens.next()) |t| steal = std.fmt.parseInt(u64, t, 10) catch 0;

                    cpu_total = user + nice + system + idle + iowait + irq + softirq + steal;
                    cpu_idle = idle + iowait;

                    if (self.prev_cpu_total > 0 and cpu_total > self.prev_cpu_total) {
                        delta_total = cpu_total - self.prev_cpu_total;
                        const delta_idle = if (cpu_idle >= self.prev_cpu_idle) cpu_idle - self.prev_cpu_idle else 0;
                        if (delta_total > delta_idle) {
                            const busy = delta_total - delta_idle;
                            cpu_percent = (@as(f32, @floatFromInt(busy)) / @as(f32, @floatFromInt(delta_total))) * 100.0;
                        }
                    }
                }
            } else |_| {}
        }
        self.prev_cpu_total = cpu_total;
        self.prev_cpu_idle = cpu_idle;

        // 2. Read /proc/meminfo for memory
        var mem_total_bytes: u64 = 0;
        var mem_available_bytes: u64 = 0;
        var mem_used_bytes: u64 = 0;
        var mem_percent: f32 = 0.0;

        if (builtin.os.tag == .linux) {
            var mem_buf: [2048]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(io, "/proc/meminfo", &mem_buf)) |mem_content| {
                var lines = std.mem.tokenizeScalar(u8, mem_content, '\n');
                var mem_free_kb: u64 = 0;
                var mem_total_kb: u64 = 0;
                var mem_avail_kb: u64 = 0;
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "MemTotal:")) {
                        mem_total_kb = parseKb(line);
                    } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                        mem_avail_kb = parseKb(line);
                    } else if (std.mem.startsWith(u8, line, "MemFree:")) {
                        mem_free_kb = parseKb(line);
                    }
                }
                mem_total_bytes = mem_total_kb * 1024;
                mem_available_bytes = if (mem_avail_kb > 0) mem_avail_kb * 1024 else mem_free_kb * 1024;
                mem_used_bytes = if (mem_total_bytes > mem_available_bytes) mem_total_bytes - mem_available_bytes else 0;
                if (mem_total_bytes > 0) {
                    mem_percent = (@as(f32, @floatFromInt(mem_used_bytes)) / @as(f32, @floatFromInt(mem_total_bytes))) * 100.0;
                }
            } else |_| {}
        }

        // 3. Read /proc/uptime
        var uptime_seconds: u64 = 0;
        if (builtin.os.tag == .linux) {
            var up_buf: [64]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(io, "/proc/uptime", &up_buf)) |up_content| {
                const space = std.mem.indexOfScalar(u8, up_content, ' ') orelse up_content.len;
                const up_float = std.fmt.parseFloat(f64, std.mem.trim(u8, up_content[0..space], " \n\r\t")) catch 0;
                uptime_seconds = @intFromFloat(up_float);
            } else |_| {}
        }

        // 4. Scan processes directly from /proc (zero subprocess overhead)
        var proc_list: std.ArrayList(ProcessRow) = .empty;
        proc_list.ensureTotalCapacity(arena, 512) catch {};
        self.curr_proc_ticks.clearRetainingCapacity();

        if (builtin.os.tag == .linux) {
            if (std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true })) |dir_val| {
                var dir = dir_val;
                defer dir.close(io);
                var it = dir.iterate();
                var path_buf: [64]u8 = undefined;
                var stat_buf: [1024]u8 = undefined;

                while (it.next(io) catch null) |entry| {
                    const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
                    const stat_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
                    const stat_content = std.Io.Dir.cwd().readFile(io, stat_path, &stat_buf) catch continue;

                    const open_paren = std.mem.indexOfScalar(u8, stat_content, '(') orelse continue;
                    const close_paren = std.mem.lastIndexOfScalar(u8, stat_content, ')') orelse continue;
                    if (close_paren <= open_paren) continue;

                    const comm_raw = stat_content[open_paren + 1 .. close_paren];
                    const rest = std.mem.trimStart(u8, stat_content[close_paren + 1 ..], " ");

                    var tok = std.mem.tokenizeScalar(u8, rest, ' ');
                    const state_tok = tok.next() orelse "?"; // 3: state
                    _ = tok.next(); // 4: ppid
                    _ = tok.next(); // 5: pgrp
                    _ = tok.next(); // 6: session
                    _ = tok.next(); // 7: tty
                    _ = tok.next(); // 8: tpgid
                    _ = tok.next(); // 9: flags
                    _ = tok.next(); // 10: minflt
                    _ = tok.next(); // 11: cminflt
                    _ = tok.next(); // 12: majflt
                    _ = tok.next(); // 13: cmajflt
                    const utime_str = tok.next() orelse "0"; // 14: utime
                    const stime_str = tok.next() orelse "0"; // 15: stime
                    _ = tok.next(); // 16: cutime
                    _ = tok.next(); // 17: cstime
                    _ = tok.next(); // 18: priority
                    _ = tok.next(); // 19: nice
                    _ = tok.next(); // 20: threads
                    _ = tok.next(); // 21: itrealvalue
                    _ = tok.next(); // 22: starttime
                    _ = tok.next(); // 23: vsize
                    const rss_str = tok.next() orelse "0"; // 24: rss in pages

                    const utime = std.fmt.parseInt(u64, utime_str, 10) catch 0;
                    const stime = std.fmt.parseInt(u64, stime_str, 10) catch 0;
                    const rss_pages = std.fmt.parseInt(u64, rss_str, 10) catch 0;
                    const rss_bytes = rss_pages * 4096;

                    const proc_ticks = utime + stime;
                    self.curr_proc_ticks.put(pid, proc_ticks) catch {};

                    var p_cpu: f32 = 0.0;
                    if (self.prev_proc_ticks.get(pid)) |prev_ticks| {
                        if (proc_ticks >= prev_ticks and delta_total > 0) {
                            const p_delta = proc_ticks - prev_ticks;
                            p_cpu = (@as(f32, @floatFromInt(p_delta)) / @as(f32, @floatFromInt(delta_total))) * 100.0 * @as(f32, @floatFromInt(self.cpu_cores));
                        }
                    }

                    var p_mem: f32 = 0.0;
                    if (mem_total_bytes > 0) {
                        p_mem = (@as(f32, @floatFromInt(rss_bytes)) / @as(f32, @floatFromInt(mem_total_bytes))) * 100.0;
                    }

                    const name_copy = arena.dupe(u8, comm_raw) catch comm_raw;
                    const state_copy = arena.dupe(u8, state_tok) catch state_tok;

                    proc_list.append(arena, .{
                        .pid = pid,
                        .name = name_copy,
                        .state = state_copy,
                        .cpu_percent = p_cpu,
                        .mem_rss_bytes = rss_bytes,
                        .mem_percent = p_mem,
                    }) catch {};
                }
            } else |_| {}
        }

        // Swap tick maps
        const tmp = self.prev_proc_ticks;
        self.prev_proc_ticks = self.curr_proc_ticks;
        self.curr_proc_ticks = tmp;

        const total_procs: u32 = @intCast(proc_list.items.len);

        // Sort processes by CPU descending, tie-breaking by Memory RSS descending
        std.mem.sort(ProcessRow, proc_list.items, {}, struct {
            fn lessThan(_: void, a: ProcessRow, b: ProcessRow) bool {
                if (a.cpu_percent != b.cpu_percent) {
                    return a.cpu_percent > b.cpu_percent;
                }
                return a.mem_rss_bytes > b.mem_rss_bytes;
            }
        }.lessThan);

        const keep_count = @min(proc_list.items.len, 256);
        const top_procs = proc_list.items[0..keep_count];

        // Resolve full unclipped process name from /proc/<pid>/cmdline (bypasses 15-char kernel comm truncation)
        if (builtin.os.tag == .linux) {
            var cmd_path_buf: [64]u8 = undefined;
            var cmd_buf: [512]u8 = undefined;
            for (top_procs) |*proc| {
                const cmd_path = std.fmt.bufPrint(&cmd_path_buf, "/proc/{d}/cmdline", .{proc.pid}) catch continue;
                if (std.Io.Dir.cwd().readFile(io, cmd_path, &cmd_buf)) |cmd_content| {
                    if (cmd_content.len > 0) {
                        const first_null = std.mem.indexOfScalar(u8, cmd_content, 0) orelse cmd_content.len;
                        const arg0 = cmd_content[0..first_null];
                        if (arg0.len > 0) {
                            const base = std.fs.path.basename(arg0);
                            const clean_base = if (std.mem.indexOfScalar(u8, base, ' ')) |sp| base[0..sp] else base;
                            if (clean_base.len > 0) {
                                if (clean_base.len > proc.name.len or std.mem.startsWith(u8, clean_base, proc.name)) {
                                    proc.name = arena.dupe(u8, clean_base) catch proc.name;
                                }
                            }
                        }
                    }
                } else |_| {}
            }
        }

        const t1 = std.Io.Clock.Timestamp.now(io, .awake);
        const sample_ns = t0.durationTo(t1).raw.toNanoseconds();
        const sample_ms = @as(f64, @floatFromInt(sample_ns)) / 1e6;

        const cpu_model_str = if (self.cpu_model_len > 0)
            arena.dupe(u8, self.cpu_model_buf[0..self.cpu_model_len]) catch "Host CPU"
        else
            "Host CPU";

        return .{
            .cpu = .{
                .percent = cpu_percent,
                .cores = self.cpu_cores,
                .model = cpu_model_str,
            },
            .mem = .{
                .total_bytes = mem_total_bytes,
                .used_bytes = mem_used_bytes,
                .available_bytes = mem_available_bytes,
                .percent = mem_percent,
            },
            .uptime_seconds = uptime_seconds,
            .processes = top_procs,
            .total_processes = total_procs,
            .sample_time_ms = sample_ms,
            .engine = "Zig direct /proc (kernel telemetry, 0 spawns)",
        };
    }
};

test "sampler benchmark 50 iterations" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = Sampler.init(gpa, io);
    defer s.deinit();

    var times: [50]f64 = undefined;
    for (0..50) |i| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const sample_res = try s.sample(io, arena.allocator());
        times[i] = sample_res.sample_time_ms;
    }

    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    var sum: f64 = 0.0;
    for (times) |t| sum += t;
    const avg = sum / 50.0;
    const p50 = times[25];
    const p90 = times[45];
    const min = times[0];
    const max = times[49];

    std.debug.print("\nOriel Sampler (/proc direct in Zig, 50 iterations):\n", .{});
    std.debug.print("  Avg: {d:.2} ms | Min: {d:.2} ms | p50: {d:.2} ms | p90: {d:.2} ms | Max: {d:.2} ms\n", .{
        avg, min, p50, p90, max,
    });

    // Take one more sample after sleeping 200ms to see top processes
    const ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 200 * 1000 * 1000 };
    _ = std.os.linux.nanosleep(&ts, null);
    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    const s2 = try s.sample(io, arena2.allocator());
    std.debug.print("Top 5 processes in s2:\n", .{});
    for (s2.processes[0..@min(5, s2.processes.len)]) |p| {
        std.debug.print("  PID {d:7} | {s:16} | CPU: {d:.1}%\n", .{ p.pid, p.name, p.cpu_percent });
    }
}
