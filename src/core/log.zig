//! Application logging infrastructure.
//!
//! Routes `std.log` messages to both `stderr` and a persistent log file in
//! `$XDG_DATA_HOME/<app_id>/app.log`. Thread-safe.
//!
//! To use in an app's `main.zig`:
//!     pub const std_options: std.Options = .{
//!         .logFn = ziguri.log.logFn,
//!     };

const std = @import("std");
const glib = @import("glib");

var log_mutex: glib.Mutex = undefined;
var log_mutex_initialized = false;
var log_fd: c_int = -1;
var log_path_buf: [1024]u8 = undefined;
var log_path_len: usize = 0;

fn ensureMutex() void {
    if (!log_mutex_initialized) {
        log_mutex.init();
        log_mutex_initialized = true;
    }
}

/// Initialize logging for `app_id`.
///
/// Creates `$XDG_DATA_HOME/<app_id>/app.log` and directs future log entries
/// to it in addition to stderr.
pub fn init(app_id: []const u8) void {
    ensureMutex();
    log_mutex.lock();
    defer log_mutex.unlock();

    if (log_fd >= 0) return; // already initialized

    const base = std.mem.span(glib.getUserDataDir());
    var path_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ base, app_id }) catch return;
    _ = glib.mkdirWithParents(dir.ptr, 0o755);

    var file_buf: [1024]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/{s}/app.log", .{ base, app_id }) catch return;

    const fd = std.c.open(file_path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, @as(c_uint, 0o644));

    if (fd >= 0) {
        log_fd = fd;
        const len = file_path.len;
        if (len < log_path_buf.len) {
            @memcpy(log_path_buf[0..len], file_path);
            log_path_len = len;
        }
    }
}

/// Close the log file.
pub fn deinit() void {
    if (!log_mutex_initialized) return;
    log_mutex.lock();
    defer log_mutex.unlock();

    if (log_fd >= 0) {
        _ = std.c.close(log_fd);
        log_fd = -1;
        log_path_len = 0;
    }
}

/// Return the active log file path, or null if not initialized.
pub fn getPath() ?[]const u8 {
    if (log_path_len == 0) return null;
    return log_path_buf[0..log_path_len];
}

/// Custom log function compatible with `std.Options.logFn`.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    ensureMutex();
    log_mutex.lock();
    defer log_mutex.unlock();

    // Format: "YYYY-MM-DD HH:MM:SS [LEVEL] (scope): message\n"
    var time_buf: [64]u8 = undefined;
    const now_str = getTimestamp(&time_buf);

    const level_str = comptime level.asText();
    const scope_str = comptime @tagName(scope);

    var msg_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&msg_buf);
    const alloc = fba.allocator();

    const formatted = std.fmt.allocPrint(alloc, "{s} [{s}] ({s}): " ++ format ++ "\n", .{ now_str, level_str, scope_str } ++ args) catch blk: {
        // Truncate gracefully if buffer fills
        break :blk std.fmt.allocPrint(alloc, "{s} [{s}] ({s}): [log truncated]\n", .{ now_str, level_str, scope_str }) catch return;
    };

    // Write to stderr
    _ = std.c.write(2, formatted.ptr, formatted.len);

    // Write to log file if open
    if (log_fd >= 0) {
        _ = std.c.write(log_fd, formatted.ptr, formatted.len);
    }
}

fn getTimestamp(buf: []u8) []const u8 {
    if (glib.DateTime.newNowLocal()) |dt| {
        defer dt.unref();
        if (dt.format("%Y-%m-%d %H:%M:%S")) |str| {
            defer glib.free(str);
            const slice = std.mem.span(str);
            const copy_len = @min(buf.len, slice.len);
            @memcpy(buf[0..copy_len], slice[0..copy_len]);
            return buf[0..copy_len];
        }
    }
    return "0000-00-00 00:00:00";
}

test "log initialization and formatting" {
    init("ziguri_test_app");
    defer deinit();

    logFn(.info, .test_scope, "hello logging {d}", .{42});

    const path = getPath();
    try std.testing.expect(path != null);

    // Verify file exists and has content
    var file_bytes: [*]u8 = undefined;
    var file_len: usize = 0;
    const path_z = try std.testing.allocator.dupeZ(u8, path.?);
    defer std.testing.allocator.free(path_z);

    if (glib.fileGetContents(path_z, &file_bytes, &file_len, null) != 0) {
        defer glib.free(file_bytes);
        const content = file_bytes[0..file_len];
        try std.testing.expect(std.mem.indexOf(u8, content, "hello logging 42") != null);
    }
    _ = glib.unlink(path_z);
}
