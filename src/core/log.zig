//! Application logging infrastructure.
//!
//! Routes `std.log` messages to both `stderr` and a persistent log file in
//! `$XDG_DATA_HOME/<app_id>/app.log`. Thread-safe.
//!
//! To use in an app's `main.zig`:
//!     pub const std_options: std.Options = .{
//!         .logFn = oriel.log.logFn,
//!     };

const builtin = @import("builtin");
const std = @import("std");

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

const glib = if (is_linux) @import("glib") else struct {};
const win32 = if (is_windows) @import("../platform/windows/win32.zig") else struct {};

var log_mutex: if (is_linux) glib.Mutex else void = if (is_linux) undefined else {};
var log_mutex_initialized = false;
var log_srw: if (is_windows) win32.SRWLOCK else void = if (is_windows) .{} else {};
var log_fd: c_int = -1;
var log_handle: ?win32.HANDLE = null;
var log_path_buf: [1024]u8 = undefined;
var log_path_len: usize = 0;

fn ensureMutex() void {
    if (is_linux) {
        if (!log_mutex_initialized) {
            log_mutex.init();
            log_mutex_initialized = true;
        }
    }
}

fn lock() void {
    if (is_linux) {
        ensureMutex();
        log_mutex.lock();
    } else if (is_windows) {
        win32.AcquireSRWLockExclusive(&log_srw);
    }
}

fn unlock() void {
    if (is_linux) {
        log_mutex.unlock();
    } else if (is_windows) {
        win32.ReleaseSRWLockExclusive(&log_srw);
    }
}

/// Initialize logging for `app_id`.
///
/// Creates `$XDG_DATA_HOME/<app_id>/app.log` and directs future log entries
/// to it in addition to stderr.
pub fn init(app_id: []const u8) void {
    if (is_linux) {
        const base = std.mem.span(glib.getUserDataDir());
        var path_buf: [1024]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ base, app_id }) catch return;
        initInDir(dir);
    } else if (is_windows) {
        var wbuf: [win32.MAX_PATH]u16 = undefined;
        const name_w = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
        var len = win32.GetEnvironmentVariableW(name_w, &wbuf, wbuf.len);
        if (len == 0 or len >= wbuf.len) {
            const appdata_w = std.unicode.utf8ToUtf16LeStringLiteral("APPDATA");
            len = win32.GetEnvironmentVariableW(appdata_w, &wbuf, wbuf.len);
        }
        if (len > 0 and len < wbuf.len) {
            var utf8_buf: [1024]u8 = undefined;
            const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wbuf[0..len]) catch return;
            const env = utf8_buf[0..utf8_len];
            var path_buf: [1024]u8 = undefined;
            const dir = std.fmt.bufPrintZ(&path_buf, "{s}\\{s}", .{ env, app_id }) catch return;
            initInDir(dir);
        }
    }
}

/// Open `<dir>/app.log` (creating `dir`) as the log file.
fn initInDir(dir: [:0]const u8) void {
    lock();
    defer unlock();

    if (is_linux) {
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
    } else if (is_windows) {
        if (log_handle != null) return;

        var file_buf: [1024]u8 = undefined;
        const file_path = std.fmt.bufPrintZ(&file_buf, "{s}\\app.log", .{dir}) catch return;

        const gpa = std.heap.smp_allocator;
        const dir_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, dir) catch return;
        defer gpa.free(dir_w);
        _ = win32.CreateDirectoryW(dir_w.ptr, null);

        const file_path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, file_path) catch return;
        defer gpa.free(file_path_w);

        const h = win32.CreateFileW(
            file_path_w.ptr,
            win32.GENERIC_WRITE,
            win32.FILE_SHARE_READ,
            null,
            win32.OPEN_ALWAYS,
            win32.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h != win32.INVALID_HANDLE_VALUE) {
            _ = win32.SetFilePointer(h, 0, null, win32.FILE_END);
            log_handle = h;
            const len = file_path.len;
            if (len < log_path_buf.len) {
                @memcpy(log_path_buf[0..len], file_path);
                log_path_len = len;
            }
        }
    }
}

/// Close the log file.
pub fn deinit() void {
    if (is_linux) {
        if (!log_mutex_initialized) return;
        lock();
        defer unlock();

        if (log_fd >= 0) {
            _ = std.c.close(log_fd);
            log_fd = -1;
            log_path_len = 0;
        }
    } else if (is_windows) {
        lock();
        defer unlock();

        if (log_handle) |h| {
            _ = win32.CloseHandle(h);
            log_handle = null;
            log_path_len = 0;
        }
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
    lock();
    defer unlock();

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

    if (to_stderr) {
        if (is_linux) {
            _ = std.c.write(2, formatted.ptr, formatted.len);
        } else if (is_windows) {
            const h = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
            if (h != null and h != win32.INVALID_HANDLE_VALUE) {
                _ = win32.WriteFile(h.?, formatted.ptr, @intCast(formatted.len), null, null);
            }
        }
    }

    if (is_linux) {
        if (log_fd >= 0) {
            _ = std.c.write(log_fd, formatted.ptr, formatted.len);
        }
    } else if (is_windows) {
        if (log_handle) |h| {
            _ = win32.WriteFile(h, formatted.ptr, @intCast(formatted.len), null, null);
        }
    }
}

fn getTimestamp(buf: []u8) []const u8 {
    if (is_linux) {
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
    } else if (is_windows) {
        var st: win32.SYSTEMTIME = undefined;
        win32.GetLocalTime(&st);
        return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
        }) catch "0000-00-00 00:00:00";
    }
    return "0000-00-00 00:00:00";
}

// From glib (no usable GIR binding): returns a newly allocated path.
extern fn g_dir_make_tmp(tmpl: ?[*:0]const u8, err: ?*?*glib.Error) ?[*:0]u8;

test "log initialization and formatting" {
    if (!is_linux) return;
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
