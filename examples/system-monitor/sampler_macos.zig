//! macOS telemetry, from the kernel's own interfaces (no subprocesses):
//!
//!   CPU, per core     host_processor_info(PROCESSOR_CPU_LOAD_INFO)
//!   memory            host_statistics64(HOST_VM_INFO64), as Activity Monitor
//!                     counts it (app + wired + compressed used; file-backed cached)
//!   processes         proc_listallpids, proc_pidinfo(PROC_PIDTASKALLINFO); the
//!                     command line (KERN_PROCARGS2) and user read once per process
//!   disks             getmntinfo: /, the Data volume, /Volumes/*
//!   network           sysctl NET_RT_IFLIST2 (64-bit counters)
//!   system            sysctl (model, OS version, Darwin release)
//!
//! No iowait (macOS doesn't count it), no frequency on Apple Silicon, and
//! no sensors (only through the undocumented SMC): null, 0, empty.
//! Processes of other users can't be read without root: they're listed,
//! with their names, at 0% and 0 B.

const std = @import("std");
const builtin = @import("builtin");
const tm = @import("telemetry.zig");

const Io = std.Io;

const mach_port_t = u32;
const kern_return_t = i32;

extern "c" fn mach_host_self() mach_port_t;
extern "c" var mach_task_self_: mach_port_t;
extern "c" fn host_processor_info(host: mach_port_t, flavor: i32, count: *u32, info: *?[*]i32, info_count: *u32) kern_return_t;
extern "c" fn host_statistics64(host: mach_port_t, flavor: i32, info: *anyopaque, count: *u32) kern_return_t;
extern "c" fn vm_deallocate(task: mach_port_t, address: usize, size: usize) kern_return_t;
extern "c" fn mach_timebase_info(info: *TimebaseInfo) kern_return_t;
extern "c" fn sysctlbyname(name: [*:0]const u8, old: ?*anyopaque, old_len: ?*usize, new: ?*anyopaque, new_len: usize) c_int;
extern "c" fn sysctl(name: [*]const c_int, name_len: c_uint, old: ?*anyopaque, old_len: ?*usize, new: ?*anyopaque, new_len: usize) c_int;
extern "c" fn getloadavg(loads: [*]f64, n: c_int) c_int;
extern "c" fn proc_listallpids(buf: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buf: ?*anyopaque, size: c_int) c_int;
extern "c" fn if_indextoname(index: c_uint, name: [*]u8) ?[*:0]u8;
extern "c" fn getpwuid(uid: u32) ?*const Passwd;
extern "c" fn gethostname(name: [*]u8, len: usize) c_int;
extern "c" fn time(t: ?*i64) i64;
/// The 64-bit-inode getmntinfo: Intel Macs need its $INODE64 name.
const getmntinfo = @extern(*const fn (buf: *?[*]Statfs, flags: c_int) callconv(.c) c_int, .{
    .name = if (builtin.cpu.arch == .x86_64) "getmntinfo$INODE64" else "getmntinfo",
});

const PROCESSOR_CPU_LOAD_INFO = 2;
const HOST_VM_INFO64 = 4;
const PROC_PIDTASKALLINFO = 2;
const PROC_PIDT_SHORTBSDINFO = 13;
const MNT_NOWAIT = 2;
const MNT_LOCAL = 0x1000;
const CTL_KERN = 1;
const KERN_PROCARGS2 = 49;
const CTL_NET = 4;
const PF_ROUTE = 17;
const NET_RT_IFLIST2 = 6;
const RTM_IFINFO2 = 0x12;
const IFF_UP = 0x1;
const IFF_LOOPBACK = 0x8;
const IFF_RUNNING = 0x40;

const TimebaseInfo = extern struct { numer: u32, denom: u32 };

const Passwd = extern struct { name: ?[*:0]const u8 };

const VmStatistics64 = extern struct {
    free_count: u32,
    active_count: u32,
    inactive_count: u32,
    wire_count: u32,
    zero_fill_count: u64,
    reactivations: u64,
    pageins: u64,
    pageouts: u64,
    faults: u64,
    cow_faults: u64,
    lookups: u64,
    hits: u64,
    purges: u64,
    purgeable_count: u32,
    speculative_count: u32,
    decompressions: u64,
    compressions: u64,
    swapins: u64,
    swapouts: u64,
    compressor_page_count: u32,
    throttled_count: u32,
    external_page_count: u32,
    internal_page_count: u32,
    total_uncompressed_pages_in_compressor: u64,
};

const ProcBsdInfo = extern struct {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu_1: u32,
    comm: [16]u8,
    name: [32]u8,
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
};

const ProcTaskInfo = extern struct {
    virtual_size: u64,
    resident_size: u64,
    total_user: u64, // mach absolute time
    total_system: u64,
    threads_user: u64,
    threads_system: u64,
    policy: i32,
    faults: i32,
    pageins: i32,
    cow_faults: i32,
    messages_sent: i32,
    messages_received: i32,
    syscalls_mach: i32,
    syscalls_unix: i32,
    csw: i32,
    threadnum: i32,
    numrunning: i32,
    priority: i32,
};

const ProcTaskAllInfo = extern struct { bsd: ProcBsdInfo, task: ProcTaskInfo };

const ProcBsdShortInfo = extern struct {
    pid: u32,
    ppid: u32,
    pgid: u32,
    status: u32,
    comm: [16]u8,
    flags: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu: u32,
};

const Statfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    fsid: [2]i32,
    owner: u32,
    type: u32,
    flags: u32,
    fssubtype: u32,
    fstypename: [16]u8,
    mntonname: [1024]u8,
    mntfromname: [1024]u8,
    flags_ext: u32,
    reserved: [7]u32,
};

const XswUsage = extern struct { total: u64, avail: u64, used: u64, pagesize: u32, encrypted: bool };

// The layouts in the macOS SDK's headers: a mistake would read the wrong
// fields, so it fails the build instead.
comptime {
    std.debug.assert(@sizeOf(VmStatistics64) == 152);
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@sizeOf(ProcTaskInfo) == 96);
    std.debug.assert(@sizeOf(ProcTaskAllInfo) == 232);
    std.debug.assert(@sizeOf(ProcBsdShortInfo) == 64);
    std.debug.assert(@sizeOf(Statfs) == 2168);
    std.debug.assert(@offsetOf(Statfs, "mntonname") == 88);
    std.debug.assert(@sizeOf(XswUsage) == 32);
}

// if_msghdr2 (net/if.h), read by offset: messages aren't aligned.
const ifm_type = 3;
const ifm_flags = 8;
const ifm_index = 12;
const ifm_data = 32; // if_data64
const ifi_ibytes = ifm_data + 64;
const ifi_obytes = ifm_data + 72;

const CoreTicks = struct { user: u64 = 0, system: u64 = 0, idle: u64 = 0, nice: u64 = 0 };

const ProcPrev = struct { start: u64, ns: u64 };

const ProcMeta = struct {
    start: u64,
    name: []u8,
    command: []u8,
    user: []u8,
    seen: u64,
};

const NetPrev = struct { name: []u8, rx: u64, tx: u64 };

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    cores: u32 = 1,
    cpu_model_buf: [128]u8 = undefined,
    cpu_model_len: usize = 0,
    timebase: TimebaseInfo = .{ .numer = 1, .denom = 1 },
    prev: CoreTicks = .{},
    prev_cores: std.ArrayList(CoreTicks) = .empty,
    prev_procs: std.AutoHashMap(u32, ProcPrev),
    curr_procs: std.AutoHashMap(u32, ProcPrev),
    meta: std.AutoHashMap(u32, ProcMeta),
    users: std.AutoHashMap(u32, []u8),
    nets: std.ArrayList(NetPrev) = .empty,
    pids: []c_int = &.{},
    args_buf: []u8 = &.{},
    prev_time: ?Io.Clock.Timestamp = null,
    samples: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: ?Io) Sampler {
        var s = Sampler{
            .gpa = gpa,
            .cores = @intCast(@max(1, std.Thread.getCpuCount() catch 1)),
            .prev_procs = .init(gpa),
            .curr_procs = .init(gpa),
            .meta = .init(gpa),
            .users = .init(gpa),
        };
        _ = mach_timebase_info(&s.timebase);
        if (s.timebase.denom == 0) s.timebase = .{ .numer = 1, .denom = 1 };
        var len: usize = s.cpu_model_buf.len;
        if (sysctlbyname("machdep.cpu.brand_string", &s.cpu_model_buf, &len, null, 0) == 0) {
            s.cpu_model_len = std.mem.indexOfScalar(u8, s.cpu_model_buf[0..len], 0) orelse len;
        }
        // KERN_PROCARGS2's buffer: kern.argmax bytes.
        var argmax: c_int = 0;
        var argmax_len: usize = @sizeOf(c_int);
        _ = sysctlbyname("kern.argmax", &argmax, &argmax_len, null, 0);
        s.args_buf = gpa.alloc(u8, @intCast(std.math.clamp(argmax, 4096, 1024 * 1024))) catch &.{};
        if (io) |actual_io| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            _ = s.sample(actual_io, arena.allocator()) catch {};
        }
        return s;
    }

    pub fn deinit(s: *Sampler, _: Io) void {
        s.prev_cores.deinit(s.gpa);
        s.prev_procs.deinit();
        s.curr_procs.deinit();
        var mit = s.meta.valueIterator();
        while (mit.next()) |m| freeMeta(s.gpa, m.*);
        s.meta.deinit();
        var uit = s.users.valueIterator();
        while (uit.next()) |u| s.gpa.free(u.*);
        s.users.deinit();
        for (s.nets.items) |n| s.gpa.free(n.name);
        s.nets.deinit(s.gpa);
        s.gpa.free(s.pids);
        s.gpa.free(s.args_buf);
    }

    fn freeMeta(gpa: std.mem.Allocator, m: ProcMeta) void {
        gpa.free(m.name);
        gpa.free(m.command);
        gpa.free(m.user);
    }

    pub fn cpuModel(s: *const Sampler) []const u8 {
        return if (s.cpu_model_len > 0) s.cpu_model_buf[0..s.cpu_model_len] else "Host CPU";
    }

    pub fn cpuCount(s: *const Sampler) u32 {
        return s.cores;
    }

    /// Mach absolute time to nanoseconds (1:1 on Intel, 125:3 on Apple Silicon).
    fn toNs(s: *const Sampler, t: u64) u64 {
        return @intCast(@as(u128, t) * s.timebase.numer / s.timebase.denom);
    }

    pub fn sample(s: *Sampler, io: Io, arena: std.mem.Allocator) !tm.SystemSample {
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        s.samples += 1;
        const dt_ns: u64 = if (s.prev_time) |p| @intCast(@max(0, p.durationTo(t0).raw.toNanoseconds())) else 0;
        const dt_s: f64 = @as(f64, @floatFromInt(dt_ns)) / 1e9;
        s.prev_time = t0;

        var cpu: tm.CpuInfo = .{
            .percent = 0,
            .user_percent = 0,
            .system_percent = 0,
            .iowait_percent = null,
            .cores = s.cores,
            .model = try arena.dupe(u8, s.cpuModel()),
            .freq_mhz = 0,
            .temp_c = null,
            .load_avg = null,
            .per_core = &.{},
        };

        // CPU: each core's user, system, idle and nice ticks.
        {
            var count: u32 = 0;
            var info: ?[*]i32 = null;
            var info_count: u32 = 0;
            if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &info_count) == 0) if (info) |ticks| {
                defer _ = vm_deallocate(mach_task_self_, @intFromPtr(ticks), info_count * @sizeOf(i32));
                const cores = try arena.alloc(tm.CoreSample, count);
                var sum: CoreTicks = .{};
                for (cores, 0..) |*c, i| {
                    const v = ticks[i * 4 ..][0..4];
                    const now: CoreTicks = .{ .user = @as(u32, @bitCast(v[0])), .system = @as(u32, @bitCast(v[1])), .idle = @as(u32, @bitCast(v[2])), .nice = @as(u32, @bitCast(v[3])) };
                    if (i >= s.prev_cores.items.len) try s.prev_cores.append(s.gpa, .{});
                    const p = &s.prev_cores.items[i];
                    const busy = (now.user + now.system + now.nice) -| (p.user + p.system + p.nice);
                    const total = busy + (now.idle -| p.idle);
                    c.* = .{ .percent = if (p.idle + p.user > 0) tm.pct(busy, total) else 0, .freq_mhz = 0 };
                    p.* = now;
                    sum.user += now.user;
                    sum.system += now.system;
                    sum.idle += now.idle;
                    sum.nice += now.nice;
                }
                const p = s.prev;
                if (p.idle + p.user > 0) {
                    const user = (sum.user + sum.nice) -| (p.user + p.nice);
                    const system = sum.system -| p.system;
                    const total = user + system + (sum.idle -| p.idle);
                    cpu.percent = tm.pct(user + system, total);
                    cpu.user_percent = tm.pct(user, total);
                    cpu.system_percent = tm.pct(system, total);
                }
                s.prev = sum;
                cpu.per_core = cores;
            };
            // Intel Macs tell their frequency; Apple Silicon doesn't.
            var hz: u64 = 0;
            var hz_len: usize = @sizeOf(u64);
            if (sysctlbyname("hw.cpufrequency", &hz, &hz_len, null, 0) == 0 and hz > 0) {
                cpu.freq_mhz = @round(@as(f64, @floatFromInt(hz)) / 1e6);
                for (cpu.per_core) |*c| c.freq_mhz = cpu.freq_mhz;
            }
            var la: [3]f64 = undefined;
            if (getloadavg(&la, 3) == 3) cpu.load_avg = .{ @round(la[0] * 100) / 100, @round(la[1] * 100) / 100, @round(la[2] * 100) / 100 };
        }

        // Memory, as Activity Monitor counts it.
        var mem = std.mem.zeroes(tm.MemInfo);
        {
            var total: u64 = 0;
            var len: usize = @sizeOf(u64);
            _ = sysctlbyname("hw.memsize", &total, &len, null, 0);
            var page: u64 = 0;
            len = @sizeOf(u64);
            if (sysctlbyname("hw.pagesize", &page, &len, null, 0) != 0 or page == 0) page = 16384;
            var vm: VmStatistics64 = undefined;
            var count: u32 = @sizeOf(VmStatistics64) / @sizeOf(u32);
            if (host_statistics64(mach_host_self(), HOST_VM_INFO64, &vm, &count) == 0) {
                const app = @as(u64, vm.internal_page_count) -| vm.purgeable_count;
                mem.used_bytes = (app + vm.wire_count + vm.compressor_page_count) * page;
                mem.cached_bytes = (@as(u64, vm.external_page_count) + vm.purgeable_count) * page;
                mem.free_bytes = (@as(u64, vm.free_count) + vm.speculative_count) * page;
            }
            mem.total_bytes = total;
            mem.available_bytes = total -| mem.used_bytes;
            mem.percent = tm.pct(mem.used_bytes, total);
            var swap: XswUsage = undefined;
            len = @sizeOf(XswUsage);
            if (sysctlbyname("vm.swapusage", &swap, &len, null, 0) == 0) {
                mem.swap_total_bytes = swap.total;
                mem.swap_used_bytes = swap.used;
            }
        }

        // Uptime: since kern.boottime.
        var uptime: u64 = 0;
        {
            var boot: extern struct { sec: i64, usec: i32, pad: i32 } = undefined;
            var len: usize = @sizeOf(@TypeOf(boot));
            if (sysctlbyname("kern.boottime", &boot, &len, null, 0) == 0) uptime = @intCast(@max(0, time(null) - boot.sec));
        }

        // Processes: every pid, its task info when this user may read it.
        var procs: std.ArrayList(tm.ProcessRow) = .empty;
        try procs.ensureTotalCapacity(arena, 1024);
        var starts: std.AutoHashMapUnmanaged(u32, u64) = .empty;
        var threads_total: u32 = 0;
        var running: u32 = 0;
        s.curr_procs.clearRetainingCapacity();
        {
            const n_hint = proc_listallpids(null, 0);
            const want: usize = @intCast(@max(n_hint, 0) + 64);
            if (s.pids.len < want) {
                s.gpa.free(s.pids);
                s.pids = s.gpa.alloc(c_int, want * 2) catch &.{};
            }
            const n = proc_listallpids(s.pids.ptr, @intCast(s.pids.len * @sizeOf(c_int)));
            for (s.pids[0..@intCast(@max(n, 0))]) |pid_c| {
                if (pid_c <= 0) continue;
                const pid: u32 = @intCast(pid_c);
                var all: ProcTaskAllInfo = undefined;
                if (proc_pidinfo(pid_c, PROC_PIDTASKALLINFO, 0, &all, @sizeOf(ProcTaskAllInfo)) == @sizeOf(ProcTaskAllInfo)) {
                    const ns = s.toNs(all.task.total_user + all.task.total_system);
                    const start = all.bsd.start_tvsec;
                    s.curr_procs.put(pid, .{ .start = start, .ns = ns }) catch {};
                    var p_cpu: f64 = 0;
                    if (s.prev_procs.get(pid)) |prev| if (prev.start == start and ns >= prev.ns and dt_ns > 0) {
                        p_cpu = tm.pct(ns - prev.ns, dt_ns);
                    };
                    starts.put(arena, pid, start) catch {};
                    threads_total += @intCast(@max(0, all.task.threadnum));
                    running += @intCast(@max(0, all.task.numrunning));
                    const name = std.mem.sliceTo(&all.bsd.name, 0);
                    try procs.append(arena, .{
                        .pid = pid,
                        .name = try arena.dupe(u8, if (name.len > 0) name else std.mem.sliceTo(&all.bsd.comm, 0)),
                        .command = "",
                        .user = "",
                        .state = stateOf(all.bsd.status),
                        .threads = @intCast(@max(0, all.task.threadnum)),
                        .cpu_percent = p_cpu,
                        .mem_rss_bytes = all.task.resident_size,
                    });
                    continue;
                }
                // Another user's (root's): its name and owner only.
                var short: ProcBsdShortInfo = undefined;
                if (proc_pidinfo(pid_c, PROC_PIDT_SHORTBSDINFO, 0, &short, @sizeOf(ProcBsdShortInfo)) != @sizeOf(ProcBsdShortInfo)) continue;
                try procs.append(arena, .{
                    .pid = pid,
                    .name = try arena.dupe(u8, std.mem.sliceTo(&short.comm, 0)),
                    .command = "",
                    .user = try arena.dupe(u8, s.userName(short.uid)),
                    .state = stateOf(short.status),
                    .threads = 0,
                    .cpu_percent = 0,
                    .mem_rss_bytes = 0,
                });
            }
        }
        std.mem.swap(std.AutoHashMap(u32, ProcPrev), &s.prev_procs, &s.curr_procs);
        const total_procs: u32 = @intCast(procs.items.len);
        tm.busiestFirst(procs.items);
        const top = procs.items[0..@min(procs.items.len, tm.max_rows)];
        for (top) |*p| {
            const start = starts.get(p.pid) orelse continue; // not readable
            const gop = s.meta.getOrPut(p.pid) catch continue;
            var have = gop.found_existing;
            if (have and gop.value_ptr.start != start) {
                freeMeta(s.gpa, gop.value_ptr.*);
                have = false;
            }
            if (!have) gop.value_ptr.* = s.readMeta(p.pid, p.name, start) orelse {
                s.meta.removeByPtr(gop.key_ptr);
                continue;
            };
            const m = gop.value_ptr;
            m.seen = s.samples;
            p.name = try arena.dupe(u8, m.name);
            p.command = try arena.dupe(u8, m.command[0..@min(m.command.len, tm.max_command)]);
            p.user = try arena.dupe(u8, m.user);
        }
        if (s.samples % 16 == 0) {
            var stale: std.ArrayList(u32) = .empty;
            var mit = s.meta.iterator();
            while (mit.next()) |e| if (e.value_ptr.seen + 16 < s.samples) stale.append(arena, e.key_ptr.*) catch {};
            for (stale.items) |pid| if (s.meta.fetchRemove(pid)) |kv| freeMeta(s.gpa, kv.value);
        }

        // Disks: the system and data volumes, and what's under /Volumes.
        var disks: std.ArrayList(tm.DiskSample) = .empty;
        {
            var mounts: ?[*]Statfs = null;
            const n = getmntinfo(&mounts, MNT_NOWAIT);
            if (mounts) |m| for (m[0..@intCast(@max(n, 0))]) |*f| {
                if (f.flags & MNT_LOCAL == 0) continue;
                const on = std.mem.sliceTo(&f.mntonname, 0);
                const fs = std.mem.sliceTo(&f.fstypename, 0);
                if (std.mem.eql(u8, fs, "devfs") or std.mem.eql(u8, fs, "autofs")) continue;
                const name = if (std.mem.eql(u8, on, "/"))
                    "root"
                else if (std.mem.eql(u8, on, "/System/Volumes/Data"))
                    "data"
                else if (std.mem.startsWith(u8, on, "/Volumes/"))
                    std.fs.path.basename(on)
                else
                    continue;
                const total = f.blocks * f.bsize;
                try disks.append(arena, .{
                    .name = try arena.dupe(u8, name),
                    .mount = try arena.dupe(u8, on),
                    .device = try arena.dupe(u8, std.mem.sliceTo(&f.mntfromname, 0)),
                    .fs = try arena.dupe(u8, fs),
                    .total_bytes = total,
                    .used_bytes = total -| f.bfree * f.bsize,
                    .read_bps = 0,
                    .write_bps = 0,
                });
            };
        }

        // Network: NET_RT_IFLIST2's interface messages, up and not virtual.
        var nets: std.ArrayList(tm.NetSample) = .empty;
        {
            const mib = [_]c_int{ CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0 };
            var len: usize = 0;
            if (sysctl(&mib, mib.len, null, &len, null, 0) == 0 and len > 0) {
                const buf = try arena.alloc(u8, len + 4096);
                len = buf.len;
                if (sysctl(&mib, mib.len, buf.ptr, &len, null, 0) == 0) {
                    var off: usize = 0;
                    while (off + 4 <= len) {
                        const msg_len = std.mem.readInt(u16, buf[off..][0..2], .little);
                        if (msg_len == 0) break;
                        defer off += msg_len;
                        if (buf[off + ifm_type] != RTM_IFINFO2 or off + ifi_obytes + 8 > len) continue;
                        const flags = std.mem.readInt(i32, buf[off + ifm_flags ..][0..4], .little);
                        if (flags & IFF_LOOPBACK != 0) continue;
                        const index = std.mem.readInt(u16, buf[off + ifm_index ..][0..2], .little);
                        var name_buf: [32]u8 = undefined;
                        const name_z = if_indextoname(index, &name_buf) orelse continue;
                        const name = std.mem.span(name_z);
                        if (virtualInterface(name)) continue;
                        const rx = std.mem.readInt(u64, buf[off + ifi_ibytes ..][0..8], .little);
                        const tx = std.mem.readInt(u64, buf[off + ifi_obytes ..][0..8], .little);
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
                        try nets.append(arena, .{
                            .name = try arena.dupe(u8, name),
                            .up = flags & IFF_UP != 0 and flags & IFF_RUNNING != 0,
                            .rx_bps = rx_bps,
                            .tx_bps = tx_bps,
                            .rx_total = rx,
                            .tx_total = tx,
                        });
                    }
                }
            }
        }

        const t1 = Io.Clock.Timestamp.now(io, .awake);
        return .{
            .cpu = cpu,
            .mem = mem,
            .uptime_seconds = uptime,
            .processes = top,
            .total_processes = total_procs,
            .threads_total = threads_total,
            .running = running,
            .disks = disks.items,
            .net = nets.items,
            .sensors = &.{},
            .sample_time_ms = @as(f64, @floatFromInt(t0.durationTo(t1).raw.toNanoseconds())) / 1e6,
            .engine = "Mach + libproc + sysctl (0 spawns)",
        };
    }

    fn userName(s: *Sampler, uid: u32) []const u8 {
        if (s.users.get(uid)) |u| return u;
        const pw = getpwuid(uid);
        const name = if (pw) |p| (if (p.name) |n| std.mem.span(n) else "") else "";
        const owned = (if (name.len > 0) s.gpa.dupe(u8, name) else std.fmt.allocPrint(s.gpa, "{d}", .{uid})) catch return "";
        s.users.put(uid, owned) catch {
            s.gpa.free(owned);
            return "";
        };
        return owned;
    }

    /// A process's display name, command line and user, read once.
    fn readMeta(s: *Sampler, pid: u32, name: []const u8, start: u64) ?ProcMeta {
        var short: ProcBsdShortInfo = undefined;
        const uid: u32 = if (proc_pidinfo(@intCast(pid), PROC_PIDT_SHORTBSDINFO, 0, &short, @sizeOf(ProcBsdShortInfo)) == @sizeOf(ProcBsdShortInfo)) short.uid else 0;
        const command = s.argsOf(s.gpa, pid) orelse (s.gpa.dupe(u8, "") catch return null);
        // The executable's own name when the kernel's is cut short.
        var display = name;
        const arg0 = command[0 .. std.mem.indexOfScalar(u8, command, ' ') orelse command.len];
        const base = std.fs.path.basename(arg0);
        if (base.len > name.len and std.mem.startsWith(u8, base, name)) display = base;
        const owned_name = s.gpa.dupe(u8, display) catch {
            s.gpa.free(command);
            return null;
        };
        const user = s.gpa.dupe(u8, s.userName(uid)) catch {
            s.gpa.free(command);
            s.gpa.free(owned_name);
            return null;
        };
        return .{ .start = start, .name = owned_name, .command = command, .user = user, .seen = s.samples };
    }

    /// KERN_PROCARGS2: argc, the executable's path, then argc arguments,
    /// NUL-separated. The arguments, space-separated.
    fn argsOf(s: *Sampler, a: std.mem.Allocator, pid: u32) ?[]u8 {
        if (s.args_buf.len == 0) return null;
        const mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, @intCast(pid) };
        var len: usize = s.args_buf.len;
        if (sysctl(&mib, mib.len, s.args_buf.ptr, &len, null, 0) != 0 or len < 4) return null;
        const buf = s.args_buf[0..len];
        const argc: usize = @intCast(@max(0, std.mem.readInt(i32, buf[0..4], .little)));
        var i: usize = 4;
        while (i < buf.len and buf[i] != 0) i += 1; // the executable's path
        while (i < buf.len and buf[i] == 0) i += 1; // its padding
        var out: std.ArrayList(u8) = .empty;
        var n: usize = 0;
        while (n < argc and i < buf.len) : (n += 1) {
            const end = std.mem.indexOfScalarPos(u8, buf, i, 0) orelse buf.len;
            if (n > 0) out.append(a, ' ') catch break;
            out.appendSlice(a, buf[i..end]) catch break;
            i = end + 1;
        }
        return out.toOwnedSlice(a) catch null;
    }

    /// A process's whole command line (empty when it can't be read).
    pub fn commandLine(s: *Sampler, _: Io, arena: std.mem.Allocator, pid: u32) []const u8 {
        return s.argsOf(arena, pid) orelse "";
    }
};

/// The kernel's p_stat: SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5.
fn stateOf(status: u32) []const u8 {
    return switch (status) {
        2 => "R",
        3 => "S",
        4 => "T",
        5 => "Z",
        else => "?",
    };
}

/// The interfaces macOS makes for itself (tunnels, AirDrop, bridges).
fn virtualInterface(name: []const u8) bool {
    const prefixes = [_][]const u8{ "lo", "utun", "awdl", "llw", "bridge", "ap", "anpi", "gif", "stf", "ipsec" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// A polite request to end: SIGTERM (never SIGKILL).
pub fn terminate(pid: u32) bool {
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch return false;
    return true;
}

fn sysctlString(a: std.mem.Allocator, name: [*:0]const u8) []const u8 {
    var buf: [256]u8 = undefined;
    var len: usize = buf.len;
    if (sysctlbyname(name, &buf, &len, null, 0) != 0) return "";
    return a.dupe(u8, std.mem.sliceTo(buf[0..len], 0)) catch "";
}

/// The machine's static description, read once.
pub fn systemInfo(_: Io, arena: std.mem.Allocator, cpu_model: []const u8, threads: u32) tm.SystemInfo {
    var host: [256]u8 = undefined;
    const hostname = if (gethostname(&host, host.len) == 0) arena.dupe(u8, std.mem.sliceTo(&host, 0)) catch "" else "";
    return .{
        .hostname = hostname,
        .os = std.fmt.allocPrint(arena, "macOS {s}", .{sysctlString(arena, "kern.osproductversion")}) catch "macOS",
        .kernel = std.fmt.allocPrint(arena, "Darwin {s}", .{sysctlString(arena, "kern.osrelease")}) catch "",
        .arch = @tagName(builtin.cpu.arch),
        .board = sysctlString(arena, "hw.model"),
        .bios = "",
        .cpu_model = cpu_model,
        .threads = threads,
    };
}

test "sampler: 20 samples, and what one holds" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var s = Sampler.init(gpa, io);
    defer s.deinit(io);
    var times: [20]f64 = undefined;
    for (&times) |*t| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        t.* = (try s.sample(io, arena.allocator())).sample_time_ms;
    }
    std.mem.sort(f64, &times, {}, std.sort.asc(f64));
    std.debug.print("\nsampler: p50 {d:.2} ms, max {d:.2} ms\n", .{ times[10], times[19] });

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try s.sample(io, a);
    const info = systemInfo(io, a, s.cpuModel(), s.cpuCount());
    std.debug.print("system: {s} | {s} | {s} | {s} | board {s} | bios {s}\n", .{ info.hostname, info.os, info.kernel, info.arch, info.board, info.bios });
    std.debug.print("cpu {d:.1}% (user {d:.1}, system {d:.1}, iowait {?d:.1}) {s}, {d} cores, {d:.0} MHz, temp {?d:.1}, load {any}\n", .{
        r.cpu.percent, r.cpu.user_percent, r.cpu.system_percent, r.cpu.iowait_percent, r.cpu.model, r.cpu.per_core.len, r.cpu.freq_mhz, r.cpu.temp_c, r.cpu.load_avg,
    });
    for (r.cpu.per_core, 0..) |c, i| std.debug.print("  core {d}: {d:.1}% {d:.0} MHz\n", .{ i, c.percent, c.freq_mhz });
    std.debug.print("mem used {d} / {d} ({d:.1}%), available {d}, cached {d}, free {d}, swap {d} / {d}\n", .{
        r.mem.used_bytes, r.mem.total_bytes, r.mem.percent, r.mem.available_bytes, r.mem.cached_bytes, r.mem.free_bytes, r.mem.swap_used_bytes, r.mem.swap_total_bytes,
    });
    std.debug.print("uptime {d} s, {d} processes, {d} threads, {d} running\n", .{ r.uptime_seconds, r.total_processes, r.threads_total, r.running });
    for (r.disks) |d| std.debug.print("disk {s} at {s} ({s}, {s}): {d} / {d}, r {d:.0} B/s w {d:.0} B/s\n", .{ d.name, d.mount, d.fs, d.device, d.used_bytes, d.total_bytes, d.read_bps, d.write_bps });
    for (r.net) |n| std.debug.print("net {s} up={} rx {d:.0} B/s tx {d:.0} B/s, totals {d} / {d}\n", .{ n.name, n.up, n.rx_bps, n.tx_bps, n.rx_total, n.tx_total });
    for (r.processes[0..@min(8, r.processes.len)]) |p| std.debug.print("proc {d} {s} [{s}] {s} thr {d} cpu {d:.1}% rss {d} | {s}\n", .{ p.pid, p.name, p.user, p.state, p.threads, p.cpu_percent, p.mem_rss_bytes, p.command });
    try std.testing.expect(r.cpu.per_core.len > 0);
    try std.testing.expect(r.mem.total_bytes > 0);
    try std.testing.expect(r.total_processes > 0);
}
