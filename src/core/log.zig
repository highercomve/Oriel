//! Application logging infrastructure.
//!
//! Routes `std.log` messages to both `stderr` and a persistent log file:
//! `$XDG_DATA_HOME/<app_id>/app.log` (Linux), `%LOCALAPPDATA%\<app_id>\app.log`
//! (Windows), `~/Library/Logs/<app_id>/app.log` (macOS, where Console.app
//! finds it too). Appended to, never rotated. Thread-safe.
//!
//! To use in an app's `main.zig`:
//!     pub const std_options: std.Options = .{
//!         .logFn = oriel.log.logFn,
//!     };

const builtin = @import("builtin");
const std = @import("std");

const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;
/// Linux and macOS write the file through a POSIX descriptor.
const is_posix = is_linux or is_macos;

const glib = if (is_linux) @import("glib") else struct {};
const win32 = if (is_windows) @import("../platform/windows/win32.zig") else struct {};

var log_mutex: if (is_linux) glib.Mutex else void = if (is_linux) undefined else {};
var log_mutex_initialized = false;
var log_srw: if (is_windows) win32.SRWLOCK else void = if (is_windows) .{} else {};
var log_pthread: if (is_macos) std.c.pthread_mutex_t else void = if (is_macos) .{} else {};
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
    } else if (is_macos) {
        _ = std.c.pthread_mutex_lock(&log_pthread);
    }
}

fn unlock() void {
    if (is_linux) {
        log_mutex.unlock();
    } else if (is_windows) {
        win32.ReleaseSRWLockExclusive(&log_srw);
    } else if (is_macos) {
        _ = std.c.pthread_mutex_unlock(&log_pthread);
    }
}

/// Initialize logging for `app_id`.
///
/// Creates the log file (see the file comment) and directs future log
/// entries to it in addition to stderr.
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
    } else if (is_macos) {
        const home = std.c.getenv("HOME") orelse return;
        var path_buf: [1024]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&path_buf, "{s}/Library/Logs/{s}", .{ std.mem.span(home), app_id }) catch return;
        initInDir(dir);
    }
}

/// `mkdir -p` (existing directories are fine; errors surface when the file
/// is opened).
fn makeDirs(dir: [:0]const u8) void {
    var buf: [1024]u8 = undefined;
    if (dir.len >= buf.len) return;
    @memcpy(buf[0..dir.len], dir);
    var i: usize = 1;
    while (i <= dir.len) : (i += 1) {
        if (i == dir.len or buf[i] == '/') {
            const saved = buf[i];
            buf[i] = 0;
            _ = std.c.mkdir(@ptrCast(&buf), 0o755);
            buf[i] = saved;
        }
    }
}

/// Open `<dir>/app.log` (creating `dir`) as the log file.
fn initInDir(dir: [:0]const u8) void {
    lock();
    defer unlock();

    if (is_posix) {
        if (log_fd >= 0) return; // already initialized

        if (is_linux) _ = glib.mkdirWithParents(dir.ptr, 0o755) else makeDirs(dir);

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
    if (is_posix) {
        if (is_linux and !log_mutex_initialized) return;
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
        if (is_posix) {
            _ = std.c.write(2, formatted.ptr, formatted.len);
        } else if (is_windows) {
            const h = win32.GetStdHandle(win32.STD_ERROR_HANDLE);
            if (h != null and h != win32.INVALID_HANDLE_VALUE) {
                // lpNumberOfBytesWritten may only be NULL with an OVERLAPPED.
                // A failed log write has nowhere to be reported, so it is dropped.
                var written: win32.DWORD = 0;
                _ = win32.WriteFile(h.?, formatted.ptr, @intCast(formatted.len), &written, null);
            }
        }
    }

    if (is_posix) {
        if (log_fd >= 0) {
            _ = std.c.write(log_fd, formatted.ptr, formatted.len);
        }
    } else if (is_windows) {
        if (log_handle) |h| {
            var written: win32.DWORD = 0;
            _ = win32.WriteFile(h, formatted.ptr, @intCast(formatted.len), &written, null);
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
    } else if (is_macos) {
        var now: std.c.time_t = undefined;
        _ = time(&now);
        var tm: [16]i64 = undefined; // struct tm (56 bytes on Darwin), aligned
        if (localtime_r(&now, &tm) == null) return "0000-00-00 00:00:00";
        const n = strftime(buf.ptr, buf.len, "%Y-%m-%d %H:%M:%S", &tm);
        if (n > 0) return buf[0..n];
    }
    return "0000-00-00 00:00:00";
}

extern "c" fn time(t: ?*std.c.time_t) std.c.time_t;
extern "c" fn localtime_r(t: *const std.c.time_t, tm: *anyopaque) ?*anyopaque;
extern "c" fn strftime(s: [*]u8, max: usize, format: [*:0]const u8, tm: *const anyopaque) usize;
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

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

test "macOS log file" {
    if (!is_macos) return;
    // A private temp dir (never ~/Library/Logs), nested to exercise makeDirs.
    var tmpl = "/tmp/oriel-log-XXXXXX".*;
    const base = mkdtemp(&tmpl) orelse return error.TmpDir;
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/a/b", .{std.mem.span(base)});

    initInDir(dir);
    writeEntry(.warn, .test_scope, "mac logging {s}", .{"ok"}, false);
    const path = getPath() orelse return error.NoLogPath;
    var path_buf: [256]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    deinit();
    try std.testing.expect(getPath() == null);

    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    try std.testing.expect(fd >= 0);
    var content: [512]u8 = undefined;
    const n = std.c.read(fd, &content, content.len);
    _ = std.c.close(fd);
    try std.testing.expect(n > 0);
    const text = content[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, text, "[warning] (test_scope): mac logging ok") != null);
    // "YYYY-MM-DD HH:MM:SS " from strftime, not the fallback.
    try std.testing.expect(!std.mem.startsWith(u8, text, "0000-"));
    try std.testing.expectEqual(@as(u8, '-'), text[4]);

    _ = std.c.unlink(path_z.ptr);
    const b = try std.fmt.bufPrintZ(&dir_buf, "{s}/a/b", .{std.mem.span(base)});
    _ = std.c.rmdir(b.ptr);
    const a = try std.fmt.bufPrintZ(&dir_buf, "{s}/a", .{std.mem.span(base)});
    _ = std.c.rmdir(a.ptr);
    _ = std.c.rmdir(base);
}
