//! Application logging infrastructure.
//!
//! Routes `std.log` messages to both `stderr` and a persistent log file in
//! `$XDG_DATA_HOME/<app_id>/app.log`. Thread-safe.
//!
//! To use in an app's `main.zig`:
//!     pub const std_options: std.Options = .{
//!         .logFn = oriel.log.logFn,
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
    const base = std.mem.span(glib.getUserDataDir());
    var path_buf: [1024]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ base, app_id }) catch return;
    initInDir(dir);
}

/// Open `<dir>/app.log` (creating `dir`) as the log file.
fn initInDir(dir: [:0]const u8) void {
    ensureMutex();
    log_mutex.lock();
    defer log_mutex.unlock();

    if (log_fd >= 0) return; // already initialized

    _ = glib.mkdirWithParents(dir.ptr, 0o755);

    var file_buf: [1024]u8 = undefined;
    const file_path = std.fmt.bufPrintZ(&file_buf, "{s}/app.log", .{dir}) catch return;

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
    writeEntry(level, scope, format, args, true);
}

/// Format one entry and write it to the log file and, if `to_stderr`, to
/// stderr. Tests pass `false`: `zig build test` reports any stderr output
/// of a passing test run as a "failed command".
fn writeEntry(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    to_stderr: bool,
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

    if (to_stderr) _ = std.c.write(2, formatted.ptr, formatted.len);

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

// From glib (no usable GIR binding): returns a newly allocated path.
extern fn g_dir_make_tmp(tmpl: ?[*:0]const u8, err: ?*?*glib.Error) ?[*:0]u8;

test "log initialization and formatting" {
    // A private temp dir, so the test never writes into the user's real
    // $XDG_DATA_HOME.
    const dir_c = g_dir_make_tmp("oriel-log-XXXXXX", null) orelse return error.TmpDir;
    defer glib.free(dir_c);
    const dir = std.mem.span(dir_c);
    defer _ = std.c.rmdir(dir_c);

    initInDir(dir);
    defer deinit();

    writeEntry(.info, .test_scope, "hello logging {d}", .{42}, false);

    const path = getPath() orelse return error.NoLogPath;
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    defer _ = std.c.unlink(path_z);

    var file_bytes: [*]u8 = undefined;
    var file_len: usize = 0;
    try std.testing.expect(glib.fileGetContents(path_z, &file_bytes, &file_len, null) != 0);
    defer glib.free(file_bytes);
    const content = file_bytes[0..file_len];
    try std.testing.expect(std.mem.indexOf(u8, content, "[info] (test_scope): hello logging 42") != null);
}
