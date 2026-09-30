//! iOS notifications: UNUserNotificationCenter. Authorization is requested
//! on the first notification (the system prompt shows then) unless the app
//! asked already (`permissions.request(.notifications)`); a denial makes
//! later notifications silent, as the system decides. Notifications also
//! show while the app is in front (the center's delegate asks for a banner).

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const ShellMod = @import("../../platform/ios/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = apple.Object;
const log = std.log.scoped(.oriel);

pub const NotificationOptions = common.NotificationOptions;

pub fn notify(options: NotificationOptions) !void {
    var params: Params = .{ .options = options };
    try ShellMod.runOnMainThread(Params, &params, notifyNow);
    if (params.err) |err| return err;
}

const Params = struct {
    options: NotificationOptions,
    err: ?anyerror = null,
};

var authorization_requested = false; // main thread only
var id_counter: std.atomic.Value(u32) = .init(1);
var center_delegate: Object = apple.nil;

fn onAuthorization(_: *apple.ContextBlock, granted: apple.c.BOOL, _: apple.id) callconv(.c) void {
    if (!apple.isTrue(granted)) log.warn("notifications are not allowed for this app (Settings > Notifications)", .{});
}

// UNNotificationPresentationOptions
const present_sound: c_ulong = 1 << 1;
const present_list: c_ulong = 1 << 3;
const present_banner: c_ulong = 1 << 4;

fn willPresent(_: apple.id, _: apple.c.SEL, _: apple.id, _: apple.id, handler: apple.id) callconv(.c) void {
    apple.callBlock(handler, &.{c_ulong}, .{present_banner | present_list | present_sound});
}

fn notifyNow(params: *Params) void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const center = apple.class("UNUserNotificationCenter").msgSend(Object, "currentNotificationCenter", .{});
    if (center.value == null) {
        params.err = error.NotificationCenterUnavailable;
        return;
    }
    if (center_delegate.value == null) {
        // The center's delegate is weak: this one lives for the process.
        center_delegate = apple.new(apple.defineClass("OrielNotificationDelegate", &.{"UNUserNotificationCenterDelegate"}, .{
            .{ "userNotificationCenter:willPresentNotification:withCompletionHandler:", willPresent },
        }));
        center.msgSend(void, "setDelegate:", .{center_delegate});
    }
    if (!authorization_requested) {
        authorization_requested = true;
        const UNAuthorizationOptionSound: c_ulong = 1 << 1;
        const UNAuthorizationOptionAlert: c_ulong = 1 << 2;
        // The center copies the (stack) block before this call returns.
        var block = apple.contextBlock(onAuthorization, null);
        center.msgSend(void, "requestAuthorizationWithOptions:completionHandler:", .{ UNAuthorizationOptionAlert | UNAuthorizationOptionSound, block.ptr() });
    }

    const content = apple.new(apple.class("UNMutableNotificationContent"));
    defer content.release();
    const title = apple.nsString(params.options.title) orelse {
        params.err = error.InvalidUtf8;
        return;
    };
    defer title.release();
    content.msgSend(void, "setTitle:", .{title});
    if (params.options.body) |b| if (apple.nsString(b)) |body| {
        defer body.release();
        content.msgSend(void, "setBody:", .{body});
    };

    var id_buf: [32]u8 = undefined;
    const id_text = params.options.id orelse (std.fmt.bufPrint(&id_buf, "oriel-{d}", .{id_counter.fetchAdd(1, .monotonic)}) catch unreachable); // fits in 32 bytes
    const identifier = apple.nsString(id_text) orelse {
        params.err = error.InvalidUtf8;
        return;
    };
    defer identifier.release();
    const request = apple.class("UNNotificationRequest").msgSend(Object, "requestWithIdentifier:content:trigger:", .{ identifier, content, apple.nil });
    if (request.value == null) {
        params.err = error.NotificationCreateFailed;
        return;
    }
    center.msgSend(void, "addNotificationRequest:withCompletionHandler:", .{ request, apple.nil });
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const ok = apple.objc.getClass("UNUserNotificationCenter") != null;
    return .{
        .module = "notification",
        .ok = ok,
        .detail = if (ok) "UNUserNotificationCenter (asks for permission on first use)" else "UserNotifications framework missing",
    };
}
