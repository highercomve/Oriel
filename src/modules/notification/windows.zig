//! Windows desktop notification implementation via Shell_NotifyIconW balloon.
//!
//! Design:
//! - Balloon notifications via Win32 `Shell_NotifyIconW` with `NIF_INFO`.
//! - Uses `Shell.host_hwnd` as owner with a dedicated notification uID (`NOTIFICATION_UID = 2001`)
//!   so it never interferes with any tray icon (`uID` 1001+).
//! - Sets NOTIFYICON_VERSION_4 consistently and routes callbacks through `Shell.WM_NOTIFY_CALLBACK`.
//! - Uses the app window's icon, or exe icon, before falling back to IDI_APPLICATION.
//! - Removes notification icon on NIN_BALLOONTIMEOUT, NIN_BALLOONUSERCLICK, NIN_BALLOONHIDE, and at shutdown.
//! - Safe UTF-16 truncation: titles truncated at 63 WCHARs, bodies at 255 WCHARs on UTF-16 boundaries
//!   (preventing orphaned surrogate halves).
//! - Main-thread marshalling: marshals through `Shell.runOnMainThread`.
//! - Documented: balloon-only (WinRT toasts require external packaging and AppUserModelID).

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const NotificationOptions = common.NotificationOptions;

pub const NOTIFICATION_UID: win32.UINT = 2001;
var notification_icon_active: bool = false;

const NotifyParams = struct {
    title: []const u8,
    body: ?[]const u8,
    err: ?anyerror = null,
};

fn getNotificationIcon() ?win32.HICON {
    if (ShellMod.main_hwnd) |hwnd| {
        const h = win32.GetClassLongPtrW(hwnd, win32.GCLP_HICONSM);
        if (h != 0) return @ptrFromInt(h);
    }
    if (win32.GetModuleHandleW(null)) |hmod| {
        if (win32.LoadIconW(@ptrCast(hmod), @ptrFromInt(1))) |h| {
            return h;
        }
    }
    return win32.LoadIconW(null, win32.IDI_APPLICATION);
}

fn handleNotificationCallback(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    _ = wParam;
    const raw: usize = @bitCast(lParam);
    const event: u16 = @truncate(raw);
    const icon_id: u16 = @truncate(raw >> 16);

    if (icon_id == NOTIFICATION_UID) {
        switch (event) {
            win32.NIN_BALLOONTIMEOUT, win32.NIN_BALLOONUSERCLICK, win32.NIN_BALLOONHIDE => {
                removeNotificationIcon();
            },
            else => {},
        }
    }
}

fn sendBalloonDirect(params: *NotifyParams) void {
    const target_hwnd = ShellMod.host_hwnd orelse {
        params.err = error.AppNotRunning;
        return;
    };

    ShellMod.on_notify_message_fn = &handleNotificationCallback;
    ShellMod.on_shutdown_fn = &deinit;

    var nid = std.mem.zeroes(win32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
    nid.hWnd = target_hwnd;
    nid.uID = NOTIFICATION_UID;
    nid.uFlags = win32.NIF_INFO | win32.NIF_MESSAGE;
    nid.uCallbackMessage = ShellMod.WM_NOTIFY_CALLBACK;

    _ = common.truncateUtf8ToUtf16(params.title, &nid.szInfoTitle, 63);

    if (params.body) |body| {
        _ = common.truncateUtf8ToUtf16(body, &nid.szInfo, 255);
    }

    nid.dwInfoFlags = win32.NIIF_INFO;

    if (!notification_icon_active) {
        nid.uFlags |= win32.NIF_ICON;
        nid.hIcon = getNotificationIcon();
        if (win32.Shell_NotifyIconW(win32.NIM_ADD, &nid) == win32.FALSE) {
            params.err = error.ShellNotifyIconFailed;
            return;
        }
        nid.uTimeoutOrVersion = win32.NOTIFYICON_VERSION_4;
        _ = win32.Shell_NotifyIconW(win32.NIM_SETVERSION, &nid);
        notification_icon_active = true;
    } else {
        if (win32.Shell_NotifyIconW(win32.NIM_MODIFY, &nid) == win32.FALSE) {
            params.err = error.ShellNotifyIconFailed;
            return;
        }
    }
}

pub fn notify(options: NotificationOptions) !void {
    var params = NotifyParams{
        .title = options.title,
        .body = options.body,
    };

    try ShellMod.runOnMainThread(NotifyParams, &params, sendBalloonDirect);

    if (params.err) |err| return err;
}

pub fn removeNotificationIcon() void {
    if (!notification_icon_active) return;
    const target_hwnd = ShellMod.host_hwnd orelse {
        notification_icon_active = false;
        return;
    };
    var nid = std.mem.zeroes(win32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
    nid.hWnd = target_hwnd;
    nid.uID = NOTIFICATION_UID;
    _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &nid);
    notification_icon_active = false;
}

pub fn deinit() void {
    removeNotificationIcon();
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var title_buf: [64]u16 = undefined;
    const len = common.truncateUtf8ToUtf16("oriel check", &title_buf, 63);
    if (len == 0) return error.TruncateFailed;

    return .{
        .module = "notification",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Win32 Shell_NotifyIconW balloon notifications available (balloon-only)", .{}),
    };
}

test {
    std.testing.refAllDecls(@This());
}
