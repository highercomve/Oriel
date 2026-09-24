//! Windows file system watch implementation using Win32 ReadDirectoryChangesW.
//!
//! Why Overlapped I/O:
//! The `poll` API requires non-blocking semantics ("Read pending events without blocking",
//! matching Linux inotify with IN.NONBLOCK). Synchronous ReadDirectoryChangesW would block
//! the thread until a change happens, causing any poll loop to hang. Overlapped I/O allows
//! checking event completion with `GetOverlappedResult(..., FALSE)` without blocking,
//! polling events when ready, and re-arming the watch only after the completed buffer has
//! been completely consumed.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

pub const buffer_align = common.buffer_align;
pub const Event = common.Event;

const WatchedDir = struct {
    handle: win32.HANDLE,
    overlapped: win32.OVERLAPPED,
    raw_buf: []align(4) u8,
    active: bool,
    pending_read: bool,
    bytes_transferred: usize,
    cursor: common.Cursor,
};

const State = struct {
    dirs: std.ArrayList(*WatchedDir),

    fn deinit(self: *State) void {
        for (self.dirs.items) |dir| {
            if (dir.pending_read) {
                // Cancel pending I/O on this directory with CancelIoEx
                if (win32.CancelIoEx(dir.handle, &dir.overlapped) == win32.FALSE) {
                    // ERROR_NOT_FOUND (1168) means I/O already finished; other errors ignored on teardown
                }
                var bytes: win32.DWORD = 0;
                // bWait=TRUE waits until cancelled/in-flight I/O finishes; result ignored on teardown
                _ = win32.GetOverlappedResult(dir.handle, &dir.overlapped, &bytes, win32.TRUE);
                dir.pending_read = false;
            }
            // CloseHandle return value ignored on teardown; handle cannot be reused anyway
            _ = win32.CloseHandle(dir.handle);
            if (dir.overlapped.hEvent) |ev| {
                // CloseHandle return value ignored on teardown; event cannot be reused anyway
                _ = win32.CloseHandle(ev);
            }
            std.heap.smp_allocator.free(dir.raw_buf);
            std.heap.smp_allocator.destroy(dir);
        }
        self.dirs.deinit(std.heap.smp_allocator);
    }
};

pub const Watcher = struct {
    state: *State,

    pub fn init() !Watcher {
        const state = try std.heap.smp_allocator.create(State);
        errdefer std.heap.smp_allocator.destroy(state);

        state.* = .{
            .dirs = .empty,
        };
        return .{ .state = state };
    }

    pub fn deinit(self: Watcher) void {
        self.state.deinit();
        std.heap.smp_allocator.destroy(self.state);
    }

    pub fn add(self: Watcher, path: [:0]const u8) !void {
        const path_w = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, path);
        defer std.heap.smp_allocator.free(path_w);

        const hDir = win32.CreateFileW(
            path_w.ptr,
            win32.FILE_LIST_DIRECTORY,
            win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
            null,
        ) orelse return error.CreateFileFailed;
        if (hDir == win32.INVALID_HANDLE_VALUE) return error.CreateFileFailed;
        // CloseHandle return value ignored on error cleanup; nothing can be recovered
        errdefer _ = win32.CloseHandle(hDir);

        const hEvent = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return error.CreateEventFailed;
        // CloseHandle return value ignored on error cleanup; nothing can be recovered
        errdefer _ = win32.CloseHandle(hEvent);

        const raw_buf = try std.heap.smp_allocator.alignedAlloc(u8, .fromByteUnits(4), 4096);
        errdefer std.heap.smp_allocator.free(raw_buf);

        const dir = try std.heap.smp_allocator.create(WatchedDir);
        errdefer std.heap.smp_allocator.destroy(dir);

        dir.* = .{
            .handle = hDir,
            .overlapped = std.mem.zeroes(win32.OVERLAPPED),
            .raw_buf = raw_buf,
            .active = true,
            .pending_read = false,
            .bytes_transferred = 0,
            .cursor = common.Cursor.init(),
        };
        dir.overlapped.hEvent = hEvent;

        // Place dir into state.dirs so it is at its final address on the heap
        try self.state.dirs.append(std.heap.smp_allocator, dir);
        errdefer _ = self.state.dirs.pop();

        const filter = win32.FILE_NOTIFY_CHANGE_FILE_NAME |
            win32.FILE_NOTIFY_CHANGE_DIR_NAME |
            win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
            win32.FILE_NOTIFY_CHANGE_CREATION |
            win32.FILE_NOTIFY_CHANGE_SIZE;

        // Issue read with &dir.overlapped at its final, stable heap address
        const ok = win32.ReadDirectoryChangesW(
            dir.handle,
            dir.raw_buf.ptr,
            @intCast(dir.raw_buf.len),
            win32.FALSE,
            filter,
            null,
            &dir.overlapped,
            null,
        );

        if (ok == win32.FALSE) {
            const err = win32.GetLastError();
            if (err != win32.ERROR_IO_PENDING) {
                return error.ReadDirectoryChangesFailed;
            }
        }
        dir.pending_read = true;
    }

    /// Read pending events without blocking. Names point into `buf`.
    /// If the kernel event buffer overflows, an event with `.kind = .other` and `.name = ""` is emitted
    /// to notify the caller that events may have been lost.
    pub fn poll(self: Watcher, buf: []align(buffer_align) u8, out: []Event) !usize {
        var total_events: usize = 0;
        var name_buf_offset: usize = 0;

        for (self.state.dirs.items) |dir| {
            if (total_events >= out.len) break;
            if (!dir.active) continue;

            if (dir.cursor.isDone()) {
                if (dir.pending_read) {
                    var bytes_transferred: win32.DWORD = 0;
                    const res = win32.GetOverlappedResult(dir.handle, &dir.overlapped, &bytes_transferred, win32.FALSE);
                    if (res == win32.FALSE) {
                        const err = win32.GetLastError();
                        if (err == win32.ERROR_IO_INCOMPLETE or err == win32.ERROR_IO_PENDING) {
                            continue; // No pending events on this directory
                        }
                        return error.GetOverlappedResultFailed;
                    }
                    dir.pending_read = false;
                    dir.bytes_transferred = bytes_transferred;
                    dir.cursor.resetWithBuffer(bytes_transferred);
                }
            }

            if (!dir.cursor.isDone()) {
                const remaining_buf = buf[name_buf_offset..];
                const remaining_out = out[total_events..];

                const n = try dir.cursor.read(
                    dir.raw_buf[0..dir.bytes_transferred],
                    remaining_buf,
                    remaining_out,
                );

                for (remaining_out[0..n]) |ev| {
                    name_buf_offset += ev.name.len;
                }
                total_events += n;
            }

            // Only re-arm once the completed buffer has been completely consumed
            if (dir.cursor.isDone() and !dir.pending_read) {
                if (dir.overlapped.hEvent) |ev| {
                    // ResetEvent returns BOOL; failure leaves event signalled so next poll re-checks without hanging
                    _ = win32.ResetEvent(ev);
                }
                dir.overlapped.Internal = 0;
                dir.overlapped.InternalHigh = 0;
                dir.overlapped.Offset = 0;
                dir.overlapped.OffsetHigh = 0;

                const filter = win32.FILE_NOTIFY_CHANGE_FILE_NAME |
                    win32.FILE_NOTIFY_CHANGE_DIR_NAME |
                    win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
                    win32.FILE_NOTIFY_CHANGE_CREATION |
                    win32.FILE_NOTIFY_CHANGE_SIZE;

                const ok = win32.ReadDirectoryChangesW(
                    dir.handle,
                    dir.raw_buf.ptr,
                    @intCast(dir.raw_buf.len),
                    win32.FALSE,
                    filter,
                    null,
                    &dir.overlapped,
                    null,
                );
                if (ok == win32.FALSE) {
                    const err = win32.GetLastError();
                    if (err != win32.ERROR_IO_PENDING) {
                        dir.active = false;
                        return error.ReadDirectoryChangesFailed;
                    }
                }
                dir.pending_read = true;
            }
        }

        return total_events;
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const watcher = try Watcher.init();
    defer watcher.deinit();
    return .{
        .module = "fs_watch",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Win32 ReadDirectoryChangesW (overlapped)", .{}),
    };
}

test {
    std.testing.refAllDecls(@This());
}
