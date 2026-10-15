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
    parent_pid: u32 = 0,
    start_time: u64 = 0,
    /// Installed desktop identity when known; otherwise grouped by executable.
    app_key: []const u8 = "",
    app_name: []const u8 = "",
    executable: []const u8 = "",
    application_id: u64 = 0,
    name: []const u8,
    /// The full command line (arguments space-separated); empty for kernel threads.
    command: []const u8,
    user: []const u8,
    state: []const u8,
    threads: u32,
    cpu_percent: f64,
    mem_rss_bytes: u64,

    pub fn jsonStringify(row: @This(), writer: anytype) !void {
        try stringifyWithId(row, writer, "application_id");
    }
};

pub const ApplicationRow = struct {
    id: u64,
    name: []const u8,
    user: []const u8,
    process_count: u32 = 0,
    threads: u32 = 0,
    cpu_percent: f64 = 0,
    /// Sum of RSS, not unique/private memory: shared pages may be counted twice.
    mem_rss_bytes: u64 = 0,
    is_application: bool = false,

    pub fn jsonStringify(row: @This(), writer: anytype) !void {
        try stringifyWithId(row, writer, "id");
    }
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
    applications: []ApplicationRow = &.{},
    applications_supported: bool = false,
    total_applications: u32 = 0,
    /// The group whose members were prioritized before the process-row limit.
    application_id: u64 = 0,
    application_process_count: u32 = 0,
    total_processes: u32,
    threads_total: u32,
    running: u32,
    disks: []DiskSample,
    net: []NetSample,
    sensors: []SensorSample,
    sample_time_ms: f64,
    engine: []const u8,

    pub fn jsonStringify(sample: @This(), writer: anytype) !void {
        try stringifyWithId(sample, writer, "application_id");
    }
};

/// IDs travel as decimal strings so JavaScript/WebView renderers cannot round
/// the u64 hash. Zig's JSON parser accepts these strings as integer fields.
fn stringifyWithId(value: anytype, writer: anytype, comptime id_field: []const u8) !void {
    try writer.beginObject();
    inline for (std.meta.fields(@TypeOf(value))) |field| {
        try writer.objectField(field.name);
        if (comptime std.mem.eql(u8, field.name, id_field) or std.mem.eql(u8, field.name, "start_time")) {
            var buf: [20]u8 = undefined;
            try writer.write(std.fmt.bufPrint(&buf, "{d}", .{@field(value, field.name)}) catch unreachable);
        } else try writer.write(@field(value, field.name));
    }
    try writer.endObject();
}

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

/// Whether a row matches the page's filter (case-insensitive): its name,
/// user or command line contains it, or its pid starts with it. Before a
/// sample's cut only the name and pid (and the user on macOS) are known:
/// those are what keep an idle process in the rows the page gets.
pub fn matches(row: ProcessRow, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(row.name, filter) != null) return true;
    if (std.ascii.indexOfIgnoreCase(row.user, filter) != null) return true;
    if (std.ascii.indexOfIgnoreCase(row.command, filter) != null) return true;
    var buf: [10]u8 = undefined;
    const pid = std.fmt.bufPrint(&buf, "{d}", .{row.pid}) catch return false;
    return std.mem.startsWith(u8, pid, filter);
}

/// The rows a sample sends first: those matching `filter` (busiest
/// first), then the rest, busiest first. With a filter, a match ranks
/// ahead of any busier process, so it survives the `max_rows` cut.
pub fn orderRows(rows: []ProcessRow, filter: []const u8) void {
    std.mem.sort(ProcessRow, rows, filter, struct {
        fn lessThan(f: []const u8, x: ProcessRow, y: ProcessRow) bool {
            const mx = matches(x, f);
            if (mx != matches(y, f)) return mx;
            if (x.cpu_percent != y.cpu_percent) return x.cpu_percent > y.cpu_percent;
            return x.mem_rss_bytes > y.mem_rss_bytes;
        }
    }.lessThan);
}

/// At most this much of the page's filter is used.
pub const max_filter = 64;

test orderRows {
    var rows = [_]ProcessRow{
        .{ .pid = 1, .name = "busy", .command = "", .user = "", .state = "", .threads = 1, .cpu_percent = 90, .mem_rss_bytes = 0 },
        .{ .pid = 42, .name = "sleep", .command = "", .user = "", .state = "", .threads = 1, .cpu_percent = 0, .mem_rss_bytes = 0 },
        .{ .pid = 7, .name = "other", .command = "", .user = "", .state = "", .threads = 1, .cpu_percent = 50, .mem_rss_bytes = 0 },
    };
    orderRows(&rows, "SLE");
    try std.testing.expectEqualStrings("sleep", rows[0].name);
    try std.testing.expectEqualStrings("busy", rows[1].name);
    orderRows(&rows, "");
    try std.testing.expectEqualStrings("busy", rows[0].name);
    try std.testing.expect(matches(rows[2], "4")); // pid 42
    try std.testing.expect(!matches(rows[2], "2"));
}

test "application IDs round trip exactly through JSON strings for all renderers" {
    const app = ApplicationRow{ .id = std.math.maxInt(u64) - 1, .name = "Editor", .user = "test" };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, app, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"18446744073709551614\"") != null);
    const parsed = try std.json.parseFromSlice(ApplicationRow, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(app.id, parsed.value.id);
    const request = try std.json.parseFromSlice(struct { application_id: u64 }, std.testing.allocator, "{\"application_id\":\"18446744073709551614\"}", .{});
    defer request.deinit();
    try std.testing.expectEqual(app.id, request.value.application_id);
}
