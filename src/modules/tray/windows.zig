//! Windows system tray implementation (Shell_NotifyIconW + TrackPopupMenu).

const std = @import("std");
const zigimg = @import("zigimg");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const window = @import("../../platform/windows/window.zig");
const App = @import("../../core/App.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;

var next_uid: std.atomic.Value(win32.UINT) = .init(1001);
var global_tray: ?*Tray = null;

pub const Tray = struct {
    gpa: std.mem.Allocator,
    menu: Menu,
    strings: std.heap.ArenaAllocator,
    id: [:0]const u8,
    title: [:0]const u8,
    tooltip: [:0]const u8,
    hicon: ?win32.HICON,
    nid: win32.NOTIFYICONDATAW,
    on_menu: ?*const fn (id: []const u8, checked: ?bool) void,
    on_activate: ?*const fn () void,
    uid: win32.UINT,

    pub fn create(gpa: std.mem.Allocator, options: Options) !*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);

        self.* = .{
            .gpa = gpa,
            .menu = Menu.init(gpa),
            .strings = std.heap.ArenaAllocator.init(gpa),
            .id = "",
            .title = "",
            .tooltip = "",
            .hicon = null,
            .nid = std.mem.zeroes(win32.NOTIFYICONDATAW),
            .on_menu = options.on_menu,
            .on_activate = options.on_activate,
            .uid = next_uid.fetchAdd(1, .monotonic),
        };
        errdefer self.menu.deinit();
        errdefer self.strings.deinit();

        const a = self.strings.allocator();
        self.id = try a.dupeZ(u8, options.id);
        self.title = try a.dupeZ(u8, options.title);
        self.tooltip = try a.dupeZ(u8, options.tooltip);

        self.hicon = createIcon(gpa, options.icon) catch |err| {
            return err;
        };
        errdefer if (self.hicon) |h| {
            _ = win32.DestroyIcon(h);
        };

        try self.menu.set(options.menu);

        // The shell's host window outlives every app window, so the icon (which
        // Windows removes with its owner window) survives closing the main window.
        const target_hwnd = ShellMod.host_hwnd orelse return error.AppNotRunning;

        self.nid.cbSize = @sizeOf(win32.NOTIFYICONDATAW);
        self.nid.hWnd = target_hwnd;
        self.nid.uID = self.uid;
        self.nid.uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP;
        self.nid.uCallbackMessage = ShellMod.WM_TRAY_CALLBACK;
        self.nid.hIcon = self.hicon;

        @memset(&self.nid.szTip, 0);
        const tip_w = try std.unicode.utf8ToUtf16LeAllocZ(a, self.tooltip);
        const copy_len = @min(tip_w.len, self.nid.szTip.len - 1);
        @memcpy(self.nid.szTip[0..copy_len], tip_w[0..copy_len]);

        if (win32.Shell_NotifyIconW(win32.NIM_ADD, &self.nid) == win32.FALSE) {
            return error.ShellNotifyIconFailed;
        }
        errdefer _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &self.nid);

        self.nid.uTimeoutOrVersion = win32.NOTIFYICON_VERSION_4;
        _ = win32.Shell_NotifyIconW(win32.NIM_SETVERSION, &self.nid);

        global_tray = self;
        ShellMod.on_tray_message_fn = &handleTrayCallback;

        return self;
    }

    pub fn deinit(self: *Tray) void {
        if (self.nid.hWnd != null) {
            _ = win32.Shell_NotifyIconW(win32.NIM_DELETE, &self.nid);
        }
        if (self.hicon) |h| {
            _ = win32.DestroyIcon(h);
            self.hicon = null;
        }
        if (global_tray == self) {
            global_tray = null;
            ShellMod.on_tray_message_fn = null;
        }
        self.menu.deinit();
        self.strings.deinit();
        self.gpa.destroy(self);
    }

    pub fn setMenu(self: *Tray, items: []const MenuItem) !void {
        try self.menu.set(items);
    }

    pub fn setChecked(self: *Tray, id: []const u8, checked: bool) void {
        const n = self.menu.find(id) orelse return;
        n.checked = checked;
        self.menu.revision +%= 1;
    }

    pub fn isChecked(self: *Tray, id: []const u8) ?bool {
        const n = self.menu.find(id) orelse return null;
        return if (n.kind == .check) n.checked else null;
    }

    pub fn setTooltip(self: *Tray, tooltip: []const u8) !void {
        const a = self.strings.allocator();
        self.tooltip = try a.dupeZ(u8, tooltip);
        const tip_w = try std.unicode.utf8ToUtf16LeAllocZ(a, self.tooltip);
        @memset(&self.nid.szTip, 0);
        const copy_len = @min(tip_w.len, self.nid.szTip.len - 1);
        @memcpy(self.nid.szTip[0..copy_len], tip_w[0..copy_len]);
        self.nid.uFlags = win32.NIF_TIP;
        if (self.nid.hWnd != null) {
            _ = win32.Shell_NotifyIconW(win32.NIM_MODIFY, &self.nid);
        }
    }

    pub fn setTitle(self: *Tray, title: []const u8) !void {
        self.title = try self.strings.allocator().dupeZ(u8, title);
    }

    pub fn setIcon(self: *Tray, icon: Icon) !void {
        const new_icon = try createIcon(self.gpa, icon);
        if (self.hicon) |old| _ = win32.DestroyIcon(old);
        self.hicon = new_icon;
        self.nid.hIcon = new_icon;
        self.nid.uFlags = win32.NIF_ICON;
        if (self.nid.hWnd != null) {
            _ = win32.Shell_NotifyIconW(win32.NIM_MODIFY, &self.nid);
        }
    }

    fn showContextMenu(self: *Tray, x: i16, y: i16) void {
        const hwnd = self.nid.hWnd orelse return;
        const hmenu = win32.CreatePopupMenu() orelse return;
        defer _ = win32.DestroyMenu(hmenu);

        self.populateMenu(hmenu, 0);

        var pt = win32.POINT{ .x = x, .y = y };
        if (pt.x == 0 and pt.y == 0) {
            _ = win32.GetCursorPos(&pt);
        }
        _ = win32.SetForegroundWindow(hwnd);
        const uid = self.uid;
        const cmd = win32.TrackPopupMenu(hmenu, win32.TPM_RIGHTBUTTON | win32.TPM_RETURNCMD, pt.x, pt.y, 0, hwnd, null);
        _ = win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0);

        // TrackPopupMenu runs a modal message loop: a dispatched task may have
        // deinit()ed this tray meanwhile. uids are never reused, so only touch
        // `self` if it is still the live tray.
        const live = global_tray orelse return;
        if (live != self or live.uid != uid) return;

        if (cmd > 0) {
            const child_id: i32 = @intCast(cmd);
            if (self.menu.node(child_id)) |n| {
                if (n.kind == .check) {
                    n.checked = !n.checked;
                    self.menu.revision +%= 1;
                }
                if (self.on_menu) |f| {
                    // `n.key` lives in the menu arena: copy it in case on_menu calls setMenu.
                    var key_buf: [256]u8 = undefined;
                    f(common.copyKey(&key_buf, n.key), if (n.kind == .check) n.checked else null);
                }
            }
        }
    }

    fn populateMenu(self: *Tray, hmenu: win32.HMENU, parent_id: i32) void {
        const parent = self.menu.node(parent_id) orelse return;
        const a = self.strings.allocator();
        for (parent.children) |child_id| {
            const child = self.menu.node(child_id) orelse continue;
            switch (child.kind) {
                .separator => {
                    _ = win32.AppendMenuW(hmenu, win32.MF_SEPARATOR, 0, null);
                },
                .submenu => {
                    const label_w = std.unicode.utf8ToUtf16LeAllocZ(a, child.label) catch continue;
                    defer a.free(label_w);
                    const hsub = win32.CreatePopupMenu() orelse continue;
                    self.populateMenu(hsub, child_id);
                    var flags: win32.UINT = win32.MF_POPUP;
                    if (!child.enabled) flags |= win32.MF_GRAYED | win32.MF_DISABLED;
                    // Once appended, hsub is destroyed with its parent menu;
                    // otherwise it is ours to destroy.
                    if (win32.AppendMenuW(hmenu, flags, @intFromPtr(hsub), label_w.ptr) == win32.FALSE) {
                        _ = win32.DestroyMenu(hsub);
                    }
                },
                .check => {
                    var flags: win32.UINT = win32.MF_STRING;
                    if (!child.enabled) flags |= win32.MF_GRAYED | win32.MF_DISABLED;
                    if (child.checked) flags |= win32.MF_CHECKED;
                    const label_w = std.unicode.utf8ToUtf16LeAllocZ(a, child.label) catch continue;
                    defer a.free(label_w);
                    _ = win32.AppendMenuW(hmenu, flags, @intCast(child_id), label_w.ptr);
                },
                .item => {
                    var flags: win32.UINT = win32.MF_STRING;
                    if (!child.enabled) flags |= win32.MF_GRAYED | win32.MF_DISABLED;
                    const label_w = std.unicode.utf8ToUtf16LeAllocZ(a, child.label) catch continue;
                    defer a.free(label_w);
                    _ = win32.AppendMenuW(hmenu, flags, @intCast(child_id), label_w.ptr);
                },
                .root => {},
            }
        }
    }
};

fn handleTrayCallback(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    const self = global_tray orelse return;
    const decoded_lp = common.decodeTrayLParam(lParam);
    if (decoded_lp.icon_id != self.uid) return;

    switch (decoded_lp.event) {
        win32.WM_LBUTTONUP, win32.NIN_SELECT, win32.NIN_KEYSELECT => {
            if (self.on_activate) |act| {
                act();
            } else {
                App.toggleWindow();
            }
        },
        win32.WM_RBUTTONUP, win32.WM_CONTEXTMENU => {
            const anchor = common.decodeTrayWParam(wParam);
            self.showContextMenu(anchor.x, anchor.y);
        },
        else => {},
    }
}

fn createIcon(gpa: std.mem.Allocator, icon: Icon) !win32.HICON {
    switch (icon) {
        .png => |bytes| {
            // First try direct PNG creation supported in Windows Vista+
            if (win32.CreateIconFromResourceEx(bytes.ptr, @intCast(bytes.len), win32.TRUE, 0x00030000, 0, 0, 0)) |h| {
                return h;
            }
            // Fallback: decode PNG with zigimg and create HICON via CreateIconIndirect
            var img = zigimg.Image.fromMemory(gpa, bytes) catch return error.InvalidIcon;
            defer img.deinit(gpa);

            img.convert(gpa, .rgba32) catch return error.InvalidIcon;
            const width: c_int = @intCast(img.width);
            const height: c_int = @intCast(img.height);
            const pixels = img.pixels.rgba32;

            var bgra = try gpa.alloc(u8, pixels.len * 4);
            defer gpa.free(bgra);
            for (pixels, 0..) |p, i| {
                bgra[i * 4 + 0] = p.b;
                bgra[i * 4 + 1] = p.g;
                bgra[i * 4 + 2] = p.r;
                bgra[i * 4 + 3] = p.a;
            }

            const hbmColor = win32.CreateBitmap(width, height, 1, 32, bgra.ptr) orelse return error.CreateBitmapFailed;
            defer _ = win32.DeleteObject(hbmColor);

            const mask_pitch = ((@as(usize, @intCast(width)) + 31) / 32) * 4;
            const mask_bytes = try gpa.alloc(u8, mask_pitch * @as(usize, @intCast(height)));
            defer gpa.free(mask_bytes);
            @memset(mask_bytes, 0);

            const hbmMask = win32.CreateBitmap(width, height, 1, 1, mask_bytes.ptr) orelse return error.CreateBitmapFailed;
            defer _ = win32.DeleteObject(hbmMask);

            var ii = win32.ICONINFO{
                .fIcon = win32.TRUE,
                .xHotspot = 0,
                .yHotspot = 0,
                .hbmMask = hbmMask,
                .hbmColor = hbmColor,
            };

            return win32.CreateIconIndirect(&ii) orelse error.CreateIconFailed;
        },
        .name => return error.NamedIconsNotSupportedOnWindows,
    }
}

pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    var menu: Menu = .init(gpa);
    defer menu.deinit();
    try menu.set(&.{
        .{ .item = .{ .id = "show", .label = "Show" } },
        .separator,
        .{ .item = .{ .id = "quit", .label = "Quit" } },
    });
    return .{
        .module = "tray",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Win32 Shell_NotifyIconW with {d} menu items; icon {d} B PNG", .{
            menu.nodes.items.len - 1,
            ctx.icon_png.len,
        }),
    };
}

test {
    std.testing.refAllDecls(@This());
}
