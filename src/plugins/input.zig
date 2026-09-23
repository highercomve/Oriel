//! Synthetic keyboard input into other apps.
//!
//! - wlroots compositors (Hyprland, Sway…): zwp_virtual_keyboard_v1, which
//!   needs an XKB keymap from libxkbcommon.
//! - X11: XTest.
//! - GNOME/KDE Wayland: libei via the RemoteDesktop portal (not wired yet).

const std = @import("std");
const wayland = @import("wayland");
const zwp = wayland.client.zwp;
const Globals = @import("wayland_globals.zig").Globals;
const ziguri = @import("../ziguri.zig");

pub const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));
pub const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/extensions/XTest.h");
});

/// The default XKB keymap as text, ready to hand to the virtual keyboard.
pub fn defaultKeymap(gpa: std.mem.Allocator) ![]u8 {
    const ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContext;
    defer xkb.xkb_context_unref(ctx);
    const keymap = xkb.xkb_keymap_new_from_names(ctx, null, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymap;
    defer xkb.xkb_keymap_unref(keymap);
    const text = xkb.xkb_keymap_get_as_string(keymap, xkb.XKB_KEYMAP_FORMAT_TEXT_V1) orelse return error.XkbKeymapString;
    defer std.c.free(text);
    return gpa.dupe(u8, std.mem.span(text));
}

/// Whether the X server (or XWayland) supports XTest.
pub fn xtestAvailable() bool {
    const display = x11.XOpenDisplay(null) orelse return false;
    defer _ = x11.XCloseDisplay(display);
    var ev: c_int = 0;
    var er: c_int = 0;
    var major: c_int = 0;
    var minor: c_int = 0;
    return x11.XTestQueryExtension(display, &ev, &er, &major, &minor) != 0;
}

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    const keymap = try defaultKeymap(gpa);
    defer gpa.free(keymap);

    var globals: Globals = undefined;
    const wayland_ok = if (globals.init(gpa)) |_| true else |_| false;
    defer if (wayland_ok) globals.deinit();

    var vk_bound = false;
    if (wayland_ok) {
        if (try globals.bind(zwp.VirtualKeyboardManagerV1, 1)) |manager| {
            vk_bound = true;
            manager.destroy();
        }
    }
    const xtest = xtestAvailable();

    return .{
        .module = "input",
        .ok = vk_bound or xtest,
        .detail = try std.fmt.allocPrint(gpa, "xkbcommon keymap {d} B; zwp_virtual_keyboard_manager_v1 {s}; XTest {s}", .{
            keymap.len,
            if (vk_bound) "bound" else if (wayland_ok) "not offered" else "no Wayland session",
            if (xtest) "available" else "unavailable",
        }),
    };
}
