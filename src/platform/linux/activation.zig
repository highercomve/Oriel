//! Wayland window activation (xdg-activation-v1).
//!
//! A compositor that checks where an activation token comes from (GNOME,
//! KDE) brings a window forward only for a token tied to a user action;
//! without one, `gtk_window_present` asks for a token of its own, which such
//! a compositor refuses. GTK already hands a launcher's token
//! (`XDG_ACTIVATION_TOKEN`) from a later launch to the running instance;
//! `setPending` takes one from elsewhere, such as the tray host. The next
//! window presented or mapped spends it.

const std = @import("std");
const gdk = @import("gdk");

const log = std.log.scoped(.activation);

extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;

/// GDK's Wayland backend, looked up at run time: GTK can be built without it.
const Wayland = struct {
    display_get_type: *const fn () callconv(.c) usize,
    // Deprecated since GTK 4.10 but the one way to give GDK a token for the
    // next present; GtkApplication uses it for a launcher's token too.
    set_startup_notification_id: *const fn (display: *anyopaque, token: [*:0]const u8) callconv(.c) void,

    var cached: ?Wayland = null;
    var resolved = false;

    /// Main thread.
    fn get() ?*const Wayland {
        if (!resolved) {
            resolved = true;
            cached = resolve();
        }
        return if (cached) |*w| w else null;
    }

    fn sym(comptime T: type, name: [:0]const u8) ?T {
        const p = std.c.dlsym(null, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    fn resolve() ?Wayland {
        return .{
            .display_get_type = sym(@FieldType(Wayland, "display_get_type"), "gdk_wayland_display_get_type") orelse return null,
            .set_startup_notification_id = sym(@FieldType(Wayland, "set_startup_notification_id"), "gdk_wayland_display_set_startup_notification_id") orelse return null,
        };
    }
};

/// Use `token` (an xdg-activation token) for the next window presented or
/// mapped. A no-op off Wayland or for an empty token. Main thread.
pub fn setPending(token: [*:0]const u8) void {
    if (token[0] == 0) return;
    const display = gdk.Display.getDefault() orelse return;
    const w = Wayland.get() orelse return;
    const obj: *anyopaque = @ptrCast(display);
    if (g_type_check_instance_is_a(obj, w.display_get_type()) == 0) return;
    w.set_startup_notification_id(obj, token);
    log.debug("activation token received", .{});
}
