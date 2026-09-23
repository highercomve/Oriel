//! System-wide hotkeys.
//!
//! - Wayland: org.freedesktop.portal.GlobalShortcuts (over GDBus).
//! - X11: XGrabKey.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const ziguri = @import("../ziguri.zig");

pub const x11 = @cImport(@cInclude("X11/Xlib.h"));

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

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    const portal = try portalVersion();
    const x = x11Available();
    var portal_buf: [32]u8 = undefined;
    return .{
        .module = "global_shortcut",
        .ok = portal != null or x,
        .detail = try std.fmt.allocPrint(gpa, "GlobalShortcuts portal {s}; X11 XGrabKey {s}", .{
            if (portal) |v| try std.fmt.bufPrint(&portal_buf, "v{d}", .{v}) else "unavailable",
            if (x) "available" else "unavailable",
        }),
    };
}
