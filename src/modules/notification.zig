//! Desktop notifications via GNotification.

const std = @import("std");
const gio = @import("gio");
const oriel = @import("../oriel.zig");

pub const NotificationOptions = struct {
    id: ?[]const u8 = null,
    title: []const u8,
    body: ?[]const u8 = null,
};

pub fn notify(options: NotificationOptions) !void {
    const app = oriel.App.gtk_app orelse return error.NoApp;
    var title_buf: [256]u8 = undefined;
    const title_z = try std.fmt.bufPrintSentinel(&title_buf, "{s}", .{options.title}, 0);
    const notif = gio.Notification.new(title_z.ptr);
    defer notif.unref();

    if (options.body) |body| {
        var body_buf: [1024]u8 = undefined;
        const body_z = try std.fmt.bufPrintSentinel(&body_buf, "{s}", .{body}, 0);
        notif.setBody(body_z.ptr);
    }

    var id_buf: [128]u8 = undefined;
    const id_z = if (options.id) |id|
        try std.fmt.bufPrintSentinel(&id_buf, "{s}", .{id}, 0)
    else
        null;

    const app_gapp: *gio.Application = @ptrCast(app);
    app_gapp.sendNotification(if (id_z) |p| p.ptr else null, notif);
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const notif = gio.Notification.new("oriel check");
    defer notif.unref();
    notif.setBody("notification smoke check");
    return .{
        .module = "notification",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "GNotification available", .{}),
    };
}

test "notification creation" {
    const notif = gio.Notification.new("test title");
    defer notif.unref();
    notif.setBody("test body");
}
