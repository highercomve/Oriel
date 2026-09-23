//! System-wide hotkeys.
//!
//! - Wayland: org.freedesktop.portal.GlobalShortcuts (over GDBus).
//! - X11: XGrabKey + event watch on X connection fd in the GLib main loop.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const ziguri = @import("../ziguri.zig");

pub const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
});

pub const Modifiers = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
};

pub const Shortcut = struct {
    id: []const u8,
    description: []const u8 = "",
    trigger: []const u8,
};

pub const ParsedTrigger = struct {
    modifiers: Modifiers,
    key: []const u8,
};

pub const Callback = *const fn (id: []const u8) void;

pub const Registered = struct {
    shortcut: Shortcut,
    callback: Callback,
    keycode: u8 = 0,
    mask: c_uint = 0,
};

var shortcuts: std.ArrayList(Registered) = .empty;
var x11_display: ?*x11.Display = null;
var x11_source_id: c_uint = 0;
var dbus_conn: ?*gio.DBusConnection = null;
var portal_sub_id: c_ulong = 0;

/// Parse an accelerator trigger string like "CTRL+ALT+G" or "super+shift+Space".
pub fn parseTrigger(trigger_str: []const u8) !ParsedTrigger {
    var it = std.mem.splitScalar(u8, trigger_str, '+');
    var mods = Modifiers{};
    var key: ?[]const u8 = null;

    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;

        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            mods.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt")) {
            mods.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            mods.shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "super") or std.ascii.eqlIgnoreCase(part, "meta") or std.ascii.eqlIgnoreCase(part, "win") or std.ascii.eqlIgnoreCase(part, "cmd")) {
            mods.super = true;
        } else {
            if (key != null) return error.MultipleKeysInTrigger;
            key = part;
        }
    }

    const final_key = key orelse return error.NoKeyInTrigger;
    return .{
        .modifiers = mods,
        .key = final_key,
    };
}

/// Version of the GlobalShortcuts portal, or null when no backend provides it.
pub fn portalVersion() !?u32 {
    var err: ?*glib.Error = null;
    const proxy = gio.DBusProxy.newForBusSync(
        .session,
        .{},
        null,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        null,
        &err,
    ) orelse {
        if (err) |e| e.free();
        return error.PortalProxy;
    };
    defer proxy.unref();
    const version = proxy.getCachedProperty("version") orelse return null;
    defer version.unref();
    return version.getUint32();
}

pub fn x11Available() bool {
    const display = x11.XOpenDisplay(null) orelse return false;
    _ = x11.XCloseDisplay(display);
    return true;
}

fn initX11() !*x11.Display {
    if (x11_display) |d| return d;
    const d = x11.XOpenDisplay(null) orelse return error.XOpenDisplay;
    x11_display = d;

    const fd = x11.ConnectionNumber(d);
    const channel = glib.IOChannel.unixNew(fd);
    defer channel.unref();
    x11_source_id = glib.ioAddWatch(channel, .{ .@"in" = true }, &onX11Data, null);
    return d;
}

fn onX11Data(_: *glib.IOChannel, _: glib.IOCondition, _: ?*anyopaque) callconv(.c) c_int {
    const disp = x11_display orelse return 0;
    while (x11.XPending(disp) > 0) {
        var ev: x11.XEvent = undefined;
        _ = x11.XNextEvent(disp, &ev);
        if (ev.type == x11.KeyPress) {
            const keycode = @as(u8, @intCast(ev.xkey.keycode));
            const state = ev.xkey.state & (x11.ControlMask | x11.Mod1Mask | x11.ShiftMask | x11.Mod4Mask);
            for (shortcuts.items) |entry| {
                if (entry.keycode == keycode and entry.mask == state) {
                    entry.callback(entry.shortcut.id);
                }
            }
        }
    }
    return 1;
}

/// Register a global shortcut. Calls `callback` on the main thread when activated.
pub fn register(gpa: std.mem.Allocator, shortcut: Shortcut, callback: Callback) !void {
    const parsed = try parseTrigger(shortcut.trigger);

    // If Wayland session is active and portal is available, register with portal.
    const is_wayland = std.c.getenv("WAYLAND_DISPLAY") != null;
    if (is_wayland) {
        if (portalVersion() catch null) |_| {
            try initPortal();
            try shortcuts.append(gpa, .{
                .shortcut = shortcut,
                .callback = callback,
            });
            return;
        }
    }

    // Otherwise use X11 / XGrabKey.
    const disp = try initX11();
    var mask: c_uint = 0;
    if (parsed.modifiers.ctrl) mask |= x11.ControlMask;
    if (parsed.modifiers.alt) mask |= x11.Mod1Mask;
    if (parsed.modifiers.shift) mask |= x11.ShiftMask;
    if (parsed.modifiers.super) mask |= x11.Mod4Mask;

    var key_buf: [64]u8 = undefined;
    const key_z = try std.fmt.bufPrintSentinel(&key_buf, "{s}", .{parsed.key}, 0);
    var sym = x11.XStringToKeysym(key_z.ptr);
    if (sym == 0 and parsed.key.len == 1) {
        sym = parsed.key[0];
    }
    if (sym == 0) return error.UnknownKey;

    const kc = x11.XKeysymToKeycode(disp, sym);
    if (kc == 0) return error.KeycodeNotFound;

    const root = x11.XDefaultRootWindow(disp);
    const masks = [_]c_uint{
        mask,
        mask | x11.LockMask,
        mask | x11.Mod2Mask,
        mask | x11.LockMask | x11.Mod2Mask,
    };
    for (masks) |m| {
        _ = x11.XGrabKey(disp, kc, m, root, 1, x11.GrabModeAsync, x11.GrabModeAsync);
    }
    _ = x11.XFlush(disp);

    try shortcuts.append(gpa, .{
        .shortcut = shortcut,
        .callback = callback,
        .keycode = kc,
        .mask = mask,
    });
}

/// Manually trigger a registered shortcut by ID (useful in tests and dev mode).
pub fn trigger(id: []const u8) bool {
    for (shortcuts.items) |entry| {
        if (std.mem.eql(u8, entry.shortcut.id, id)) {
            entry.callback(id);
            return true;
        }
    }
    return false;
}

/// Unregister a shortcut by its ID.
pub fn unregister(id: []const u8) bool {
    for (shortcuts.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.shortcut.id, id)) {
            if (x11_display) |disp| {
                if (entry.keycode != 0) {
                    const root = x11.XDefaultRootWindow(disp);
                    const masks = [_]c_uint{
                        entry.mask,
                        entry.mask | x11.LockMask,
                        entry.mask | x11.Mod2Mask,
                        entry.mask | x11.LockMask | x11.Mod2Mask,
                    };
                    for (masks) |m| {
                        _ = x11.XUngrabKey(disp, entry.keycode, m, root);
                    }
                    _ = x11.XFlush(disp);
                }
            }
            _ = shortcuts.swapRemove(i);
            return true;
        }
    }
    return false;
}

/// Clean up registered shortcuts and release X11 resources.
pub fn deinit(gpa: std.mem.Allocator) void {
    if (x11_display) |disp| {
        const root = x11.XDefaultRootWindow(disp);
        for (shortcuts.items) |entry| {
            if (entry.keycode != 0) {
                const masks = [_]c_uint{
                    entry.mask,
                    entry.mask | x11.LockMask,
                    entry.mask | x11.Mod2Mask,
                    entry.mask | x11.LockMask | x11.Mod2Mask,
                };
                for (masks) |m| {
                    _ = x11.XUngrabKey(disp, entry.keycode, m, root);
                }
            }
        }
        _ = x11.XFlush(disp);
        if (x11_source_id != 0) {
            _ = glib.Source.remove(x11_source_id);
            x11_source_id = 0;
        }
        _ = x11.XCloseDisplay(disp);
        x11_display = null;
    }
    shortcuts.deinit(gpa);
    shortcuts = .empty;
}

fn initPortal() !void {
    if (dbus_conn != null) return;
    var err: ?*glib.Error = null;
    const conn = gio.busGetSync(.session, null, &err) orelse {
        if (err) |e| e.free();
        return error.DBusConnection;
    };
    dbus_conn = conn;

    portal_sub_id = conn.signalSubscribe(
        "org.freedesktop.portal.Desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        "Activated",
        "/org/freedesktop/portal/desktop",
        null,
        .{},
        &onPortalActivated,
        null,
        null,
    );
}

fn onPortalActivated(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    _: ?*anyopaque,
) callconv(.c) void {
    // Parameters: (o session_handle, s shortcut_id, t timestamp, a{sv} options)
    const child = params.getChildValue(1);
    defer child.unref();
    var len: usize = 0;
    const str = child.getString(&len);
    _ = trigger(str[0..len]);
}

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    const portal = try portalVersion();
    const x = x11Available();
    var portal_buf: [32]u8 = undefined;

    // Verify X11 grab works if X11 is available
    var x11_ok = false;
    if (x) {
        if (x11.XOpenDisplay(null)) |disp| {
            defer _ = x11.XCloseDisplay(disp);
            const root = x11.XDefaultRootWindow(disp);
            const sym = x11.XStringToKeysym("F12");
            const kc = x11.XKeysymToKeycode(disp, sym);
            if (kc != 0) {
                _ = x11.XGrabKey(disp, kc, x11.ControlMask, root, 1, x11.GrabModeAsync, x11.GrabModeAsync);
                _ = x11.XUngrabKey(disp, kc, x11.ControlMask, root);
                _ = x11.XFlush(disp);
                x11_ok = true;
            }
        }
    }

    return .{
        .module = "global_shortcut",
        .ok = portal != null or x11_ok,
        .detail = try std.fmt.allocPrint(gpa, "GlobalShortcuts portal {s}; X11 XGrabKey {s}", .{
            if (portal) |v| try std.fmt.bufPrint(&portal_buf, "v{d}", .{v}) else "unavailable",
            if (x11_ok) "available" else "unavailable",
        }),
    };
}

test "parseTrigger accelerator parsing" {
    const p1 = try parseTrigger("CTRL+ALT+G");
    try std.testing.expect(p1.modifiers.ctrl);
    try std.testing.expect(p1.modifiers.alt);
    try std.testing.expect(!p1.modifiers.shift);
    try std.testing.expectEqualStrings("G", p1.key);

    const p2 = try parseTrigger("super+shift+Space");
    try std.testing.expect(p2.modifiers.super);
    try std.testing.expect(p2.modifiers.shift);
    try std.testing.expect(!p2.modifiers.ctrl);
    try std.testing.expectEqualStrings("Space", p2.key);

    const p3 = try parseTrigger("ctrl+v");
    try std.testing.expect(p3.modifiers.ctrl);
    try std.testing.expect(!p3.modifiers.alt);
    try std.testing.expectEqualStrings("v", p3.key);

    try std.testing.expectError(error.NoKeyInTrigger, parseTrigger("ctrl+alt"));
    try std.testing.expectError(error.MultipleKeysInTrigger, parseTrigger("ctrl+a+b"));
}

test "trigger registered shortcut" {
    const H = struct {
        var triggered: bool = false;
        fn cb(_: []const u8) void {
            triggered = true;
        }
    };
    try shortcuts.append(std.testing.allocator, .{
        .shortcut = .{ .id = "test_hotkey", .trigger = "ctrl+alt+t" },
        .callback = &H.cb,
    });
    defer shortcuts.deinit(std.testing.allocator);

    try std.testing.expect(trigger("test_hotkey"));
    try std.testing.expect(H.triggered);
    try std.testing.expect(!trigger("non_existent"));
}
