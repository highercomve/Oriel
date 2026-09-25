//! Overlay windows on Windows (Milestone 10): always-on-top (HWND_TOPMOST),
//! skip-taskbar (WS_EX_TOOLWINDOW: off the taskbar and Alt+Tab), per-pixel
//! transparency (DWM blur-behind with an empty region, plus a transparent
//! WebView2 background), click-through (WS_EX_LAYERED | WS_EX_TRANSPARENT)
//! and placement on the work area of the window's monitor.
//!
//! Sizes and margins are logical pixels (96 DPI), scaled by the window's DPI.

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const App = @import("../../core/App.zig");
const WindowHandle = @import("window.zig").WindowHandle;

const log = std.log.scoped(.oriel);

/// Extended style for a new window with `options`.
pub fn exStyle(options: App.WindowOptions) win32.DWORD {
    var ex: win32.DWORD = if (options.skip_taskbar) win32.WS_EX_TOOLWINDOW else win32.WS_EX_APPWINDOW;
    if (options.always_on_top) ex |= win32.WS_EX_TOPMOST;
    return ex;
}

test exStyle {
    try std.testing.expectEqual(win32.WS_EX_APPWINDOW, exStyle(.{}));
    const overlay = exStyle(.{ .skip_taskbar = true, .always_on_top = true });
    try std.testing.expect(overlay & win32.WS_EX_TOOLWINDOW != 0);
    try std.testing.expect(overlay & win32.WS_EX_APPWINDOW == 0);
    try std.testing.expect(overlay & win32.WS_EX_TOPMOST != 0);
}

/// Let DWM compose the window with per-pixel alpha, and give the webview a
/// transparent background: only what the page paints shows.
pub fn makeTransparent(hwnd: win32.HWND, controller: *webview2.ICoreWebView2Controller) void {
    // An empty blur region: no blur, just alpha composition of the client area.
    const region = win32.CreateRectRgn(0, 0, -1, -1);
    defer if (region) |r| {
        _ = win32.DeleteObject(r);
    };
    const bb: win32.DWM_BLURBEHIND = .{
        .dwFlags = win32.DWM_BB_ENABLE | win32.DWM_BB_BLURREGION,
        .fEnable = win32.TRUE,
        .hRgnBlur = region,
        .fTransitionOnMaximized = win32.FALSE,
    };
    const hr = win32.DwmEnableBlurBehindWindow(hwnd, &bb);
    if (hr < 0) log.warn("transparent window: DwmEnableBlurBehindWindow failed (0x{X})", .{@as(u32, @bitCast(hr))});

    var c2: ?*anyopaque = null;
    if (controller.lpVtbl.QueryInterface(controller, &webview2.IID_ICoreWebView2Controller2, &c2) < 0 or c2 == null) {
        log.warn("transparent window: this WebView2 runtime has no ICoreWebView2Controller2", .{});
        return;
    }
    const ctl2: *webview2.ICoreWebView2Controller2 = @ptrCast(@alignCast(c2.?));
    defer _ = ctl2.lpVtbl.base.Release(@ptrCast(ctl2));
    _ = ctl2.lpVtbl.put_DefaultBackgroundColor(ctl2, .{ .A = 0, .R = 0, .G = 0, .B = 0 });
}

fn scale(hwnd: win32.HWND) f32 {
    const dpi = win32.GetDpiForWindow(hwnd);
    return if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

fn workRect(hwnd: win32.HWND) ?win32.RECT {
    const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info: win32.MONITORINFO = .{};
    if (win32.GetMonitorInfoW(monitor, &info) == win32.FALSE) return null;
    return info.rcWork;
}

pub fn setWindowPlacement(handle: WindowHandle, placement: App.Placement) void {
    const hwnd = handle.hwnd;
    const work = workRect(hwnd) orelse return;
    var outer: win32.RECT = undefined;
    if (win32.GetWindowRect(hwnd, &outer) == win32.FALSE) return;
    const s = scale(hwnd);
    const scaled: App.Placement = .{ .anchor = placement.anchor, .margin = @intFromFloat(@round(@as(f32, @floatFromInt(placement.margin)) * s)) };
    const o = scaled.origin(
        .{ .x = work.left, .y = work.top, .width = work.right - work.left, .height = work.bottom - work.top },
        outer.right - outer.left,
        outer.bottom - outer.top,
    );
    _ = win32.SetWindowPos(hwnd, null, o.x, o.y, 0, 0, win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

pub fn setWindowClickThrough(handle: WindowHandle, enabled: bool) void {
    const hwnd = handle.hwnd;
    const current: win32.DWORD = @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE))));
    const bits = win32.WS_EX_LAYERED | win32.WS_EX_TRANSPARENT;
    const next = if (enabled) current | bits else current & ~bits;
    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, @intCast(next));
    // A layered window stays invisible until its attributes are set.
    if (enabled) _ = win32.SetLayeredWindowAttributes(hwnd, 0, 255, win32.LWA_ALPHA);
    _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED);
}

pub fn setWindowAlwaysOnTop(handle: WindowHandle, enabled: bool) void {
    _ = win32.SetWindowPos(handle.hwnd, if (enabled) win32.HWND_TOPMOST else win32.HWND_NOTOPMOST, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE);
}

/// The work area of the window's monitor, in logical pixels.
pub fn getWindowWorkArea(handle: WindowHandle) ?App.Rect {
    const r = workRect(handle.hwnd) orelse return null;
    const s = scale(handle.hwnd);
    const l = struct {
        fn f(v: c_int, k: f32) c_int {
            return @intFromFloat(@round(@as(f32, @floatFromInt(v)) / k));
        }
    }.f;
    return .{ .x = l(r.left, s), .y = l(r.top, s), .width = l(r.right - r.left, s), .height = l(r.bottom - r.top, s) };
}
