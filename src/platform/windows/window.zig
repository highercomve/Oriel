//! Windows Win32 and WebView2 window creation and manipulation.
//!
//! Handles native HWND and ICoreWebView2 instantiation, window properties
//! (size, fullscreen, maximized, title), navigation policy decisions, and close requests.

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const scheme_mod = @import("scheme.zig");
const bridge_mod = @import("bridge.zig");
const ShellMod = @import("Shell.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");

const log = std.log.scoped(.oriel);

pub const WINDOW_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("OrielWindowClass");

pub const WindowHandle = struct {
    hwnd: win32.HWND,
    controller: *webview2.ICoreWebView2Controller,
    webview: *webview2.ICoreWebView2,
    data: ?*anyopaque = null,
    deinit_fn: ?*const fn (ctx: *anyopaque) void = null,

    pub fn deinit(self: WindowHandle) void {
        if (self.deinit_fn) |f| {
            if (self.data) |d| f(d);
        }
    }

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.hwnd == other.hwnd;
    }
};

pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

pub fn showWindow(handle: WindowHandle) void {
    _ = win32.ShowWindow(handle.hwnd, win32.SW_SHOW);
    _ = win32.SetForegroundWindow(handle.hwnd);
}

pub fn hideWindow(handle: WindowHandle) void {
    _ = win32.ShowWindow(handle.hwnd, win32.SW_HIDE);
}

pub fn toggleWindow(handle: WindowHandle) void {
    if (win32.IsWindowVisible(handle.hwnd) != .FALSE and win32.GetForegroundWindow() == handle.hwnd) {
        hideWindow(handle);
    } else {
        showWindow(handle);
    }
}

/// Close like the user clicked X. On the main thread this is synchronous (as
/// GTK's close is): the window is gone when it returns. From other threads the
/// request is posted to the window's thread.
pub fn closeWindow(handle: WindowHandle) void {
    if (win32.GetCurrentThreadId() == ShellMod.main_thread_id) {
        _ = win32.SendMessageW(handle.hwnd, win32.WM_CLOSE, 0, 0); // the handler's result carries no information
    } else if (win32.PostMessageW(handle.hwnd, win32.WM_CLOSE, 0, 0) == win32.FALSE) {
        log.err("closeWindow: PostMessageW failed ({d})", .{win32.GetLastError()});
    }
}

pub fn destroyWindow(handle: WindowHandle) void {
    _ = win32.SetWindowLongPtrW(handle.hwnd, win32.GWLP_USERDATA, 0);
    handle.deinit();
    _ = win32.DestroyWindow(handle.hwnd);
    if (ShellMod.main_hwnd == handle.hwnd) ShellMod.main_hwnd = null;
}

pub fn setWindowTitle(handle: WindowHandle, title: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, title) catch return;
    defer gpa.free(title_w);
    _ = win32.SetWindowTextW(handle.hwnd, title_w.ptr);
}

/// Read a 32-bit window long (style bits). GetWindowLongPtrW returns a
/// sign-extended LONG_PTR, so WS_POPUP (bit 31) comes back negative and
/// `@intCast` to DWORD would panic: keep the low 32 bits instead.
fn windowLong(hwnd: win32.HWND, index: c_int) win32.DWORD {
    return @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, index))));
}

pub fn setWindowFullscreen(handle: WindowHandle, fullscreen: bool) void {
    const hwnd = handle.hwnd;
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE);

    if (fullscreen) {
        var wp: win32.WINDOWPLACEMENT = undefined;
        _ = win32.GetWindowPlacement(hwnd, &wp);
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, style & ~@as(win32.LONG_PTR, @intCast(win32.WS_OVERLAPPEDWINDOW)));
        _ = win32.ShowWindow(hwnd, win32.SW_MAXIMIZE);
    } else {
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, style | @as(win32.LONG_PTR, @intCast(win32.WS_OVERLAPPEDWINDOW)));
        _ = win32.ShowWindow(hwnd, win32.SW_RESTORE);
    }
}

pub fn isWindowFullscreen(handle: WindowHandle) bool {
    const style = windowLong(handle.hwnd, win32.GWL_STYLE);
    return (style & win32.WS_OVERLAPPEDWINDOW) == 0;
}

pub fn setWindowMaximized(handle: WindowHandle, maximized: bool) void {
    _ = win32.ShowWindow(handle.hwnd, if (maximized) win32.SW_MAXIMIZE else win32.SW_RESTORE);
}

pub fn isWindowMaximized(handle: WindowHandle) bool {
    return win32.IsZoomed(handle.hwnd) != .FALSE;
}

pub fn setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void {
    var rect = win32.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
    const style = windowLong(handle.hwnd, win32.GWL_STYLE);
    const ex_style = windowLong(handle.hwnd, win32.GWL_EXSTYLE);
    // `width`/`height` are the client (webview) size: account for a menu bar.
    const has_menu: win32.BOOL = if (win32.GetMenu(handle.hwnd) != null) win32.TRUE else win32.FALSE;
    _ = win32.AdjustWindowRectEx(&rect, style, has_menu, ex_style);
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    _ = win32.SetWindowPos(handle.hwnd, null, 0, 0, w, h, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
}

pub fn getWindowSize(handle: WindowHandle) WindowSize {
    var rect: win32.RECT = undefined;
    _ = win32.GetClientRect(handle.hwnd, &rect);
    return .{
        .width = rect.right - rect.left,
        .height = rect.bottom - rect.top,
    };
}

pub fn openExternal(uri: [*:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const uri_slice = std.mem.span(uri);
    const uri_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, uri_slice) catch return;
    defer gpa.free(uri_w);
    const open_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
    _ = win32.ShellExecuteW(null, open_w, uri_w.ptr, null, null, win32.SW_SHOWNORMAL);
}

pub fn getWindowByView(view: *webview2.ICoreWebView2) ?*App.Window {
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.webview == view) return w;
    }
    return null;
}

pub fn getWindowByHwnd(hwnd: win32.HWND) ?*App.Window {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn WindowCreator(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime csp_z: ?[:0]const u8,
) type {
    const SchemeImpl = scheme_mod.Scheme(config, csp_z);
    const BridgeImpl = bridge_mod.Bridge(api, config, local);

    return struct {
        // WebResourceRequested event handler
        /// Lifetime: owned by WindowData, which outlives the registration.
        /// Removed via webview.remove_WebResourceRequested in WindowData.deinit before freeing.
        const ResourceHandler = struct {
            handler: webview2.ICoreWebView2WebResourceRequestedEventHandler,
            env_ptr: *webview2.ICoreWebView2Environment,

            const res_vtable = webview2.ICoreWebView2WebResourceRequestedEventHandler.VTable{
                .QueryInterface = &qiRes,
                .AddRef = &addRefRes,
                .Release = &releaseRes,
                .Invoke = &invokeRes,
            };

            fn qiRes(this: *webview2.ICoreWebView2WebResourceRequestedEventHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2WebResourceRequestedEventHandler)) {
                    ppv.* = this;
                    _ = addRefRes(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefRes(_: *webview2.ICoreWebView2WebResourceRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn releaseRes(_: *webview2.ICoreWebView2WebResourceRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn invokeRes(r_this: *webview2.ICoreWebView2WebResourceRequestedEventHandler, _: ?*webview2.ICoreWebView2, args: ?*webview2.ICoreWebView2WebResourceRequestedEventArgs) callconv(.winapi) win32.HRESULT {
                const r_self: *@This() = @fieldParentPtr("handler", r_this);
                if (args) |a| {
                    SchemeImpl.handleRequest(r_self.env_ptr, a);
                }
                return win32.S_OK;
            }
        };

        // WebMessageReceived event handler
        /// Lifetime: owned by WindowData, which outlives the registration.
        /// Removed via webview.remove_WebMessageReceived in WindowData.deinit before freeing.
        const MessageHandler = struct {
            handler: webview2.ICoreWebView2WebMessageReceivedEventHandler,

            const msg_vtable = webview2.ICoreWebView2WebMessageReceivedEventHandler.VTable{
                .QueryInterface = &qiMsg,
                .AddRef = &addRefMsg,
                .Release = &releaseMsg,
                .Invoke = &invokeMsg,
            };

            fn qiMsg(this: *webview2.ICoreWebView2WebMessageReceivedEventHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2WebMessageReceivedEventHandler)) {
                    ppv.* = this;
                    _ = addRefMsg(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefMsg(_: *webview2.ICoreWebView2WebMessageReceivedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn releaseMsg(_: *webview2.ICoreWebView2WebMessageReceivedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn invokeMsg(_: *webview2.ICoreWebView2WebMessageReceivedEventHandler, sender: ?*webview2.ICoreWebView2, args: ?*webview2.ICoreWebView2WebMessageReceivedEventArgs) callconv(.winapi) win32.HRESULT {
                if (sender) |s| {
                    if (args) |a| {
                        BridgeImpl.onMessage(s, a);
                    }
                }
                return win32.S_OK;
            }
        };

        // NavigationStarting event handler
        /// Lifetime: owned by WindowData, which outlives the registration.
        /// Removed via webview.remove_NavigationStarting in WindowData.deinit before freeing.
        const NavHandler = struct {
            handler: webview2.ICoreWebView2NavigationStartingEventHandler,

            const nav_vtable = webview2.ICoreWebView2NavigationStartingEventHandler.VTable{
                .QueryInterface = &qiNav,
                .AddRef = &addRefNav,
                .Release = &releaseNav,
                .Invoke = &invokeNav,
            };

            fn qiNav(this: *webview2.ICoreWebView2NavigationStartingEventHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2NavigationStartingEventHandler)) {
                    ppv.* = this;
                    _ = addRefNav(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefNav(_: *webview2.ICoreWebView2NavigationStartingEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn releaseNav(_: *webview2.ICoreWebView2NavigationStartingEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn invokeNav(_: *webview2.ICoreWebView2NavigationStartingEventHandler, _: ?*webview2.ICoreWebView2, args: ?*webview2.ICoreWebView2NavigationStartingEventArgs) callconv(.winapi) win32.HRESULT {
                if (args) |a| {
                    var uri_w: ?win32.LPWSTR = null;
                    const uri_hr = a.lpVtbl.get_Uri(a, @ptrCast(&uri_w));
                    defer if (uri_w != null) win32.CoTaskMemFree(uri_w);

                    if (uri_hr < 0 or uri_w == null) {
                        _ = a.lpVtbl.put_Cancel(a, win32.TRUE);
                        return win32.S_OK;
                    }

                    const slen = std.mem.indexOfScalar(u16, std.mem.span(uri_w.?), 0) orelse std.mem.span(uri_w.?).len;
                    const uri_u8 = std.unicode.utf16LeToUtf8Alloc(std.heap.smp_allocator, uri_w.?[0..slen]) catch {
                        _ = a.lpVtbl.put_Cancel(a, win32.TRUE);
                        return win32.S_OK;
                    };
                    defer std.heap.smp_allocator.free(uri_u8);

                    var user_init: win32.BOOL = .FALSE;
                    _ = a.lpVtbl.get_IsUserInitiated(a, &user_init);

                    const verdict = security.navigation(config.security, local, uri_u8, user_init != .FALSE);
                    switch (verdict) {
                        .allow => {},
                        .open_external => {
                            _ = a.lpVtbl.put_Cancel(a, win32.TRUE);
                            const uri_z = std.heap.smp_allocator.dupeZ(u8, uri_u8) catch return win32.S_OK;
                            defer std.heap.smp_allocator.free(uri_z);
                            App.openExternal(uri_z);
                        },
                        .block => {
                            _ = a.lpVtbl.put_Cancel(a, win32.TRUE);
                            log.warn("blocked navigation to {s}", .{uri_u8});
                        },
                    }
                }
                return win32.S_OK;
            }
        };

        // NewWindowRequested event handler
        /// Lifetime: owned by WindowData, which outlives the registration.
        /// Removed via webview.remove_NewWindowRequested in WindowData.deinit before freeing.
        const NewWinHandler = struct {
            handler: webview2.ICoreWebView2NewWindowRequestedEventHandler,
            main_view: *webview2.ICoreWebView2,

            const new_win_vtable = webview2.ICoreWebView2NewWindowRequestedEventHandler.VTable{
                .QueryInterface = &qiNW,
                .AddRef = &addRefNW,
                .Release = &releaseNW,
                .Invoke = &invokeNW,
            };

            fn qiNW(this: *webview2.ICoreWebView2NewWindowRequestedEventHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2NewWindowRequestedEventHandler)) {
                    ppv.* = this;
                    _ = addRefNW(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefNW(_: *webview2.ICoreWebView2NewWindowRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn releaseNW(_: *webview2.ICoreWebView2NewWindowRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn invokeNW(nw_this: *webview2.ICoreWebView2NewWindowRequestedEventHandler, _: ?*webview2.ICoreWebView2, args: ?*webview2.ICoreWebView2NewWindowRequestedEventArgs) callconv(.winapi) win32.HRESULT {
                const nw_self: *@This() = @fieldParentPtr("handler", nw_this);
                if (args) |a| {
                    _ = a.lpVtbl.put_Handled(a, win32.TRUE);
                    var uri_w: ?win32.LPWSTR = null;
                    if (a.lpVtbl.get_Uri(a, @ptrCast(&uri_w)) >= 0 and uri_w != null) {
                        defer win32.CoTaskMemFree(uri_w);
                        const slen = std.mem.indexOfScalar(u16, std.mem.span(uri_w.?), 0) orelse std.mem.span(uri_w.?).len;
                        const uri_u8 = std.unicode.utf16LeToUtf8Alloc(std.heap.smp_allocator, uri_w.?[0..slen]) catch return win32.S_OK;
                        defer std.heap.smp_allocator.free(uri_u8);

                        var user_init: win32.BOOL = .FALSE;
                        _ = a.lpVtbl.get_IsUserInitiated(a, &user_init);

                        const verdict = security.navigation(config.security, local, uri_u8, user_init != .FALSE);
                        switch (verdict) {
                            .allow => {
                                _ = nw_self.main_view.navigate(uri_w.?);
                            },
                            .open_external => {
                                const uri_z = std.heap.smp_allocator.dupeZ(u8, uri_u8) catch return win32.S_OK;
                                defer std.heap.smp_allocator.free(uri_z);
                                App.openExternal(uri_z);
                            },
                            .block => {
                                log.warn("blocked new window to {s}", .{uri_u8});
                            },
                        }
                    }
                }
                return win32.S_OK;
            }
        };

        // WindowCloseRequested event handler
        /// Lifetime: owned by WindowData, which outlives the registration.
        /// Removed via webview.remove_WindowCloseRequested in WindowData.deinit before freeing.
        const CloseHandler = struct {
            handler: webview2.ICoreWebView2WindowCloseRequestedEventHandler,
            target_hwnd: win32.HWND,

            const close_vtable = webview2.ICoreWebView2WindowCloseRequestedEventHandler.VTable{
                .QueryInterface = &qiClose,
                .AddRef = &addRefClose,
                .Release = &releaseClose,
                .Invoke = &invokeClose,
            };

            fn qiClose(this: *webview2.ICoreWebView2WindowCloseRequestedEventHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2WindowCloseRequestedEventHandler)) {
                    ppv.* = this;
                    _ = addRefClose(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefClose(_: *webview2.ICoreWebView2WindowCloseRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn releaseClose(_: *webview2.ICoreWebView2WindowCloseRequestedEventHandler) callconv(.winapi) win32.ULONG {
                return 1;
            }
            fn invokeClose(cl_this: *webview2.ICoreWebView2WindowCloseRequestedEventHandler, _: ?*webview2.ICoreWebView2, _: ?*anyopaque) callconv(.winapi) win32.HRESULT {
                const cl_self: *@This() = @fieldParentPtr("handler", cl_this);
                _ = win32.PostMessageW(cl_self.target_hwnd, win32.WM_CLOSE, 0, 0);
                return win32.S_OK;
            }
        };

        pub const WindowData = struct {
            env: *webview2.ICoreWebView2Environment,
            controller: *webview2.ICoreWebView2Controller,
            webview: *webview2.ICoreWebView2,

            res_handler: ResourceHandler,
            res_token: webview2.EventRegistrationToken = .{},

            msg_handler: MessageHandler,
            msg_token: webview2.EventRegistrationToken = .{},

            nav_handler: NavHandler,
            nav_token: webview2.EventRegistrationToken = .{},
            /// iframes: NavigationStarting only covers the top-level document.
            frame_nav_token: webview2.EventRegistrationToken = .{},

            nw_handler: NewWinHandler,
            nw_token: webview2.EventRegistrationToken = .{},

            cl_handler: CloseHandler,
            cl_token: webview2.EventRegistrationToken = .{},

            pub fn deinit(self: *WindowData) void {
                _ = self.webview.lpVtbl.remove_WebResourceRequested(self.webview, self.res_token);
                _ = self.webview.lpVtbl.remove_WebMessageReceived(self.webview, self.msg_token);
                _ = self.webview.lpVtbl.remove_NavigationStarting(self.webview, self.nav_token);
                _ = self.webview.lpVtbl.remove_FrameNavigationStarting(self.webview, self.frame_nav_token);
                _ = self.webview.lpVtbl.remove_NewWindowRequested(self.webview, self.nw_token);
                _ = self.webview.lpVtbl.remove_WindowCloseRequested(self.webview, self.cl_token);

                _ = self.env.lpVtbl.Release(self.env);
                _ = self.controller.lpVtbl.Close(self.controller);
                _ = self.controller.lpVtbl.Release(self.controller);
                _ = self.webview.lpVtbl.Release(self.webview);

                std.heap.smp_allocator.destroy(self);
            }

            fn deinitTypeErased(ctx: *anyopaque) void {
                const self: *WindowData = @ptrCast(@alignCast(ctx));
                self.deinit();
            }
        };

        /// Shared initialization state between createWindow and the async completion handlers.
        /// Lifetime: heap-allocated with atomic refcount. The creator holds one reference
        /// and each active completion handler (EnvHandler, CtrlHandler) holds one; freed at zero.
        const InitState = struct {
            ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
            abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            env: ?*webview2.ICoreWebView2Environment = null,
            controller: ?*webview2.ICoreWebView2Controller = null,
            err: ?win32.HRESULT = null,

            fn ref(self: *InitState) void {
                _ = self.ref_count.fetchAdd(1, .monotonic);
            }

            fn unref(self: *InitState) void {
                if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
                    if (self.controller) |c| _ = c.lpVtbl.Release(c);
                    if (self.env) |e| _ = e.lpVtbl.Release(e);
                    std.heap.smp_allocator.destroy(self);
                }
            }
        };

        /// Lifetime: heap-allocated with atomic refcount. The creator holds one reference
        /// and WebView2 holds its own; freed at zero. Unrefs InitState on destruction.
        const CtrlHandler = struct {
            handler: webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
            ref_count: std.atomic.Value(u32),
            ctrl_state: *InitState,

            const ctrl_vtable = webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler.VTable{
                .QueryInterface = &qiCtrl,
                .AddRef = &addRefCtrl,
                .Release = &releaseCtrl,
                .Invoke = &invokeCtrl,
            };

            fn qiCtrl(c_this: *webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler)) {
                    ppv.* = c_this;
                    _ = addRefCtrl(c_this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRefCtrl(c_this: *webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(.winapi) win32.ULONG {
                const c_self: *@This() = @fieldParentPtr("handler", c_this);
                return c_self.ref_count.fetchAdd(1, .monotonic) + 1;
            }
            fn releaseCtrl(c_this: *webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) callconv(.winapi) win32.ULONG {
                const c_self: *@This() = @fieldParentPtr("handler", c_this);
                const prev = c_self.ref_count.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    c_self.ctrl_state.unref();
                    std.heap.smp_allocator.destroy(c_self);
                    return 0;
                }
                return prev - 1;
            }
            fn invokeCtrl(c_this: *webview2.ICoreWebView2CreateCoreWebView2ControllerCompletedHandler, c_err: win32.HRESULT, c_result: ?*webview2.ICoreWebView2Controller) callconv(.winapi) win32.HRESULT {
                const c_self: *@This() = @fieldParentPtr("handler", c_this);
                if (c_self.ctrl_state.abandoned.load(.acquire)) {
                    c_self.ctrl_state.completed.store(true, .release);
                    return win32.S_OK;
                }
                if (c_err < 0 or c_result == null) {
                    c_self.ctrl_state.err = c_err;
                } else {
                    const ctrl = c_result.?;
                    _ = ctrl.lpVtbl.AddRef(ctrl);
                    c_self.ctrl_state.controller = ctrl;
                }
                c_self.ctrl_state.completed.store(true, .release);
                return win32.S_OK;
            }
        };

        /// Lifetime: heap-allocated with atomic refcount. The creator holds one reference
        /// and WebView2 holds its own; freed at zero. Unrefs InitState on destruction.
        const EnvHandler = struct {
            handler: webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
            ref_count: std.atomic.Value(u32),
            target_hwnd: win32.HWND,
            init_state: *InitState,

            const vtable = webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler.VTable{
                .QueryInterface = &qi,
                .AddRef = &addRef,
                .Release = &release,
                .Invoke = &invoke,
            };

            fn qi(this: *webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, riid: *const win32.GUID, ppv: *?*anyopaque) callconv(.winapi) win32.HRESULT {
                if (win32.isEqualGUID(riid, &webview2.IID_IUnknown) or win32.isEqualGUID(riid, &webview2.IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler)) {
                    ppv.* = this;
                    _ = addRef(this);
                    return win32.S_OK;
                }
                ppv.* = null;
                return win32.E_NOINTERFACE;
            }
            fn addRef(this: *webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(.winapi) win32.ULONG {
                const self: *@This() = @fieldParentPtr("handler", this);
                return self.ref_count.fetchAdd(1, .monotonic) + 1;
            }
            fn release(this: *webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) callconv(.winapi) win32.ULONG {
                const self: *@This() = @fieldParentPtr("handler", this);
                const prev = self.ref_count.fetchSub(1, .acq_rel);
                if (prev == 1) {
                    self.init_state.unref();
                    std.heap.smp_allocator.destroy(self);
                    return 0;
                }
                return prev - 1;
            }
            fn invoke(this: *webview2.ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler, err: win32.HRESULT, result: ?*webview2.ICoreWebView2Environment) callconv(.winapi) win32.HRESULT {
                const self: *@This() = @fieldParentPtr("handler", this);
                if (self.init_state.abandoned.load(.acquire)) {
                    self.init_state.completed.store(true, .release);
                    return win32.S_OK;
                }
                if (err < 0 or result == null) {
                    self.init_state.err = err;
                    self.init_state.completed.store(true, .release);
                    return win32.S_OK;
                }
                const env = result.?;
                _ = env.lpVtbl.AddRef(env);
                self.init_state.env = env;

                const gpa = std.heap.smp_allocator;
                const ctrl_handler = gpa.create(CtrlHandler) catch {
                    self.init_state.err = win32.E_FAIL;
                    self.init_state.completed.store(true, .release);
                    return win32.S_OK;
                };
                self.init_state.ref();
                ctrl_handler.* = .{
                    .handler = .{ .lpVtbl = &CtrlHandler.ctrl_vtable },
                    .ref_count = std.atomic.Value(u32).init(1),
                    .ctrl_state = self.init_state,
                };

                const hr = env.createCoreWebView2Controller(self.target_hwnd, &ctrl_handler.handler);
                _ = ctrl_handler.handler.lpVtbl.Release(&ctrl_handler.handler);
                if (hr < 0) {
                    self.init_state.err = hr;
                    self.init_state.completed.store(true, .release);
                }
                return win32.S_OK;
            }
        };

        pub fn registerWindowClass() !void {
            const hInst: win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse return error.NoModuleHandle);
            const wc = win32.WNDCLASSEXW{
                .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
                .lpfnWndProc = &wndProc,
                .hInstance = hInst,
                .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
                .lpszClassName = WINDOW_CLASS_NAME,
            };
            if (win32.RegisterClassExW(&wc) == 0) {
                // Ignore if class already registered
                if (win32.GetLastError() != 1410) { // ERROR_CLASS_ALREADY_EXISTS
                    return error.RegisterClassFailed;
                }
            }
        }

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            try registerWindowClass();

            const hInst: win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse return error.NoModuleHandle);
            const gpa = std.heap.smp_allocator;

            const title_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, options.title);
            defer gpa.free(title_w);

            var style: win32.DWORD = win32.WS_OVERLAPPEDWINDOW;
            if (!options.decorations) style = win32.WS_POPUP;
            if (!options.resizable and options.decorations) {
                style &= ~@as(win32.DWORD, win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
            }

            var rect = win32.RECT{
                .left = 0,
                .top = 0,
                .right = options.width,
                .bottom = options.height,
            };
            _ = win32.AdjustWindowRectEx(&rect, style, win32.FALSE, win32.WS_EX_APPWINDOW);
            const w = rect.right - rect.left;
            const h = rect.bottom - rect.top;

            const hwnd = win32.CreateWindowExW(
                win32.WS_EX_APPWINDOW,
                WINDOW_CLASS_NAME,
                title_w.ptr,
                style,
                win32.CW_USEDEFAULT,
                win32.CW_USEDEFAULT,
                w,
                h,
                null,
                null,
                hInst,
                null,
            ) orelse return error.CreateWindowFailed;
            errdefer _ = win32.DestroyWindow(hwnd);

            // Compute userDataFolder: %LOCALAPPDATA%\<app_id>\WebView2
            const user_data_folder_w = blk: {
                var buf: [win32.MAX_PATH]u16 = undefined;
                var len = win32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &buf, buf.len);
                if (len == 0 or len >= buf.len) {
                    len = win32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("TEMP"), &buf, buf.len);
                }
                if (len > 0 and len < buf.len) {
                    const base_u8 = std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]) catch break :blk null;
                    defer gpa.free(base_u8);
                    const folder_path = std.fmt.allocPrint(gpa, "{s}\\{s}\\WebView2", .{ base_u8, config.id }) catch break :blk null;
                    defer gpa.free(folder_path);
                    break :blk std.unicode.utf8ToUtf16LeAllocZ(gpa, folder_path) catch null;
                }
                break :blk null;
            };
            defer if (user_data_folder_w) |ud| gpa.free(ud);

            // Initialize WebView2
            const state = try gpa.create(InitState);
            state.* = .{};

            const env_handler = gpa.create(EnvHandler) catch |err| {
                state.unref();
                return err;
            };
            state.ref();
            env_handler.* = .{
                .handler = .{ .lpVtbl = &EnvHandler.vtable },
                .ref_count = std.atomic.Value(u32).init(1),
                .target_hwnd = hwnd,
                .init_state = state,
            };

            const user_data_ptr: ?win32.LPCWSTR = if (user_data_folder_w) |ud| ud.ptr else null;
            const env_hr = webview2.createEnvironmentWithOptions(user_data_ptr, &env_handler.handler);
            _ = env_handler.handler.lpVtbl.Release(&env_handler.handler);
            if (env_hr) |_| {} else |err| {
                state.abandoned.store(true, .release);
                state.unref();
                return err;
            }

            // Pump modal messages until WebView2 environment and controller are initialized
            var msg: win32.MSG = undefined;
            var early_exit = false;
            while (!state.completed.load(.acquire)) {
                const res = win32.GetMessageW(&msg, null, 0, 0);
                if (@intFromEnum(res) == 0) {
                    win32.PostQuitMessage(@intCast(msg.wParam));
                    early_exit = true;
                    break;
                } else if (@intFromEnum(res) < 0) {
                    early_exit = true;
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }

            if (early_exit or state.err != null or state.controller == null or state.env == null) {
                state.abandoned.store(true, .release);
                state.unref();
                return error.WebView2InitFailed;
            }

            const env = state.env.?;
            state.env = null;
            errdefer _ = env.lpVtbl.Release(env);

            const controller = state.controller.?;
            state.controller = null;
            errdefer {
                _ = controller.lpVtbl.Close(controller);
                _ = controller.lpVtbl.Release(controller);
            }
            state.unref();

            var view_opt: ?*webview2.ICoreWebView2 = null;
            if (controller.getCoreWebView2(&view_opt) < 0 or view_opt == null) {
                return error.WebView2InitFailed;
            }
            const view = view_opt.?;
            errdefer _ = view.lpVtbl.Release(view);

            // Settings
            var settings_opt: ?*webview2.ICoreWebView2Settings = null;
            if (view.getSettings(&settings_opt) >= 0 and settings_opt != null) {
                const s = settings_opt.?;
                defer _ = s.lpVtbl.Release(s);
                _ = s.lpVtbl.put_IsScriptEnabled(s, win32.TRUE);
                _ = s.lpVtbl.put_IsWebMessageEnabled(s, win32.TRUE);
                _ = s.lpVtbl.put_AreDevToolsEnabled(s, if (config.devtools) win32.TRUE else win32.FALSE);
                _ = s.lpVtbl.put_AreDefaultScriptDialogsEnabled(s, win32.TRUE);
            }

            // Register asset filter for "https://app.localhost/*"
            const filter_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, scheme_mod.filter_pattern);
            defer gpa.free(filter_w);
            _ = view.addWebResourceRequestedFilter(filter_w.ptr, webview2.COREWEBVIEW2_WEB_RESOURCE_CONTEXT.ALL);

            // Allocate WindowData
            const data = try gpa.create(WindowData);
            errdefer gpa.destroy(data);

            data.* = .{
                .env = env,
                .controller = controller,
                .webview = view,
                .res_handler = .{
                    .handler = .{ .lpVtbl = &ResourceHandler.res_vtable },
                    .env_ptr = env,
                },
                .msg_handler = .{
                    .handler = .{ .lpVtbl = &MessageHandler.msg_vtable },
                },
                .nav_handler = .{
                    .handler = .{ .lpVtbl = &NavHandler.nav_vtable },
                },
                .nw_handler = .{
                    .handler = .{ .lpVtbl = &NewWinHandler.new_win_vtable },
                    .main_view = view,
                },
                .cl_handler = .{
                    .handler = .{ .lpVtbl = &CloseHandler.close_vtable },
                    .target_hwnd = hwnd,
                },
            };

            // Register event handlers
            if (view.addWebResourceRequested(&data.res_handler.handler, &data.res_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_WebResourceRequested(view, data.res_token);

            if (view.addWebMessageReceived(&data.msg_handler.handler, &data.msg_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_WebMessageReceived(view, data.msg_token);

            if (view.addNavigationStarting(&data.nav_handler.handler, &data.nav_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_NavigationStarting(view, data.nav_token);

            // Same policy for iframes as for the page (WebKitGTK's
            // decide-policy covers both); FrameNavigationStarting passes the
            // same args type, so the same handler serves both events.
            if (view.lpVtbl.add_FrameNavigationStarting(view, &data.nav_handler.handler, &data.frame_nav_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_FrameNavigationStarting(view, data.frame_nav_token);

            if (view.addNewWindowRequested(&data.nw_handler.handler, &data.nw_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_NewWindowRequested(view, data.nw_token);

            if (view.addWindowCloseRequested(&data.cl_handler.handler, &data.cl_token) < 0) {
                return error.WebView2AddEventHandlerFailed;
            }
            errdefer _ = view.lpVtbl.remove_WindowCloseRequested(view, data.cl_token);

            // Inject bridge JS
            BridgeImpl.setupUserContent(view);

            // Size controller to client area
            var client_rect: win32.RECT = undefined;
            _ = win32.GetClientRect(hwnd, &client_rect);
            _ = controller.putBounds(client_rect);
            _ = controller.putIsVisible(win32.TRUE);

            // Load initial URI
            const target_uri = try security.resolveWindowUrl(
                gpa,
                config.security,
                local,
                if (config.dev) |d| d.url else null,
                options.url,
                config.start,
            );
            defer gpa.free(target_uri);
            const target_uri_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, target_uri);
            defer gpa.free(target_uri_w);
            _ = view.navigate(target_uri_w.ptr);

            if (ShellMod.on_window_created_fn) |hook| {
                hook(hwnd);
                // A menu bar takes its height from the client area: grow the
                // window so the client area keeps the requested size (as on
                // GTK), then size the webview (the WM_SIZE this causes is
                // ignored until the window is registered).
                if (win32.GetMenu(hwnd) != null) {
                    var outer = win32.RECT{ .left = 0, .top = 0, .right = options.width, .bottom = options.height };
                    if (win32.AdjustWindowRectEx(&outer, style, win32.TRUE, win32.WS_EX_APPWINDOW) != win32.FALSE) {
                        _ = win32.SetWindowPos(hwnd, null, 0, 0, outer.right - outer.left, outer.bottom - outer.top, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                    }
                }
                var client: win32.RECT = undefined;
                if (win32.GetClientRect(hwnd, &client) != win32.FALSE) {
                    _ = controller.putBounds(client);
                }
            }

            _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
            _ = win32.SetForegroundWindow(hwnd);

            const handle = WindowHandle{
                .hwnd = hwnd,
                .controller = controller,
                .webview = view,
                .data = data,
                .deinit_fn = &WindowData.deinitTypeErased,
            };
            win_inst.handle = handle;
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(win_inst)));

            return handle;
        }

        fn wndProc(hwnd: win32.HWND, uMsg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
            const win = getWindowByHwnd(hwnd);

            switch (uMsg) {
                win32.WM_SIZE => {
                    if (win) |w| {
                        if (!w.ready) return 0;
                        var bounds: win32.RECT = undefined;
                        _ = win32.GetClientRect(hwnd, &bounds);
                        _ = w.handle.controller.putBounds(bounds);
                    }
                    return 0;
                },
                win32.WM_DPICHANGED => {
                    if (win) |w| {
                        if (!w.ready) return 0;
                        _ = w.handle.controller.notifyParentWindowPositionChanged();
                        var bounds: win32.RECT = undefined;
                        _ = win32.GetClientRect(hwnd, &bounds);
                        _ = w.handle.controller.putBounds(bounds);
                    }
                    return 0;
                },
                win32.WM_CLOSE => {
                    if (win) |w| {
                        if (!w.ready) {
                            w.pending_close = true;
                            return 0;
                        }
                        if (std.mem.eql(u8, w.label, "main") and config.on_close == .hide) {
                            _ = win32.ShowWindow(hwnd, win32.SW_HIDE);
                            return 0;
                        }

                        w.saveGeometry();

                        App.ensureWindowsMutex();
                        App.windows_mutex.lock();
                        for (App.windows_list.items, 0..) |item, i| {
                            if (item == w) {
                                _ = App.windows_list.swapRemove(i);
                                break;
                            }
                        }
                        const remaining = App.windows_list.items.len;
                        App.windows_mutex.unlock();

                        // Clear GWLP_USERDATA before freeing w or destroying window
                        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);

                        w.handle.deinit();

                        std.heap.smp_allocator.free(w.label);
                        std.heap.smp_allocator.free(w.options.title);
                        std.heap.smp_allocator.destroy(w);

                        _ = win32.DestroyWindow(hwnd);
                        if (ShellMod.main_hwnd == hwnd) ShellMod.main_hwnd = null;

                        if (remaining == 0) {
                            App.quit(0);
                        }
                        return 0;
                    }
                    return 0;
                },
                win32.WM_COMMAND => {
                    ShellMod.handleMenuCommand(wParam);
                    return 0;
                },
                win32.WM_DESTROY => {
                    return 0;
                },
                else => return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam),
            }
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
