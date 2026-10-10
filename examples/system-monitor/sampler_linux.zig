//! Linux telemetry read straight from the kernel: /proc and /sys, no
//! subprocesses. Built to cost as little as possible per sample:
//! one open /proc handle every per-process read is relative to, fixed
//! buffers, and what doesn't change between samples (a process's name,
//! command line and user, the mounts, the sensors) read once and kept.

const std = @import("std");
const builtin = @import("builtin");

const is_linux = builtin.os.tag == .linux;
const linux = std.os.linux;
const Io = std.Io;

const tm = @import("telemetry.zig");
const CoreSample = tm.CoreSample;
const CpuInfo = tm.CpuInfo;
const MemInfo = tm.MemInfo;
const ProcessRow = tm.ProcessRow;
const DiskSample = tm.DiskSample;
const NetSample = tm.NetSample;
const SensorSample = tm.SensorSample;
const SystemSample = tm.SystemSample;
const SystemInfo = tm.SystemInfo;
const max_rows = tm.max_rows;
const max_command = tm.max_command;
const pct = tm.pct;
const round1 = tm.round1;

const Ticks = struct {
    user: u64 = 0,
    system: u64 = 0,
    idle: u64 = 0,
    iowait: u64 = 0,
    total: u64 = 0,
};

/// A process's name, command line and user: read when it's first seen in
/// the top rows, kept while it lives (`start` tells a reused pid apart).
const ProcMeta = struct {
    start: u64,
    name: []u8,
    command: []u8,
    uid: u32,
    seen: u64,
};

const Mount = struct {
    name: []u8,
    mount: [:0]u8,
    device: []u8,
    fs: []u8,
    /// Its /proc/diskstats name (nvme0n1p2, dm-0).
    stat_name: []u8,
    read_sectors: u64 = 0,
    write_sectors: u64 = 0,
    has_prev: bool = false,
};

const NetPrev = struct {
    name: []u8,
    rx: u64,
    tx: u64,
};

const Sensor = struct {
    name: []u8,
    path: []u8,
    /// Read every this many samples: 1 for the cheap ones (the CPU's, the
    /// GPU's), `medium_every` for those that cost a firmware call (ACPI,
    /// WMI: ~0.2 ms each), `drive_every` for a drive's (a command to the
    /// drive, up to half a second, waking it from power saving).
    every: u8 = 1,
    last: ?f64 = null,
};

const medium_every = 5;
const drive_every = 15;

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    proc_dir: ?Io.Dir = null,
    prev: Ticks = .{},
    prev_cores: std.ArrayList(Ticks) = .empty,
    prev_proc_ticks: std.AutoHashMap(u32, u64),
    /// Each process's /proc/<pid>/stat, kept open and read again with
    /// pread: no path walk, open and close per process per sample.
    stat_fds: std.AutoHashMap(u32, i32),
    stat_fd_cap: usize = 0,
    curr_proc_ticks: std.AutoHashMap(u32, u64),
    meta: std.AutoHashMap(u32, ProcMeta),
    users: std.AutoHashMap(u32, []u8),
    mounts: std.ArrayList(Mount) = .empty,
    nets: std.ArrayList(NetPrev) = .empty,
    sensors: std.ArrayList(Sensor) = .empty,
    cpu_sensor: ?usize = null,
    prev_time: ?Io.Clock.Timestamp = null,
    samples: u64 = 0,
    cpu_cores: u32 = 1,
    cpu_model_buf: [128]u8 = undefined,
    cpu_model_len: usize = 0,
    /// The page buffers samples read files into (/proc/stat on a big
    /// machine, the mounts with containers running, are tens of KB).
    buf: []u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, io: ?Io) Sampler {
        var s = Sampler{
            .gpa = gpa,
            .prev_proc_ticks = std.AutoHashMap(u32, u64).init(gpa),
            .stat_fds = std.AutoHashMap(u32, i32).init(gpa),
            .curr_proc_ticks = std.AutoHashMap(u32, u64).init(gpa),
            .meta = std.AutoHashMap(u32, ProcMeta).init(gpa),
            .users = std.AutoHashMap(u32, []u8).init(gpa),
            .cpu_cores = @intCast(@max(1, std.Thread.getCpuCount() catch 1)),
        };
        s.buf = gpa.alloc(u8, 256 * 1024) catch &.{};
        if (io) |actual_io| if (is_linux) {
            s.proc_dir = Io.Dir.cwd().openDir(actual_io, "/proc", .{ .iterate = true }) catch null;
            s.stat_fd_cap = statFdCap();
            s.initCpuModel(actual_io);
            s.loadUsers(actual_io);
            s.findSensors(actual_io);
            s.loadMounts(actual_io);
            // A first sample: the next one has deltas to work from.
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            _ = s.sample(actual_io, arena.allocator()) catch {};
        };
        return s;
    }

    pub fn deinit(s: *Sampler, io: Io) void {
        if (s.proc_dir) |d| d.close(io);
        s.prev_cores.deinit(s.gpa);
        s.prev_proc_ticks.deinit();
        var fit = s.stat_fds.valueIterator();
        while (fit.next()) |fd| _ = linux.close(fd.*);
        s.stat_fds.deinit();
        s.curr_proc_ticks.deinit();
        var mit = s.meta.valueIterator();
        while (mit.next()) |m| freeMeta(s.gpa, m.*);
        s.meta.deinit();
        var uit = s.users.valueIterator();
        while (uit.next()) |u| s.gpa.free(u.*);
        s.users.deinit();
        for (s.mounts.items) |m| freeMount(s.gpa, m);
        s.mounts.deinit(s.gpa);
        for (s.nets.items) |n| s.gpa.free(n.name);
        s.nets.deinit(s.gpa);
        for (s.sensors.items) |x| {
            s.gpa.free(x.name);
            s.gpa.free(x.path);
        }
        s.sensors.deinit(s.gpa);
        s.gpa.free(s.buf);
    }

    pub fn cpuModel(s: *const Sampler) []const u8 {
        return if (s.cpu_model_len > 0) s.cpu_model_buf[0..s.cpu_model_len] else "Host CPU";
    }

    pub fn cpuCount(s: *const Sampler) u32 {
        return s.cpu_cores;
    }

    fn freeMeta(gpa: std.mem.Allocator, m: ProcMeta) void {
        gpa.free(m.name);
        gpa.free(m.command);
    }

    fn freeMount(gpa: std.mem.Allocator, m: Mount) void {
        gpa.free(m.name);
        gpa.free(m.mount);
        gpa.free(m.device);
        gpa.free(m.fs);
        gpa.free(m.stat_name);
    }

    /// A file's contents into `buf` (empty when it can't be read).
    fn read(io: Io, path: []const u8, buf: []u8) []const u8 {
        return Io.Dir.cwd().readFile(io, path, buf) catch "";
    }

    fn initCpuModel(s: *Sampler, io: Io) void {
        var lines = std.mem.tokenizeScalar(u8, read(io, "/proc/cpuinfo", s.buf[0..8192]), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "model name") and !std.mem.startsWith(u8, line, "Hardware")) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const model = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
            const len = @min(model.len, s.cpu_model_buf.len);
            @memcpy(s.cpu_model_buf[0..len], model[0..len]);
            s.cpu_model_len = len;
            return;
        }
    }

    /// uid → name, from /etc/passwd (once: processes are many, users few).
    fn loadUsers(s: *Sampler, io: Io) void {
        var lines = std.mem.tokenizeScalar(u8, read(io, "/etc/passwd", s.buf), '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next();
            const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            if (s.users.contains(uid)) continue;
            const owned = s.gpa.dupe(u8, name) catch continue;
            s.users.put(uid, owned) catch s.gpa.free(owned);
        }
    }

    /// Every hwmon temperature input, named "chip label"; the CPU's own
    /// (cpu_sensor) the first of k10temp/zenpower/coretemp/cpu_thermal.
    fn findSensors(s: *Sampler, io: Io) void {
        var path_buf: [96]u8 = undefined;
        var small: [64]u8 = undefined;
        var cpu_rank: usize = std.math.maxInt(usize);
        const cpu_chips = [_][]const u8{ "k10temp", "zenpower", "coretemp", "cpu_thermal", "soc_thermal" };
        const Chip = struct {
            buf: [32]u8 = undefined,
            len: usize = 0,
            fn set(c: *@This(), v: []const u8) void {
                c.len = @min(v.len, c.buf.len);
                @memcpy(c.buf[0..c.len], v[0..c.len]);
            }
            fn slice(c: *const @This()) []const u8 {
                return c.buf[0..c.len];
            }
        };
        var chips: [32]Chip = undefined;
        var chip_count: usize = 0;
        for (0..32) |h| {
            const name_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/name", .{h}) catch continue;
            const chip_raw = std.mem.trim(u8, read(io, name_path, &small), " \n");
            if (chip_raw.len == 0) continue;
            var chip_buf: [32]u8 = undefined;
            const chip = chip_buf[0..@min(chip_raw.len, chip_buf.len)];
            @memcpy(chip, chip_raw[0..chip.len]);
            // The same chip again (several NVMe drives): numbered from #2.
            var instance: usize = 1;
            for (chips[0..chip_count]) |c| if (std.mem.eql(u8, c.slice(), chip)) {
                instance += 1;
            };
            if (chip_count < chips.len) {
                chips[chip_count] = .{};
                chips[chip_count].set(chip);
                chip_count += 1;
            }
            for (1..17) |t| {
                const input = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/temp{d}_input", .{ h, t }) catch continue;
                // A drive's sensor isn't read here (startup would wait on
                // the drives): it exists when its input file does. The
                // others are timed: a slow one is read less often.
                const drive = std.mem.eql(u8, chip, "nvme") or std.mem.eql(u8, chip, "drivetemp");
                var milli: ?i64 = null;
                var every: u8 = 1;
                if (drive) {
                    Io.Dir.cwd().access(io, input, .{}) catch continue;
                    every = drive_every;
                } else {
                    const before = Io.Clock.Timestamp.now(io, .awake);
                    const first = read(io, input, &small);
                    if (first.len == 0) continue;
                    if (before.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds() > 50 * std.time.ns_per_us) every = medium_every;
                    milli = std.fmt.parseInt(i64, std.mem.trim(u8, first, " \n"), 10) catch null;
                }
                const path = s.gpa.dupe(u8, input) catch continue;
                const label_path = std.fmt.bufPrint(&path_buf, "/sys/class/hwmon/hwmon{d}/temp{d}_label", .{ h, t }) catch continue;
                var label_buf: [64]u8 = undefined;
                const label = std.mem.trim(u8, read(io, label_path, &label_buf), " \n");
                const name = (if (instance > 1)
                    std.fmt.allocPrint(s.gpa, "{s}#{d} {s}", .{ chip, instance, if (label.len > 0) label else "temp" })
                else
                    std.fmt.allocPrint(s.gpa, "{s} {s}", .{ chip, if (label.len > 0) label else "temp" })) catch {
                    s.gpa.free(path);
                    continue;
                };
                s.sensors.append(s.gpa, .{ .name = name, .path = path, .every = every, .last = if (milli) |m| @as(f64, @floatFromInt(m)) / 1000.0 else null }) catch {
                    s.gpa.free(path);
                    s.gpa.free(name);
                    continue;
                };
                for (cpu_chips, 0..) |c, rank| {
                    if (!std.mem.eql(u8, chip, c) or rank >= cpu_rank) continue;
                    // coretemp: its package, not a core.
                    if (std.mem.eql(u8, c, "coretemp") and !std.mem.startsWith(u8, label, "Package")) continue;
                    cpu_rank = rank;
                    s.cpu_sensor = s.sensors.items.len - 1;
                }
            }
        }
    }

    /// The mounted block devices (one entry per device), from /proc/self/mounts.
    fn loadMounts(s: *Sampler, io: Io) void {
        var fresh: std.ArrayList(Mount) = .empty;
        var lines = std.mem.tokenizeScalar(u8, read(io, "/proc/self/mounts", s.buf), '\n');
        while (lines.next()) |line| {
            if (fresh.items.len >= 16) break;
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const device = f.next() orelse continue;
            const mount_raw = f.next() orelse continue;
            const fs = f.next() orelse continue;
            if (!std.mem.startsWith(u8, device, "/dev/")) continue;
            if (std.mem.eql(u8, fs, "squashfs") or std.mem.eql(u8, fs, "iso9660")) continue;
            if (std.mem.startsWith(u8, mount_raw, "/snap") or std.mem.startsWith(u8, mount_raw, "/var/lib/docker")) continue;
            var dup = false;
            for (fresh.items) |m| if (std.mem.eql(u8, m.device, device)) {
                dup = true;
            };
            if (dup) continue;
            var mount_buf: [512]u8 = undefined;
            const mount = unescapeOctal(mount_raw, &mount_buf);
            const base = std.fs.path.basename(mount);
            // dm devices (LVM, LUKS) are counted under their dm-N name.
            var link_buf: [256]u8 = undefined;
            const stat_name = if (Io.Dir.cwd().readLink(io, device, &link_buf)) |n| std.fs.path.basename(link_buf[0..n]) else |_| std.fs.path.basename(device);
            const m: Mount = .{
                .name = s.gpa.dupe(u8, if (std.mem.eql(u8, mount, "/")) "root" else base) catch continue,
                .mount = s.gpa.dupeZ(u8, mount) catch continue,
                .device = s.gpa.dupe(u8, device) catch continue,
                .fs = s.gpa.dupe(u8, fs) catch continue,
                .stat_name = s.gpa.dupe(u8, stat_name) catch continue,
            };
            fresh.append(s.gpa, m) catch {
                freeMount(s.gpa, m);
                continue;
            };
        }
        // The I/O counters carry over to the same device.
        for (fresh.items) |*m| for (s.mounts.items) |old| if (std.mem.eql(u8, old.device, m.device)) {
            m.read_sectors = old.read_sectors;
            m.write_sectors = old.write_sectors;
            m.has_prev = old.has_prev;
        };
        for (s.mounts.items) |m| freeMount(s.gpa, m);
        s.mounts.deinit(s.gpa);
        s.mounts = fresh;
    }

    /// /proc/self/mounts escapes spaces and such as \040.
    fn unescapeOctal(in: []const u8, out: []u8) []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < in.len and n < out.len) : (n += 1) {
            if (in[i] == '\\' and i + 4 <= in.len) {
                if (std.fmt.parseInt(u8, in[i + 1 .. i + 4], 8)) |c| {
                    out[n] = c;
                    i += 4;
                    continue;
                } else |_| {}
            }
            out[n] = in[i];
            i += 1;
        }
        return out[0..n];
    }

    fn parseTicks(line: []const u8) Ticks {
        var t = std.mem.tokenizeScalar(u8, line, ' ');
        _ = t.next(); // "cpu" / "cpuN"
        var v: [8]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
        for (&v) |*x| x.* = std.fmt.parseInt(u64, t.next() orelse break, 10) catch 0;
        // user nice system idle iowait irq softirq steal
        return .{
            .user = v[0] + v[1],
            .system = v[2] + v[5] + v[6],
            .idle = v[3],
            .iowait = v[4],
            .total = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7],
        };
    }



    fn parseKb(line: []const u8) u64 {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
        var t = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        return (std.fmt.parseInt(u64, t.next() orelse return 0, 10) catch 0) * 1024;
    }

    pub fn sample(s: *Sampler, io: Io, arena: std.mem.Allocator) !SystemSample {
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        s.samples += 1;
        const dt_s: f64 = if (s.prev_time) |p| @as(f64, @floatFromInt(p.durationTo(t0).raw.toNanoseconds())) / 1e9 else 0;
        s.prev_time = t0;

        var cpu: CpuInfo = .{
            .percent = 0,
            .user_percent = 0,
            .system_percent = 0,
            .iowait_percent = 0,
            .cores = s.cpu_cores,
            .model = if (s.cpu_model_len > 0) try arena.dupe(u8, s.cpu_model_buf[0..s.cpu_model_len]) else "Host CPU",
            .freq_mhz = 0,
            .temp_c = null,
            .load_avg = null,
            .per_core = &.{},
        };
        var delta_total: u64 = 0;
        var mem: MemInfo = std.mem.zeroes(MemInfo);
        var uptime_seconds: u64 = 0;
        var threads_total: u32 = 0;
        var running: u32 = 0;

        if (!is_linux) return .{
            .cpu = cpu,
            .mem = mem,
            .uptime_seconds = 0,
            .processes = &.{},
            .total_processes = 0,
            .threads_total = 0,
            .running = 0,
            .disks = &.{},
            .net = &.{},
            .sensors = &.{},
            .sample_time_ms = 0,
            .engine = "telemetry is Linux-only for now",
        };

        // CPU: the aggregate line, then one per core.
        {
            var lines = std.mem.tokenizeScalar(u8, read(io, "/proc/stat", s.buf), '\n');
            var cores: std.ArrayList(CoreSample) = .empty;
            try cores.ensureTotalCapacity(arena, s.cpu_cores);
            var core: usize = 0;
            while (lines.next()) |line| {
                if (!std.mem.startsWith(u8, line, "cpu")) break;
                const t = parseTicks(line);
                if (line[3] == ' ') {
                    if (s.prev.total > 0 and t.total > s.prev.total) {
                        delta_total = t.total - s.prev.total;
                        const idle = (t.idle + t.iowait) -| (s.prev.idle + s.prev.iowait);
                        cpu.percent = pct(delta_total -| idle, delta_total);
                        cpu.user_percent = pct(t.user -| s.prev.user, delta_total);
                        cpu.system_percent = pct(t.system -| s.prev.system, delta_total);
                        cpu.iowait_percent = pct(t.iowait -| s.prev.iowait, delta_total);
                    }
                    s.prev = t;
                    continue;
                }
                if (core >= s.prev_cores.items.len) try s.prev_cores.append(s.gpa, .{});
                const p = &s.prev_cores.items[core];
                var percent: f64 = 0;
                if (p.total > 0 and t.total > p.total) {
                    const d = t.total - p.total;
                    percent = pct(d -| ((t.idle + t.iowait) -| (p.idle + p.iowait)), d);
                }
                p.* = t;
                try cores.append(arena, .{ .percent = percent, .freq_mhz = 0 });
                core += 1;
            }
            // Frequencies (kHz), and their average.
            var path_buf: [80]u8 = undefined;
            var small: [32]u8 = undefined;
            var freq_sum: f64 = 0;
            for (cores.items, 0..) |*c, i| {
                const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq", .{i}) catch continue;
                const khz = std.fmt.parseInt(u64, std.mem.trim(u8, read(io, path, &small), " \n"), 10) catch continue;
                c.freq_mhz = @round(@as(f64, @floatFromInt(khz)) / 1000.0);
                freq_sum += c.freq_mhz;
            }
            if (cores.items.len > 0) cpu.freq_mhz = @round(freq_sum / @as(f64, @floatFromInt(cores.items.len)));
            cpu.per_core = cores.items;
        }

        // Load average, and the threads running / all: "0.27 0.39 0.35 3/2014 72826".
        {
            var t = std.mem.tokenizeAny(u8, read(io, "/proc/loadavg", s.buf[0..128]), " /\n");
            var la: [3]f64 = .{ 0, 0, 0 };
            for (&la) |*l| l.* = std.fmt.parseFloat(f64, t.next() orelse break) catch 0;
            cpu.load_avg = la;
            running = std.fmt.parseInt(u32, t.next() orelse "0", 10) catch 0;
            threads_total = std.fmt.parseInt(u32, t.next() orelse "0", 10) catch 0;
        }

        // Memory.
        {
            var lines = std.mem.tokenizeScalar(u8, read(io, "/proc/meminfo", s.buf[0..8192]), '\n');
            var swap_free: u64 = 0;
            var reclaimable: u64 = 0;
            while (lines.next()) |line| {
                const v = parseKb(line);
                if (std.mem.startsWith(u8, line, "MemTotal:")) mem.total_bytes = v //
                else if (std.mem.startsWith(u8, line, "MemFree:")) mem.free_bytes = v //
                else if (std.mem.startsWith(u8, line, "MemAvailable:")) mem.available_bytes = v //
                else if (std.mem.startsWith(u8, line, "Buffers:")) mem.buffers_bytes = v //
                else if (std.mem.startsWith(u8, line, "Cached:")) mem.cached_bytes = v //
                else if (std.mem.startsWith(u8, line, "SReclaimable:")) reclaimable = v //
                else if (std.mem.startsWith(u8, line, "SwapTotal:")) mem.swap_total_bytes = v //
                else if (std.mem.startsWith(u8, line, "SwapFree:")) swap_free = v;
            }
            mem.cached_bytes += reclaimable;
            if (mem.available_bytes == 0) mem.available_bytes = mem.free_bytes;
            mem.used_bytes = mem.total_bytes -| mem.available_bytes;
            mem.swap_used_bytes = mem.swap_total_bytes -| swap_free;
            mem.percent = pct(mem.used_bytes, mem.total_bytes);
        }

        {
            const up = read(io, "/proc/uptime", s.buf[0..64]);
            const space = std.mem.indexOfScalar(u8, up, ' ') orelse up.len;
            uptime_seconds = @intFromFloat(@max(0, std.fmt.parseFloat(f64, up[0..space]) catch 0));
        }

        // Processes: one read of /proc/<pid>/stat each, relative to /proc.
        var procs: std.ArrayList(ProcessRow) = .empty;
        try procs.ensureTotalCapacity(arena, 1024);
        s.curr_proc_ticks.clearRetainingCapacity();
        const page = std.heap.pageSize();
        var starts: std.AutoHashMapUnmanaged(u32, u64) = .empty;
        if (s.proc_dir) |dir| {
            var it = dir.iterate();
            var path_buf: [32]u8 = undefined;
            var stat_buf: [1024]u8 = undefined;
            while (it.next(io) catch null) |entry| {
                const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;
                const stat = s.readStat(dir, pid, &path_buf, &stat_buf) orelse continue;
                const open = std.mem.indexOfScalar(u8, stat, '(') orelse continue;
                const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
                if (close <= open) continue;
                // Fields from 3 (state) on, 0-based here.
                var f: [22][]const u8 = undefined;
                var tok = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
                var n: usize = 0;
                while (n < f.len) : (n += 1) f[n] = tok.next() orelse break;
                if (n < f.len) continue;
                const ticks = (std.fmt.parseInt(u64, f[11], 10) catch 0) + (std.fmt.parseInt(u64, f[12], 10) catch 0);
                const rss = (std.fmt.parseInt(u64, f[21], 10) catch 0) * page;
                s.curr_proc_ticks.put(pid, ticks) catch {};
                var p_cpu: f64 = 0;
                if (s.prev_proc_ticks.get(pid)) |prev| if (ticks >= prev and delta_total > 0) {
                    p_cpu = round1(pct(ticks - prev, delta_total) * @as(f64, @floatFromInt(s.cpu_cores)));
                };
                starts.put(arena, pid, std.fmt.parseInt(u64, f[19], 10) catch 0) catch {};
                procs.append(arena, .{
                    .pid = pid,
                    .name = try arena.dupe(u8, stat[open + 1 .. close]),
                    .command = "",
                    .user = "",
                    .state = try arena.dupe(u8, f[0]),
                    .threads = std.fmt.parseInt(u32, f[17], 10) catch 1,
                    .cpu_percent = p_cpu,
                    .mem_rss_bytes = rss,
                }) catch {};
            }
        }
        // The stat files of processes gone: closed.
        {
            var gone: std.ArrayList(u32) = .empty;
            var fit = s.stat_fds.keyIterator();
            while (fit.next()) |pid| if (!s.curr_proc_ticks.contains(pid.*)) gone.append(arena, pid.*) catch {};
            for (gone.items) |pid| if (s.stat_fds.fetchRemove(pid)) |kv| {
                _ = linux.close(kv.value);
            };
        }
        std.mem.swap(std.AutoHashMap(u32, u64), &s.prev_proc_ticks, &s.curr_proc_ticks);
        const total_procs: u32 = @intCast(procs.items.len);

        tm.busiestFirst(procs.items);
        const top = procs.items[0..@min(procs.items.len, max_rows)];

        // The top rows' names, command lines and users: read once per process.
        for (top) |*p| {
            const start = starts.get(p.pid) orelse 0;
            const gop = s.meta.getOrPut(p.pid) catch continue;
            var have = gop.found_existing;
            if (have and gop.value_ptr.start != start) {
                freeMeta(s.gpa, gop.value_ptr.*);
                have = false;
            }
            if (!have) {
                gop.value_ptr.* = s.readMeta(io, p.pid, p.name, start) orelse {
                    s.meta.removeByPtr(gop.key_ptr);
                    continue;
                };
            }
            const m = gop.value_ptr;
            m.seen = s.samples;
            p.name = try arena.dupe(u8, m.name);
            // Long command lines (a browser's run to kilobytes) cut: the
            // table shows the start; copying asks for the whole (command_line).
            p.command = try arena.dupe(u8, m.command[0..@min(m.command.len, max_command)]);
            p.user = if (s.users.get(m.uid)) |u| try arena.dupe(u8, u) else try std.fmt.allocPrint(arena, "{d}", .{m.uid});
        }
        // Processes gone (or out of the top rows a while): forgotten.
        if (s.samples % 16 == 0) {
            var stale: std.ArrayList(u32) = .empty;
            var mit = s.meta.iterator();
            while (mit.next()) |e| if (e.value_ptr.seen + 16 < s.samples) stale.append(arena, e.key_ptr.*) catch {};
            for (stale.items) |pid| if (s.meta.fetchRemove(pid)) |kv| freeMeta(s.gpa, kv.value);
        }

        // Disks: the mounts list again now and then, then size and I/O rates.
        if (s.samples % 15 == 0) s.loadMounts(io);
        const disks = try arena.alloc(DiskSample, s.mounts.items.len);
        {
            const stats = read(io, "/proc/diskstats", s.buf);
            for (s.mounts.items, disks) |*m, *d| {
                d.* = .{
                    .name = try arena.dupe(u8, m.name),
                    .mount = try arena.dupe(u8, m.mount),
                    .device = try arena.dupe(u8, m.device),
                    .fs = try arena.dupe(u8, m.fs),
                    .total_bytes = 0,
                    .used_bytes = 0,
                    .read_bps = 0,
                    .write_bps = 0,
                };
                if (fsSize(m.mount)) |size| {
                    d.total_bytes = size[0];
                    d.used_bytes = size[1];
                }
                var lines = std.mem.tokenizeScalar(u8, stats, '\n');
                while (lines.next()) |line| {
                    var f = std.mem.tokenizeScalar(u8, line, ' ');
                    _ = f.next();
                    _ = f.next();
                    if (!std.mem.eql(u8, f.next() orelse continue, m.stat_name)) continue;
                    var v: [7]u64 = undefined;
                    for (&v) |*x| x.* = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
                    // reads merged sectors ms writes merged sectors
                    const rd = v[2];
                    const wr = v[6];
                    if (m.has_prev and dt_s > 0) {
                        d.read_bps = @as(f64, @floatFromInt(rd -| m.read_sectors)) * 512 / dt_s;
                        d.write_bps = @as(f64, @floatFromInt(wr -| m.write_sectors)) * 512 / dt_s;
                    }
                    m.read_sectors = rd;
                    m.write_sectors = wr;
                    m.has_prev = true;
                    break;
                }
            }
        }

        // Network: every interface but loopback and container plumbing.
        var nets: std.ArrayList(NetSample) = .empty;
        {
            var lines = std.mem.tokenizeScalar(u8, read(io, "/proc/net/dev", s.buf), '\n');
            _ = lines.next();
            _ = lines.next();
            var path_buf: [96]u8 = undefined;
            var small: [16]u8 = undefined;
            while (lines.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " ");
                if (std.mem.eql(u8, name, "lo") or std.mem.startsWith(u8, name, "veth") or std.mem.startsWith(u8, name, "br-") or
                    std.mem.startsWith(u8, name, "docker") or std.mem.startsWith(u8, name, "virbr")) continue;
                var f = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
                var v: [9]u64 = undefined;
                for (&v) |*x| x.* = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
                const rx = v[0];
                const tx = v[8];
                var rx_bps: f64 = 0;
                var tx_bps: f64 = 0;
                var found = false;
                for (s.nets.items) |*p| if (std.mem.eql(u8, p.name, name)) {
                    if (dt_s > 0) {
                        rx_bps = @as(f64, @floatFromInt(rx -| p.rx)) / dt_s;
                        tx_bps = @as(f64, @floatFromInt(tx -| p.tx)) / dt_s;
                    }
                    p.rx = rx;
                    p.tx = tx;
                    found = true;
                    break;
                };
                if (!found) if (s.gpa.dupe(u8, name)) |owned| {
                    s.nets.append(s.gpa, .{ .name = owned, .rx = rx, .tx = tx }) catch s.gpa.free(owned);
                } else |_| {};
                const state_path = std.fmt.bufPrint(&path_buf, "/sys/class/net/{s}/operstate", .{name}) catch continue;
                const state = std.mem.trim(u8, read(io, state_path, &small), " \n");
                try nets.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .up = std.mem.eql(u8, state, "up") or std.mem.eql(u8, state, "unknown"),
                    .rx_bps = rx_bps,
                    .tx_bps = tx_bps,
                    .rx_total = rx,
                    .tx_total = tx,
                });
            }
        }

        // Sensors.
        const sensors = try arena.alloc(SensorSample, s.sensors.items.len);
        var sensor_count: usize = 0;
        for (s.sensors.items, 0..) |*x, i| {
            // Init's sample is the first; the drives' first read is the
            // second's, on the command pool.
            if (x.every == 1 or s.samples % x.every == 2) {
                var small: [16]u8 = undefined;
                if (std.fmt.parseInt(i64, std.mem.trim(u8, read(io, x.path, &small), " \n"), 10)) |milli| {
                    x.last = round1(@as(f64, @floatFromInt(milli)) / 1000.0);
                } else |_| {}
            }
            const c = x.last orelse continue;
            if (s.cpu_sensor == i) cpu.temp_c = c;
            sensors[sensor_count] = .{ .name = try arena.dupe(u8, x.name), .temp_c = c };
            sensor_count += 1;
        }

        const t1 = Io.Clock.Timestamp.now(io, .awake);
        return .{
            .cpu = cpu,
            .mem = mem,
            .uptime_seconds = uptime_seconds,
            .processes = top,
            .total_processes = total_procs,
            .threads_total = threads_total,
            .running = running,
            .disks = disks,
            .net = nets.items,
            .sensors = sensors[0..sensor_count],
            .sample_time_ms = @as(f64, @floatFromInt(t0.durationTo(t1).raw.toNanoseconds())) / 1e6,
            .engine = "Zig direct /proc + /sys (kernel telemetry, 0 spawns)",
        };
    }

    fn failed(rc: usize) bool {
        return @as(isize, @bitCast(rc)) < 0;
    }

    /// How many stat files may stay open: the soft open-files limit raised
    /// to the hard one, half of it left for everything else.
    fn statFdCap() usize {
        if (!is_linux) return 0;
        var lim: linux.rlimit = undefined;
        if (failed(linux.getrlimit(.NOFILE, &lim))) return 0;
        if (lim.cur < lim.max) {
            var want = lim;
            want.cur = @min(lim.max, 65536);
            if (!failed(linux.setrlimit(.NOFILE, &want))) lim.cur = want.cur;
        }
        return @intCast(@min(lim.cur / 2, 16384));
    }

    /// /proc/<pid>/stat's contents: through its kept file when there is
    /// one (a pread from 0 makes the kernel write it afresh), else opened.
    fn readStat(s: *Sampler, dir: Io.Dir, pid: u32, path_buf: []u8, buf: []u8) ?[]const u8 {
        if (s.stat_fds.get(pid)) |fd| {
            const n = linux.pread(fd, buf.ptr, buf.len, 0);
            if (!failed(n) and n > 0) return buf[0..n];
            // The process ended (ESRCH), maybe its pid reused: opened again.
            _ = linux.close(fd);
            _ = s.stat_fds.remove(pid);
        }
        const path = std.fmt.bufPrintZ(path_buf, "{d}/stat", .{pid}) catch return null;
        const rc = linux.openat(dir.handle, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (failed(rc)) return null;
        const fd: i32 = @intCast(rc);
        const n = linux.pread(fd, buf.ptr, buf.len, 0);
        if (failed(n) or n == 0) {
            _ = linux.close(fd);
            return null;
        }
        if (s.stat_fds.count() < s.stat_fd_cap) {
            s.stat_fds.put(pid, fd) catch {
                _ = linux.close(fd);
            };
        } else {
            _ = linux.close(fd);
        }
        return buf[0..n];
    }

    /// A process's whole command line (empty when it's gone or has none).
    pub fn commandLine(s: *Sampler, io: Io, arena: std.mem.Allocator, pid: u32) []const u8 {
        const dir = s.proc_dir orelse return "";
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{d}/cmdline", .{pid}) catch return "";
        const raw = dir.readFile(io, path, s.buf) catch return "";
        const out = arena.dupe(u8, std.mem.trimEnd(u8, raw, "\x00 ")) catch return "";
        for (out) |*c| if (c.* == 0) {
            c.* = ' ';
        };
        return out;
    }

    /// A process's display name, command line and user, read from /proc.
    fn readMeta(s: *Sampler, io: Io, pid: u32, comm: []const u8, start: u64) ?ProcMeta {
        const dir = s.proc_dir orelse return null;
        var path_buf: [32]u8 = undefined;
        var cmd_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{d}/cmdline", .{pid}) catch return null;
        const raw = dir.readFile(io, path, &cmd_buf) catch "";
        // The kernel's comm is cut at 15 bytes: the command's own name when
        // it starts the same (or is longer).
        var name: []const u8 = comm;
        const arg0 = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
        if (arg0.len > 0) {
            const base = std.fs.path.basename(arg0);
            const clean = if (std.mem.indexOfScalar(u8, base, ' ')) |sp| base[0..sp] else base;
            if (clean.len > 0 and (std.mem.startsWith(u8, clean, comm) or (comm.len >= 15 and clean.len > comm.len))) name = clean;
        }
        const command = s.gpa.dupe(u8, std.mem.trimEnd(u8, raw, "\x00 ")) catch return null;
        for (command) |*c| if (c.* == 0) {
            c.* = ' ';
        };
        const owned_name = s.gpa.dupe(u8, name) catch {
            s.gpa.free(command);
            return null;
        };
        // The owner of /proc/<pid>: its real user, one statx, no file to parse.
        var uid: u32 = 0;
        if (is_linux) {
            const dir_path = std.fmt.bufPrintZ(&path_buf, "{d}", .{pid}) catch "";
            var stx: linux.Statx = undefined;
            if (dir_path.len > 0 and linux.statx(dir.handle, dir_path, 0, .{ .UID = true }, &stx) == 0) uid = stx.uid;
        }
        return .{ .start = start, .name = owned_name, .command = command, .uid = uid, .seen = s.samples };
    }

    /// Total and used bytes of the filesystem mounted at `path`.
    fn fsSize(path: [:0]const u8) ?[2]u64 {
        if (!is_linux or !builtin.link_libc or @sizeOf(usize) != 8) return null;
        var st: Statvfs = undefined;
        if (statvfs(path.ptr, &st) != 0) return null;
        const total = st.f_blocks * st.f_frsize;
        const free = st.f_bfree * st.f_frsize;
        return .{ total, total -| free };
    }
};

// glibc's and musl's struct statvfs on 64-bit Linux.
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    spare: [6]c_int,
};
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

/// A polite request to end: SIGTERM (never SIGKILL).
pub fn terminate(pid: u32) bool {
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch return false;
    return true;
}

/// The machine's static description, read once.
pub fn systemInfo(io: Io, arena: std.mem.Allocator, cpu_model: []const u8, threads: u32) SystemInfo {
    const R = struct {
        fn trimmed(i: Io, a: std.mem.Allocator, path: []const u8) []const u8 {
            var buf: [256]u8 = undefined;
            const v = std.mem.trim(u8, Io.Dir.cwd().readFile(i, path, &buf) catch "", " \n\t");
            return a.dupe(u8, v) catch "";
        }
    };
    var os: []const u8 = @tagName(builtin.os.tag);
    var buf: [4096]u8 = undefined;
    if (is_linux) {
        var lines = std.mem.tokenizeScalar(u8, Io.Dir.cwd().readFile(io, "/etc/os-release", &buf) catch "", '\n');
        while (lines.next()) |line| if (std.mem.startsWith(u8, line, "PRETTY_NAME=")) {
            os = arena.dupe(u8, std.mem.trim(u8, line["PRETTY_NAME=".len..], "\"")) catch os;
        };
    }
    const vendor = if (is_linux) R.trimmed(io, arena, "/sys/class/dmi/id/board_vendor") else "";
    const board = if (is_linux) R.trimmed(io, arena, "/sys/class/dmi/id/board_name") else "";
    const bios_v = if (is_linux) R.trimmed(io, arena, "/sys/class/dmi/id/bios_version") else "";
    const bios_d = if (is_linux) R.trimmed(io, arena, "/sys/class/dmi/id/bios_date") else "";
    return .{
        .hostname = if (is_linux) R.trimmed(io, arena, "/proc/sys/kernel/hostname") else "",
        .os = os,
        .kernel = if (is_linux) R.trimmed(io, arena, "/proc/sys/kernel/osrelease") else "",
        .arch = @tagName(builtin.cpu.arch),
        .board = std.mem.trim(u8, std.fmt.allocPrint(arena, "{s} {s}", .{ vendor, board }) catch "", " "),
        .bios = std.mem.trim(u8, std.fmt.allocPrint(arena, "{s} {s}", .{ bios_v, bios_d }) catch "", " "),
        .cpu_model = cpu_model,
        .threads = threads,
    };
}

test "sampler: 50 samples" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = Sampler.init(gpa, io);
    defer s.deinit(io);

    var times: [50]f64 = undefined;
    var last_rows: usize = 0;
    for (&times) |*t| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try s.sample(io, arena.allocator());
        t.* = r.sample_time_ms;
        last_rows = r.processes.len;
    }
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (times) |t| sum += t;
    std.debug.print("\nsampler: avg {d:.2} ms, p50 {d:.2}, p90 {d:.2}, min {d:.2}, max {d:.2} ({d} rows)\n", .{
        sum / 50, times[25], times[45], times[0], times[49], last_rows,
    });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try s.sample(io, arena.allocator());
    std.debug.print("cpu {d:.1}% ({d} cores, {d:.0} MHz, temp {?d:.1}), load {d:.2} {d:.2} {d:.2}, threads {d}\n", .{
        r.cpu.percent, r.cpu.per_core.len, r.cpu.freq_mhz, r.cpu.temp_c, r.cpu.load_avg.?[0], r.cpu.load_avg.?[1], r.cpu.load_avg.?[2], r.threads_total,
    });
    for (r.disks) |d| std.debug.print("disk {s} {s} {s} {d}/{d} r {d:.0} w {d:.0}\n", .{ d.name, d.mount, d.fs, d.used_bytes, d.total_bytes, d.read_bps, d.write_bps });
    for (r.net) |n| std.debug.print("net {s} up={} rx {d:.0}/s tx {d:.0}/s\n", .{ n.name, n.up, n.rx_bps, n.tx_bps });
    for (r.sensors) |x| std.debug.print("sensor {s} {d:.1}\n", .{ x.name, x.temp_c });
    for (r.processes[0..@min(5, r.processes.len)]) |p| std.debug.print("proc {d} {s} [{s}] thr {d} {s}\n", .{ p.pid, p.name, p.user, p.threads, p.command });
}
