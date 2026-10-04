//! Desktop notifications via GNotification.
//!
//! Clicks and buttons activate the application action `app.oriel-notification`
//! with an `(ss)` target: the notification's id and the button's id ("" for a
//! click on the notification itself). A click on the notification also
//! presents the main window, as GApplication's default activation did.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const oriel = @import("../../oriel.zig");
const App = @import("../../core/App.zig");
const common = @import("common.zig");

pub const NotificationOptions = common.NotificationOptions;

const action_name = "oriel-notification";
var action_registered: std.atomic.Value(bool) = .init(false);

pub fn notify(options: NotificationOptions) !void {
    const app = App.gtk_app orelse return error.NoApp;
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

    // The action map belongs to the main thread; the action is only needed
    // once someone clicks, so registering it asynchronously is enough.
    if (!action_registered.swap(true, .acq_rel)) App.runOnMain({}, registerAction);

    const detailed = "app." ++ action_name;
    const id_text: [:0]const u8 = if (id_z) |z| z else "";
    notif.setDefaultActionAndTargetValue(detailed, target(id_text, ""));
    for (options.actions) |a| {
        var label_buf: [256]u8 = undefined;
        var aid_buf: [128]u8 = undefined;
        const label_z = try std.fmt.bufPrintSentinel(&label_buf, "{s}", .{a.label}, 0);
        const aid_z = try std.fmt.bufPrintSentinel(&aid_buf, "{s}", .{a.id}, 0);
        notif.addButtonWithTargetValue(label_z.ptr, detailed, target(id_text, aid_z));
    }

    const app_gapp: *gio.Application = @ptrCast(app);
    app_gapp.sendNotification(if (id_z) |p| p.ptr else null, notif);
}

fn target(id: [:0]const u8, action: [:0]const u8) *glib.Variant {
    var children = [_]*glib.Variant{ glib.Variant.newString(id.ptr), glib.Variant.newString(action.ptr) };
    return glib.Variant.newTuple(&children, children.len);
}

fn registerAction(_: void) void {
    const app = App.gtk_app orelse {
        action_registered.store(false, .release);
        return;
    };
    const action = gio.SimpleAction.new(action_name, glib.VariantType.new("(ss)"));
    defer action.unref();
    _ = gio.SimpleAction.signals.activate.connect(action, ?*anyopaque, &onActivate, null, .{});
    gio.ActionMap.addAction(app.as(gio.ActionMap), action.as(gio.Action));
}

fn onActivate(_: *gio.SimpleAction, parameter: ?*glib.Variant, _: ?*anyopaque) callconv(.c) void {
    const p = parameter orelse return;
    const id = childString(p, 0);
    const action = childString(p, 1);
    if (action.len == 0) if (App.main_window) |w| w.present();
    common.dispatch(id, if (action.len == 0) null else action);
}

fn childString(v: *glib.Variant, index: usize) []const u8 {
    const child = v.getChildValue(index);
    defer child.unref();
    // The string stays valid while `v` (which owns the child's data) lives.
    return std.mem.span(child.getString(null));
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const notif = gio.Notification.new("oriel check");
    defer notif.unref();
    notif.setBody("notification smoke check");
    notif.setDefaultActionAndTargetValue("app." ++ action_name, target("check", ""));
    notif.addButtonWithTargetValue("Open", "app." ++ action_name, target("check", "open"));
    return .{
        .module = "notification",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "GNotification available (click actions)", .{}),
    };
}

test "notification creation" {
    const notif = gio.Notification.new("test title");
    defer notif.unref();
    notif.setBody("test body");
    notif.addButtonWithTargetValue("Reply", "app." ++ action_name, target("id", "reply"));
}
