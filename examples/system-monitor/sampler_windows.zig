//! Windows telemetry, from the OS's own calls (no WMI, no subprocesses):
//!
//!   CPU, per core     NtQuerySystemInformation(SystemProcessorPerformanceInformation)
//!   frequencies       CallNtPowerInformation(ProcessorInformation)
//!   processes         NtQuerySystemInformation(SystemProcessInformation): every
//!                     process's name, threads, CPU times and working set in one call
//!   user, command     the process's token, NtQueryInformationProcess(ProcessCommandLineInformation),
//!                     read once while it lives
//!   memory            GlobalMemoryStatusEx, GetPerformanceInfo (cache, threads)
//!   disks             GetLogicalDriveStrings, GetDiskFreeSpaceEx, IOCTL_DISK_PERFORMANCE
//!   network           GetIfTable2 (hardware interfaces)
//!
//! Windows has no load average, no iowait and no sensors an app can read
//! without WMI and often administrator rights: those stay null or empty,
//! and the page hides them.

const std = @import("std");
const builtin = @import("builtin");
const tm = @import("telemetry.zig");

const Io = std.Io;

const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const BOOL = i32;
const HKEY = *opaque {};

// ntdll
extern "ntdll" fn NtQuerySystemInformation(class: u32, info: ?*anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) i32;
extern "ntdll" fn NtQueryInformationProcess(process: HANDLE, class: u32, info: ?*anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) i32;
extern "ntdll" fn RtlGetVersion(info: *OSVERSIONINFOW) callconv(.winapi) i32;
// powrprof
extern "powrprof" fn CallNtPowerInformation(level: i32, in: ?*anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32) callconv(.winapi) i32;
// kernel32
extern "kernel32" fn GlobalMemoryStatusEx(m: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetPerformanceInfo(p: *PERFORMANCE_INFORMATION, cb: u32) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GetLogicalDriveStringsW(len: u32, buf: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetDiskFreeSpaceExW(dir: [*:0]const u16, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) BOOL;
extern "kernel32" fn GetVolumeInformationW(root: [*:0]const u16, name: ?[*]u16, name_len: u32, serial: ?*u32, max_component: ?*u32, flags: ?*u32, fs_name: ?[*]u16, fs_name_len: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn DeviceIoControl(h: HANDLE, code: u32, in: ?*anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, ret: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn GetComputerNameExW(format: i32, buf: [*]u16, size: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetErrorMode(mode: u32) callconv(.winapi) u32;
// advapi32
extern "advapi32" fn OpenProcessToken(process: HANDLE, access: u32, token: *HANDLE) callconv(.winapi) BOOL;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: u32, info: ?*anyopaque, len: u32, ret: *u32) callconv(.winapi) BOOL;
extern "advapi32" fn LookupAccountSidW(system: ?[*:0]const u16, sid: *anyopaque, name: [*]u16, name_len: *u32, domain: [*]u16, domain_len: *u32, use: *u32) callconv(.winapi) BOOL;
extern "advapi32" fn RegGetValueW(key: HKEY, subkey: ?[*:0]const u16, value: ?[*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;
// iphlpapi
extern "iphlpapi" fn GetIfTable2(table: *?*MIB_IF_TABLE2) callconv(.winapi) u32;
extern "iphlpapi" fn FreeMibTable(memory: ?*anyopaque) callconv(.winapi) void;
// user32
extern "user32" fn EnumWindows(callback: *const fn (HWND, isize) callconv(.winapi) BOOL, lparam: isize) callconv(.winapi) BOOL;
extern "user32" fn GetWindowThreadProcessId(window: HWND, pid: *u32) callconv(.winapi) u32;
extern "user32" fn GetWindow(window: HWND, cmd: u32) callconv(.winapi) HWND;
extern "user32" fn IsWindowVisible(window: HWND) callconv(.winapi) BOOL;
extern "user32" fn PostMessageW(window: HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) BOOL;

const SystemProcessInformation = 5;
const SystemProcessorPerformanceInformation = 8;
const ProcessorInformation = 11;
const ProcessCommandLineInformation = 60;
const STATUS_INFO_LENGTH_MISMATCH: i32 = @bitCast(@as(u32, 0xC0000004));
const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
const TOKEN_QUERY = 0x0008;
const TokenUser = 1;
const DRIVE_REMOVABLE = 2;
const DRIVE_FIXED = 3;
const IOCTL_DISK_PERFORMANCE = 0x70020;
const OPEN_EXISTING = 3;
const FILE_SHARE_READ_WRITE = 3;
const SEM_FAILCRITICALERRORS = 1;
const IF_TYPE_SOFTWARE_LOOPBACK = 24;
const IF_OPER_STATUS_UP = 1;
const RRF_RT_REG_SZ = 0x2;
const GW_OWNER = 4;
const WM_CLOSE = 0x0010;
const ComputerNameDnsHostname = 1;
const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000002)))))));

const SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = extern struct {
    idle: i64,
    kernel: i64, // idle included
    user: i64,
    dpc: i64,
    interrupt: i64,
    interrupt_count: u32,
};

const PROCESSOR_POWER_INFORMATION = extern struct {
    number: u32,
    max_mhz: u32,
    current_mhz: u32,
    mhz_limit: u32,
    max_idle_state: u32,
    current_idle_state: u32,
};

const UNICODE_STRING = extern struct {
    len: u16, // bytes
    max: u16,
    buf: ?[*]u16,
};

/// The leading part of the process records NtQuerySystemInformation
/// returns, back to back (`next` bytes apart, 0 for the last).
const SYSTEM_PROCESS_INFORMATION = extern struct {
    next: u32,
    threads: u32,
    working_set_private: i64,
    hard_faults: u32,
    threads_high_watermark: u32,
    cycle_time: u64,
    create_time: i64,
    user_time: i64,
    kernel_time: i64,
    image_name: UNICODE_STRING,
    base_priority: i32,
    pid: usize,
    parent_pid: usize,
    handles: u32,
    session: u32,
    process_key: usize,
    peak_virtual: usize,
    virtual_size: usize,
    page_faults: u32,
    peak_working_set: usize,
    working_set: usize,
};

const MEMORYSTATUSEX = extern struct {
    length: u32 = @sizeOf(MEMORYSTATUSEX),
    load: u32 = 0,
    total_phys: u64 = 0,
    avail_phys: u64 = 0,
    total_page_file: u64 = 0,
    avail_page_file: u64 = 0,
    total_virtual: u64 = 0,
    avail_virtual: u64 = 0,
    avail_extended_virtual: u64 = 0,
};

const PERFORMANCE_INFORMATION = extern struct {
    cb: u32,
    commit_total: usize,
    commit_limit: usize,
    commit_peak: usize,
    physical_total: usize,
    physical_available: usize,
    system_cache: usize,
    kernel_total: usize,
    kernel_paged: usize,
    kernel_nonpaged: usize,
    page_size: usize,
    handle_count: u32,
    process_count: u32,
    thread_count: u32,
};

const DISK_PERFORMANCE = extern struct {
    bytes_read: i64,
    bytes_written: i64,
    read_time: i64,
    write_time: i64,
    idle_time: i64,
    read_count: u32,
    write_count: u32,
    queue_depth: u32,
    split_count: u32,
    query_time: i64,
    storage_device_number: u32,
    storage_manager_name: [8]u16,
};

const MIB_IF_ROW2 = extern struct {
    luid: u64,
    index: u32,
    guid: [16]u8,
    alias: [257]u16,
    description: [257]u16,
    phys_len: u32,
    phys: [32]u8,
    perm_phys: [32]u8,
    mtu: u32,
    if_type: u32,
    tunnel_type: u32,
    media_type: u32,
    physical_medium: u32,
    access_type: u32,
    direction: u32,
    /// InterfaceAndOperStatusFlags: bit 0 HardwareInterface.
    flags: u8,
    oper_status: u32,
    admin_status: u32,
    media_connect_state: u32,
    network_guid: [16]u8,
    connection_type: u32,
    transmit_link_speed: u64,
    receive_link_speed: u64,
    in_octets: u64,
    in_ucast_pkts: u64,
    in_nucast_pkts: u64,
    in_discards: u64,
    in_errors: u64,
    in_unknown_protos: u64,
    in_ucast_octets: u64,
    in_multicast_octets: u64,
    in_broadcast_octets: u64,
    out_octets: u64,
    out_ucast_pkts: u64,
    out_nucast_pkts: u64,
    out_discards: u64,
    out_errors: u64,
    out_ucast_octets: u64,
    out_multicast_octets: u64,
    out_broadcast_octets: u64,
    out_qlen: u64,
};

const MIB_IF_TABLE2 = extern struct {
    count: u32,
    table: [1]MIB_IF_ROW2, // `count` of them
};

const OSVERSIONINFOW = extern struct {
    size: u32 = @sizeOf(OSVERSIONINFOW),
    major: u32 = 0,
    minor: u32 = 0,
    build: u32 = 0,
    platform: u32 = 0,
    csd: [128]u16 = @splat(0),
};

// The layouts as the Windows SDK has them (64-bit): a mistake here would
// read the wrong fields, so it fails the build instead.
comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION) == 48);
        std.debug.assert(@offsetOf(SYSTEM_PROCESS_INFORMATION, "create_time") == 32);
        std.debug.assert(@offsetOf(SYSTEM_PROCESS_INFORMATION, "image_name") == 56);
        std.debug.assert(@offsetOf(SYSTEM_PROCESS_INFORMATION, "pid") == 80);
        std.debug.assert(@offsetOf(SYSTEM_PROCESS_INFORMATION, "working_set") == 144);
        std.debug.assert(@sizeOf(MEMORYSTATUSEX) == 64);
        std.debug.assert(@sizeOf(PERFORMANCE_INFORMATION) == 104);
        std.debug.assert(@sizeOf(DISK_PERFORMANCE) == 88);
        std.debug.assert(@sizeOf(MIB_IF_ROW2) == 1352);
        std.debug.assert(@offsetOf(MIB_IF_ROW2, "oper_status") == 1156);
        std.debug.assert(@offsetOf(MIB_IF_ROW2, "in_octets") == 1208);
        std.debug.assert(@offsetOf(MIB_IF_ROW2, "out_octets") == 1280);
        std.debug.assert(@offsetOf(MIB_IF_TABLE2, "table") == 8);
        std.debug.assert(@sizeOf(OSVERSIONINFOW) == 276);
    }
}

const CoreTimes = struct { busy: u64 = 0, total: u64 = 0, user: u64 = 0, system: u64 = 0 };

const ProcPrev = struct { create: i64, ticks: u64 };

/// A process's user and command line, read once (`create` tells a reused
/// pid apart).
const ProcMeta = struct {
    create: i64,
    user: []u8,
    command: []u8,
    seen: u64,
};

const Drive = struct {
    root: [4]u16, // "C:\" and its terminator
    name: []u8,
    fs: []u8,
    /// \\.\C: for IOCTL_DISK_PERFORMANCE (null when it can't be opened).
    volume: HANDLE,
    read: i64 = 0,
    written: i64 = 0,
    has_prev: bool = false,
};

const NetPrev = struct { luid: u64, rx: u64, tx: u64 };

pub const Sampler = struct {
    gpa: std.mem.Allocator,
    cores: u32 = 1,
    cpu_model_buf: [128]u8 = undefined,
    cpu_model_len: usize = 0,
    prev: CoreTimes = .{},
    prev_cores: std.ArrayList(CoreTimes) = .empty,
    prev_procs: std.AutoHashMap(u32, ProcPrev),
    curr_procs: std.AutoHashMap(u32, ProcPrev),
    meta: std.AutoHashMap(u32, ProcMeta),
    users: std.StringHashMap([]u8),
    proc_buf: []align(8) u8 = &.{},
    drives: std.ArrayList(Drive) = .empty,
    nets: std.ArrayList(NetPrev) = .empty,
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
        // No "insert a disk" dialog for an empty card reader.
        _ = SetErrorMode(SEM_FAILCRITICALERRORS);
        s.initCpuModel();
        s.loadDrives();
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
        while (mit.next()) |m| {
            s.gpa.free(m.user);
            s.gpa.free(m.command);
        }
        s.meta.deinit();
        var uit = s.users.iterator();
        while (uit.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.users.deinit();
        s.freeDrives();
        s.drives.deinit(s.gpa);
        s.nets.deinit(s.gpa);
        s.gpa.free(s.proc_buf);
    }

    pub fn cpuModel(s: *const Sampler) []const u8 {
        return if (s.cpu_model_len > 0) s.cpu_model_buf[0..s.cpu_model_len] else "Host CPU";
    }

    pub fn cpuCount(s: *const Sampler) u32 {
        return s.cores;
    }

    fn initCpuModel(s: *Sampler) void {
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const model = regString(fba.allocator(), "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString") orelse return;
        const trimmed = std.mem.trim(u8, model, " ");
        const len = @min(trimmed.len, s.cpu_model_buf.len);
        @memcpy(s.cpu_model_buf[0..len], trimmed[0..len]);
        s.cpu_model_len = len;
    }

    fn freeDrives(s: *Sampler) void {
        for (s.drives.items) |d| {
            s.gpa.free(d.name);
            s.gpa.free(d.fs);
            if (d.volume) |h| _ = CloseHandle(h);
        }
        s.drives.clearRetainingCapacity();
    }

    /// The fixed and removable drives (C:, D:...), with their I/O counters'
    /// handles; counters carry over to the same letter.
    fn loadDrives(s: *Sampler) void {
        var old = s.drives;
        s.drives = .empty;
        defer {
            for (old.items) |d| {
                s.gpa.free(d.name);
                s.gpa.free(d.fs);
                if (d.volume) |h| _ = CloseHandle(h);
            }
            old.deinit(s.gpa);
        }
        var buf: [512]u16 = undefined;
        const n = GetLogicalDriveStringsW(buf.len, &buf);
        if (n == 0 or n > buf.len) return;
        var it = std.mem.splitScalar(u16, buf[0..n], 0);
        while (it.next()) |root| {
            if (root.len != 3) continue;
            var d: Drive = .{ .root = .{ root[0], root[1], root[2], 0 }, .name = &.{}, .fs = &.{}, .volume = null };
            const root_z: [*:0]const u16 = @ptrCast(&d.root);
            const kind = GetDriveTypeW(root_z);
            if (kind != DRIVE_FIXED and kind != DRIVE_REMOVABLE) continue;
            var label: [261]u16 = undefined;
            var fs: [261]u16 = undefined;
            if (GetVolumeInformationW(root_z, &label, label.len, null, null, null, &fs, fs.len) == 0) continue; // no medium
            const letter = [2]u8{ @intCast(root[0]), ':' };
            const label_utf8 = utf8(s.gpa, std.mem.sliceTo(&label, 0)) orelse continue;
            defer s.gpa.free(label_utf8);
            d.name = (if (label_utf8.len > 0)
                std.fmt.allocPrint(s.gpa, "{s} ({s})", .{ label_utf8, &letter })
            else
                s.gpa.dupe(u8, &letter)) catch continue;
            d.fs = utf8(s.gpa, std.mem.sliceTo(&fs, 0)) orelse {
                s.gpa.free(d.name);
                continue;
            };
            const device = [_:0]u16{ '\\', '\\', '.', '\\', root[0], ':' };
            const h = CreateFileW(&device, 0, FILE_SHARE_READ_WRITE, null, OPEN_EXISTING, 0, null);
            d.volume = if (h == invalid_handle) null else h;
            for (old.items) |o| if (o.root[0] == d.root[0]) {
                d.read = o.read;
                d.written = o.written;
                d.has_prev = o.has_prev;
            };
            s.drives.append(s.gpa, d) catch {
                s.gpa.free(d.name);
                s.gpa.free(d.fs);
                if (d.volume) |v| _ = CloseHandle(v);
            };
        }
    }

    /// Every process record, into `proc_buf` (grown until it fits).
    fn readProcesses(s: *Sampler) ?[]align(8) u8 {
        if (s.proc_buf.len == 0) s.proc_buf = s.gpa.alignedAlloc(u8, .@"8", 512 * 1024) catch return null;
        for (0..4) |_| {
            var need: u32 = 0;
            const st = NtQuerySystemInformation(SystemProcessInformation, s.proc_buf.ptr, @intCast(s.proc_buf.len), &need);
            if (st == 0) return s.proc_buf[0..@max(need, 1)];
            if (st != STATUS_INFO_LENGTH_MISMATCH) return null;
            s.gpa.free(s.proc_buf);
            s.proc_buf = s.gpa.alignedAlloc(u8, .@"8", @as(usize, need) + 64 * 1024) catch {
                s.proc_buf = &.{};
                return null;
            };
        }
        return null;
    }

    pub fn sample(s: *Sampler, io: Io, arena: std.mem.Allocator) !tm.SystemSample {
        const t0 = Io.Clock.Timestamp.now(io, .awake);
        s.samples += 1;
        const dt_s: f64 = if (s.prev_time) |p| @as(f64, @floatFromInt(p.durationTo(t0).raw.toNanoseconds())) / 1e9 else 0;
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

        // CPU: per core, and their sum. Kernel time includes idle.
        var delta_total: u64 = 0;
        {
            const infos = try arena.alloc(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION, s.cores);
            var got: u32 = 0;
            const st = NtQuerySystemInformation(SystemProcessorPerformanceInformation, infos.ptr, @intCast(infos.len * @sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)), &got);
            const n = if (st == 0) got / @sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION) else 0;
            const cores = try arena.alloc(tm.CoreSample, n);
            var sum: CoreTimes = .{};
            for (infos[0..n], cores, 0..) |info, *c, i| {
                const idle: u64 = @intCast(@max(0, info.idle));
                const kernel: u64 = @intCast(@max(0, info.kernel));
                const user: u64 = @intCast(@max(0, info.user));
                const now: CoreTimes = .{ .busy = (kernel + user) -| idle, .total = kernel + user, .user = user, .system = kernel -| idle };
                if (i >= s.prev_cores.items.len) try s.prev_cores.append(s.gpa, .{});
                const p = &s.prev_cores.items[i];
                c.* = .{ .percent = if (p.total > 0) tm.pct(now.busy -| p.busy, now.total -| p.total) else 0, .freq_mhz = 0 };
                p.* = now;
                sum.busy += now.busy;
                sum.total += now.total;
                sum.user += now.user;
                sum.system += now.system;
            }
            if (s.prev.total > 0 and sum.total > s.prev.total) {
                delta_total = sum.total - s.prev.total;
                cpu.percent = tm.pct(sum.busy -| s.prev.busy, delta_total);
                cpu.user_percent = tm.pct(sum.user -| s.prev.user, delta_total);
                cpu.system_percent = tm.pct(sum.system -| s.prev.system, delta_total);
            }
            s.prev = sum;
            // Frequencies: the cores' current MHz.
            const power = try arena.alloc(PROCESSOR_POWER_INFORMATION, @max(n, 1));
            if (n > 0 and CallNtPowerInformation(ProcessorInformation, null, 0, power.ptr, @intCast(power.len * @sizeOf(PROCESSOR_POWER_INFORMATION))) == 0) {
                var mhz: f64 = 0;
                for (cores, power[0..n]) |*c, p| {
                    c.freq_mhz = @floatFromInt(p.current_mhz);
                    mhz += c.freq_mhz;
                }
                cpu.freq_mhz = @round(mhz / @as(f64, @floatFromInt(n)));
            }
            cpu.per_core = cores;
        }

        // Memory: physical, the file cache, and the page file beyond RAM.
        var mem = std.mem.zeroes(tm.MemInfo);
        var threads_total: u32 = 0;
        {
            var ms: MEMORYSTATUSEX = .{};
            if (GlobalMemoryStatusEx(&ms) != 0) {
                mem.total_bytes = ms.total_phys;
                mem.available_bytes = ms.avail_phys;
                mem.used_bytes = ms.total_phys -| ms.avail_phys;
                mem.swap_total_bytes = ms.total_page_file -| ms.total_phys;
                mem.swap_used_bytes = @min(mem.swap_total_bytes, (ms.total_page_file -| ms.avail_page_file) -| mem.used_bytes);
                mem.percent = tm.pct(mem.used_bytes, mem.total_bytes);
            }
            var pi: PERFORMANCE_INFORMATION = std.mem.zeroes(PERFORMANCE_INFORMATION);
            if (K32GetPerformanceInfo(&pi, @sizeOf(PERFORMANCE_INFORMATION)) != 0) {
                mem.cached_bytes = @as(u64, pi.system_cache) * pi.page_size;
                mem.free_bytes = mem.available_bytes -| mem.cached_bytes;
                threads_total = pi.thread_count;
            }
        }

        // Processes: one call for all of them.
        var procs: std.ArrayList(tm.ProcessRow) = .empty;
        try procs.ensureTotalCapacity(arena, 512);
        var creates: std.AutoHashMapUnmanaged(u32, i64) = .empty;
        s.curr_procs.clearRetainingCapacity();
        if (s.readProcesses()) |buf| {
            var off: usize = 0;
            while (off + @sizeOf(SYSTEM_PROCESS_INFORMATION) <= buf.len) {
                const p: *const SYSTEM_PROCESS_INFORMATION = @ptrCast(@alignCast(buf.ptr + off));
                defer off = if (p.next == 0) buf.len else off + p.next;
                const pid: u32 = @truncate(p.pid);
                if (pid == 0) continue; // the idle "process": the cores' idle time
                const ticks: u64 = @intCast(@max(0, p.user_time) + @max(0, p.kernel_time));
                s.curr_procs.put(pid, .{ .create = p.create_time, .ticks = ticks }) catch {};
                var p_cpu: f64 = 0;
                if (s.prev_procs.get(pid)) |prev| if (prev.create == p.create_time and ticks >= prev.ticks and delta_total > 0) {
                    p_cpu = tm.round1(tm.pct(ticks - prev.ticks, delta_total) * @as(f64, @floatFromInt(s.cores)));
                };
                const name = if (p.image_name.buf) |b| (utf8(arena, b[0 .. p.image_name.len / 2]) orelse "?") else if (pid == 4) "System" else "?";
                creates.put(arena, pid, p.create_time) catch {};
                procs.append(arena, .{
                    .pid = pid,
                    .name = name,
                    .command = "",
                    .user = "",
                    .state = "",
                    .threads = p.threads,
                    .cpu_percent = p_cpu,
                    .mem_rss_bytes = p.working_set,
                }) catch {};
            }
        }
        std.mem.swap(std.AutoHashMap(u32, ProcPrev), &s.prev_procs, &s.curr_procs);
        const total_procs: u32 = @intCast(procs.items.len);
        tm.busiestFirst(procs.items);
        const top = procs.items[0..@min(procs.items.len, tm.max_rows)];
        for (top) |*p| {
            const create = creates.get(p.pid) orelse 0;
            const gop = s.meta.getOrPut(p.pid) catch continue;
            var have = gop.found_existing;
            if (have and gop.value_ptr.create != create) {
                s.gpa.free(gop.value_ptr.user);
                s.gpa.free(gop.value_ptr.command);
                have = false;
            }
            if (!have) gop.value_ptr.* = s.readMeta(p.pid, create);
            gop.value_ptr.seen = s.samples;
            p.user = try arena.dupe(u8, gop.value_ptr.user);
            const cmd = gop.value_ptr.command;
            p.command = try arena.dupe(u8, cmd[0..@min(cmd.len, tm.max_command)]);
        }
        if (s.samples % 16 == 0) {
            var stale: std.ArrayList(u32) = .empty;
            var mit = s.meta.iterator();
            while (mit.next()) |e| if (e.value_ptr.seen + 16 < s.samples) stale.append(arena, e.key_ptr.*) catch {};
            for (stale.items) |pid| if (s.meta.fetchRemove(pid)) |kv| {
                s.gpa.free(kv.value.user);
                s.gpa.free(kv.value.command);
            };
        }

        // Disks: the drive list again now and then, sizes, and I/O rates.
        if (s.samples % 15 == 0) s.loadDrives();
        const disks = try arena.alloc(tm.DiskSample, s.drives.items.len);
        for (s.drives.items, disks) |*d, *out| {
            const root_z: [*:0]const u16 = @ptrCast(&d.root);
            var total: u64 = 0;
            var free: u64 = 0;
            _ = GetDiskFreeSpaceExW(root_z, null, &total, &free);
            out.* = .{
                .name = try arena.dupe(u8, d.name),
                .mount = try std.fmt.allocPrint(arena, "{c}:\\", .{@as(u8, @intCast(d.root[0]))}),
                .device = "",
                .fs = try arena.dupe(u8, d.fs),
                .total_bytes = total,
                .used_bytes = total -| free,
                .read_bps = 0,
                .write_bps = 0,
            };
            if (d.volume) |h| {
                var perf: DISK_PERFORMANCE = undefined;
                var got: u32 = 0;
                if (DeviceIoControl(h, IOCTL_DISK_PERFORMANCE, null, 0, &perf, @sizeOf(DISK_PERFORMANCE), &got, null) != 0) {
                    if (d.has_prev and dt_s > 0) {
                        out.read_bps = @as(f64, @floatFromInt(@max(0, perf.bytes_read - d.read))) / dt_s;
                        out.write_bps = @as(f64, @floatFromInt(@max(0, perf.bytes_written - d.written))) / dt_s;
                    }
                    d.read = perf.bytes_read;
                    d.written = perf.bytes_written;
                    d.has_prev = true;
                }
            }
        }

        // Network: the hardware interfaces (Ethernet, Wi-Fi), not the
        // loopback, filters and virtual adapters.
        var nets: std.ArrayList(tm.NetSample) = .empty;
        {
            var table: ?*MIB_IF_TABLE2 = null;
            if (GetIfTable2(&table) == 0) if (table) |tbl| {
                defer FreeMibTable(tbl);
                const rows: [*]const MIB_IF_ROW2 = &tbl.table;
                for (rows[0..tbl.count]) |*r| {
                    if (r.flags & 1 == 0 or r.if_type == IF_TYPE_SOFTWARE_LOOPBACK) continue;
                    var rx_bps: f64 = 0;
                    var tx_bps: f64 = 0;
                    var found = false;
                    for (s.nets.items) |*p| if (p.luid == r.luid) {
                        if (dt_s > 0) {
                            rx_bps = @as(f64, @floatFromInt(r.in_octets -| p.rx)) / dt_s;
                            tx_bps = @as(f64, @floatFromInt(r.out_octets -| p.tx)) / dt_s;
                        }
                        p.rx = r.in_octets;
                        p.tx = r.out_octets;
                        found = true;
                        break;
                    };
                    if (!found) s.nets.append(s.gpa, .{ .luid = r.luid, .rx = r.in_octets, .tx = r.out_octets }) catch {};
                    try nets.append(arena, .{
                        .name = utf8(arena, std.mem.sliceTo(&r.alias, 0)) orelse "?",
                        .up = r.oper_status == IF_OPER_STATUS_UP,
                        .rx_bps = rx_bps,
                        .tx_bps = tx_bps,
                        .rx_total = r.in_octets,
                        .tx_total = r.out_octets,
                    });
                }
            };
        }

        const t1 = Io.Clock.Timestamp.now(io, .awake);
        return .{
            .cpu = cpu,
            .mem = mem,
            .uptime_seconds = GetTickCount64() / 1000,
            .processes = top,
            .total_processes = total_procs,
            .threads_total = threads_total,
            .running = 0,
            .disks = disks,
            .net = nets.items,
            .sensors = &.{},
            .sample_time_ms = @as(f64, @floatFromInt(t0.durationTo(t1).raw.toNanoseconds())) / 1e6,
            .engine = "Win32 + NT native calls (0 spawns, no WMI)",
        };
    }

    /// A process's user and command line (empty for those this user can't
    /// open: the system's own, other users').
    fn readMeta(s: *Sampler, pid: u32, create: i64) ProcMeta {
        var m: ProcMeta = .{ .create = create, .user = &.{}, .command = &.{}, .seen = s.samples };
        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse {
            m.user = s.gpa.dupe(u8, if (pid == 4) "SYSTEM" else "") catch &.{};
            return m;
        };
        defer _ = CloseHandle(h);
        m.command = commandLineOf(s.gpa, h) orelse &.{};
        m.user = s.userOf(h) orelse (s.gpa.dupe(u8, "") catch &.{});
        return m;
    }

    /// The account a process runs as ("DOMAIN\\user" as just "user"),
    /// looked up once per SID.
    fn userOf(s: *Sampler, process: HANDLE) ?[]u8 {
        var token: HANDLE = null;
        if (OpenProcessToken(process, TOKEN_QUERY, &token) == 0) return null;
        defer _ = CloseHandle(token);
        var buf: [256]u8 align(8) = undefined;
        var got: u32 = 0;
        if (GetTokenInformation(token, TokenUser, &buf, buf.len, &got) == 0) return null;
        const sid: *anyopaque = @as(*const ?*anyopaque, @ptrCast(&buf)).* orelse return null;
        // SIDs are short: their bytes (sub-authority count at [1]) as the key.
        const sid_bytes: [*]const u8 = @ptrCast(sid);
        const sid_len: usize = 8 + @as(usize, sid_bytes[1]) * 4;
        if (s.users.get(sid_bytes[0..sid_len])) |u| return s.gpa.dupe(u8, u) catch null;
        var name: [256]u16 = undefined;
        var domain: [256]u16 = undefined;
        var name_len: u32 = name.len;
        var domain_len: u32 = domain.len;
        var use: u32 = 0;
        if (LookupAccountSidW(null, sid, &name, &name_len, &domain, &domain_len, &use) == 0) return null;
        const user = utf8(s.gpa, name[0..name_len]) orelse return null;
        const key = s.gpa.dupe(u8, sid_bytes[0..sid_len]) catch return user;
        const cached = s.gpa.dupe(u8, user) catch {
            s.gpa.free(key);
            return user;
        };
        s.users.put(key, cached) catch {
            s.gpa.free(key);
            s.gpa.free(cached);
        };
        return user;
    }

    /// A process's whole command line (empty when it can't be read).
    pub fn commandLine(_: *Sampler, _: Io, arena: std.mem.Allocator, pid: u32) []const u8 {
        const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return "";
        defer _ = CloseHandle(h);
        return commandLineOf(arena, h) orelse "";
    }
};

/// ProcessCommandLineInformation: a UNICODE_STRING followed by its text.
fn commandLineOf(a: std.mem.Allocator, process: HANDLE) ?[]u8 {
    var buf: [8192]u8 align(8) = undefined;
    var got: u32 = 0;
    if (NtQueryInformationProcess(process, ProcessCommandLineInformation, &buf, buf.len, &got) != 0) return null;
    const us: *const UNICODE_STRING = @ptrCast(&buf);
    const text = us.buf orelse return a.dupe(u8, "") catch null;
    return utf8(a, text[0 .. us.len / 2]);
}

fn utf8(a: std.mem.Allocator, wide: []const u16) ?[]u8 {
    return std.unicode.utf16LeToUtf8Alloc(a, wide) catch null;
}

fn wideZ(a: std.mem.Allocator, s: []const u8) ?[:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch null;
}

/// A REG_SZ under HKEY_LOCAL_MACHINE, as UTF-8.
fn regString(a: std.mem.Allocator, subkey: []const u8, value: []const u8) ?[]u8 {
    var tmp: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tmp);
    const k = wideZ(fba.allocator(), subkey) orelse return null;
    const v = wideZ(fba.allocator(), value) orelse return null;
    var data: [512]u16 = undefined;
    var size: u32 = @sizeOf(@TypeOf(data));
    if (RegGetValueW(HKEY_LOCAL_MACHINE, k.ptr, v.ptr, RRF_RT_REG_SZ, null, &data, &size) != 0) return null;
    const n = @min(size / 2, data.len);
    return utf8(a, std.mem.sliceTo(data[0..n], 0));
}

/// Ask a process to close: WM_CLOSE to its visible top-level windows, as
/// clicking their close buttons would (Windows has no SIGTERM; this never
/// calls TerminateProcess). False when it has no window to ask.
pub fn terminate(pid: u32) bool {
    const Ctx = struct {
        pid: u32,
        asked: bool = false,
        fn each(window: HWND, lparam: isize) callconv(.winapi) BOOL {
            const ctx: *@This() = @ptrFromInt(@as(usize, @bitCast(lparam)));
            var owner: u32 = 0;
            _ = GetWindowThreadProcessId(window, &owner);
            if (owner == ctx.pid and IsWindowVisible(window) != 0 and GetWindow(window, GW_OWNER) == null) {
                if (PostMessageW(window, WM_CLOSE, 0, 0) != 0) ctx.asked = true;
            }
            return 1;
        }
    };
    var ctx: Ctx = .{ .pid = pid };
    _ = EnumWindows(Ctx.each, @bitCast(@intFromPtr(&ctx)));
    return ctx.asked;
}

/// The machine's static description, read once.
pub fn systemInfo(_: Io, arena: std.mem.Allocator, cpu_model: []const u8, threads: u32) tm.SystemInfo {
    var host: [256]u16 = undefined;
    var host_len: u32 = host.len;
    const hostname = if (GetComputerNameExW(ComputerNameDnsHostname, &host, &host_len) != 0) utf8(arena, host[0..host_len]) orelse "" else "";
    var ver: OSVERSIONINFOW = .{};
    _ = RtlGetVersion(&ver);
    const nt = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion";
    var product = regString(arena, nt, "ProductName") orelse "Windows";
    // Windows 11 still says "Windows 10" there: its builds start at 22000.
    if (ver.build >= 22000) if (std.mem.indexOf(u8, product, "Windows 10")) |i| {
        product = std.mem.concat(arena, u8, &.{ product[0..i], "Windows 11", product[i + "Windows 10".len ..] }) catch product;
    };
    const display = regString(arena, nt, "DisplayVersion") orelse "";
    const bios_key = "HARDWARE\\DESCRIPTION\\System\\BIOS";
    const join = struct {
        fn f(a: std.mem.Allocator, x: ?[]u8, y: ?[]u8) []const u8 {
            return std.mem.trim(u8, std.fmt.allocPrint(a, "{s} {s}", .{ x orelse "", y orelse "" }) catch "", " ");
        }
    }.f;
    return .{
        .hostname = hostname,
        .os = std.mem.trim(u8, std.fmt.allocPrint(arena, "{s} {s}", .{ product, display }) catch product, " "),
        .kernel = std.fmt.allocPrint(arena, "NT {d}.{d}.{d}", .{ ver.major, ver.minor, ver.build }) catch "",
        .arch = @tagName(builtin.cpu.arch),
        .board = join(arena, regString(arena, bios_key, "BaseBoardManufacturer"), regString(arena, bios_key, "BaseBoardProduct")),
        .bios = join(arena, regString(arena, bios_key, "BIOSVersion"), regString(arena, bios_key, "BIOSReleaseDate")),
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
