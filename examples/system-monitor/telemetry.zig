//! What the page is sent: the same shape on every OS, each sampler
//! (sampler_linux.zig, sampler_windows.zig, sampler_macos.zig) filling what
//! its OS can tell (null, 0 or an empty list for the rest).

const std = @import("std");

pub const CoreSample = struct {
    percent: f64,
    freq_mhz: f64,
};

pub const CpuInfo = struct {
    percent: f64,
    user_percent: f64,
    system_percent: f64,
    /// Time waiting on I/O (null where the OS doesn't count it: Windows, macOS).
    iowait_percent: ?f64,
    cores: u32,
    model: []const u8,
    /// The cores' average current frequency (0 when unknown: Apple Silicon).
    freq_mhz: f64,
    /// The package temperature (k10temp Tctl, coretemp Package...), if any.
    temp_c: ?f64,
    /// The 1, 5 and 15 minute load averages (null on Windows, which has none).
    load_avg: ?[3]f64,
    per_core: []CoreSample,
};

pub const MemInfo = struct {
    total_bytes: u64,
    used_bytes: u64,
    available_bytes: u64,
    free_bytes: u64,
    cached_bytes: u64,
    buffers_bytes: u64,
    swap_total_bytes: u64,
    swap_used_bytes: u64,
    percent: f64,
};

pub const ProcessRow = struct {
    pid: u32,
    name: []const u8,
    /// The full command line (arguments space-separated); empty for kernel threads.
    command: []const u8,
    user: []const u8,
    state: []const u8,
    threads: u32,
    cpu_percent: f64,
    mem_rss_bytes: u64,
};

pub const DiskSample = struct {
    /// "root" for /, else the mount point's last part ("efi", "projects").
    name: []const u8,
    mount: []const u8,
    device: []const u8,
    fs: []const u8,
    total_bytes: u64,
    used_bytes: u64,
    read_bps: f64,
    write_bps: f64,
};

pub const NetSample = struct {
    name: []const u8,
    up: bool,
    rx_bps: f64,
    tx_bps: f64,
    rx_total: u64,
    tx_total: u64,
};

pub const SensorSample = struct {
    name: []const u8,
    temp_c: f64,
};

pub const SystemSample = struct {
    cpu: CpuInfo,
    mem: MemInfo,
    uptime_seconds: u64,
    processes: []ProcessRow,
    total_processes: u32,
    threads_total: u32,
    running: u32,
    disks: []DiskSample,
    net: []NetSample,
    sensors: []SensorSample,
    sample_time_ms: f64,
    engine: []const u8,
};

/// What doesn't change while the app runs (system_info).
pub const SystemInfo = struct {
    hostname: []const u8,
    os: []const u8,
    kernel: []const u8,
    arch: []const u8,
    board: []const u8,
    bios: []const u8,
    cpu_model: []const u8,
    threads: u32,
};

/// How many processes a sample sends, the busiest first.
pub const max_rows = 256;
/// The command line a sample sends, at most.
pub const max_command = 200;


/// One-decimal rounding for the page: short in JSON (0.43, not 0.4300000071).
pub fn round1(v: f64) f64 {
    return @round(v * 10) / 10;
}

/// part / whole as a percentage, to one decimal.
pub fn pct(part: u64, whole: u64) f64 {
    if (whole == 0) return 0;
    return round1(@as(f64, @floatFromInt(part)) / @as(f64, @floatFromInt(whole)) * 100.0);
}

/// The busiest processes first: CPU, then memory.
pub fn busiestFirst(rows: []ProcessRow) void {
    std.mem.sort(ProcessRow, rows, {}, struct {
        fn lessThan(_: void, x: ProcessRow, y: ProcessRow) bool {
            if (x.cpu_percent != y.cpu_percent) return x.cpu_percent > y.cpu_percent;
            return x.mem_rss_bytes > y.mem_rss_bytes;
        }
    }.lessThan);
}
