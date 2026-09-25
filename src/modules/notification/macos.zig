//! macOS notifications.
//!
//! Bundled app (`.app` with a bundle identifier): UNUserNotificationCenter.
//! Authorization is requested once, on the first notification; macOS shows
//! its permission prompt then. A denial makes later notifications silent,
//! as the system decides.
//!
//! Unbundled executable (`zig build run`, the dev build): UserNotifications
//! raises an Objective-C exception without a bundle identifier, so the
//! notification goes through `osascript` ("display notification") instead;
//! macOS attributes it to Script Editor. Title and body are passed as
//! arguments, never as script text.

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const ShellMod = @import("../../platform/macos/Shell.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const Object = cocoa.Object;
const c = std.c;
const log = std.log.scoped(.oriel);

pub const NotificationOptions = common.NotificationOptions;

/// Whether this process runs from an `.app` bundle with a bundle id.
fn bundled() bool {
    const bundle = cocoa.class("NSBundle").msgSend(Object, "mainBundle", .{});
    if (bundle.value == null) return false;
    if (bundle.msgSend(Object, "bundleIdentifier", .{}).value == null) return false;
    const path = cocoa.utf8(bundle.msgSend(Object, "bundlePath", .{})) orelse return false;
    return std.mem.endsWith(u8, path, ".app");
}

pub fn notify(options: NotificationOptions) !void {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    if (!bundled()) return notifyViaOsascript(options);
    var params: Params = .{ .options = options };
    try ShellMod.runOnMainThread(Params, &params, notifyBundled);
    if (params.err) |err| return err;
}

// --- UNUserNotificationCenter -------------------------------------------------

const Params = struct {
    options: NotificationOptions,
    err: ?anyerror = null,
};

var authorization_requested = false; // main thread only
var id_counter: std.atomic.Value(u32) = .init(1);

const AuthBlock = cocoa.objc.Block(struct {}, .{ cocoa.c.BOOL, cocoa.id }, void);

fn onAuthorization(_: *const AuthBlock.Context, granted: cocoa.c.BOOL, _: cocoa.id) callconv(.c) void {
    if (!cocoa.isTrue(granted)) log.warn("notifications are not allowed for this app (System Settings > Notifications)", .{});
}

fn notifyBundled(params: *Params) void {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    const center = cocoa.class("UNUserNotificationCenter").msgSend(Object, "currentNotificationCenter", .{});
    if (center.value == null) {
        params.err = error.NotificationCenterUnavailable;
        return;
    }
    if (!authorization_requested) {
        authorization_requested = true;
        const UNAuthorizationOptionSound: c_ulong = 1 << 1;
        const UNAuthorizationOptionAlert: c_ulong = 1 << 2;
        // The center copies the (stack) block before this call returns.
        var block = AuthBlock.init(.{}, &onAuthorization);
        center.msgSend(void, "requestAuthorizationWithOptions:completionHandler:", .{ UNAuthorizationOptionAlert | UNAuthorizationOptionSound, @as(cocoa.id, @ptrCast(&block)) });
    }

    const content = cocoa.new(cocoa.class("UNMutableNotificationContent"));
    defer content.release();
    const title = cocoa.nsString(params.options.title) orelse {
        params.err = error.InvalidUtf8;
        return;
    };
    defer title.release();
    content.msgSend(void, "setTitle:", .{title});
    if (params.options.body) |b| if (cocoa.nsString(b)) |body| {
        defer body.release();
        content.msgSend(void, "setBody:", .{body});
    };

    var id_buf: [32]u8 = undefined;
    const id_text = params.options.id orelse (std.fmt.bufPrint(&id_buf, "oriel-{d}", .{id_counter.fetchAdd(1, .monotonic)}) catch unreachable); // fits in 32 bytes
    const identifier = cocoa.nsString(id_text) orelse {
        params.err = error.InvalidUtf8;
        return;
    };
    defer identifier.release();
    const request = cocoa.class("UNNotificationRequest").msgSend(Object, "requestWithIdentifier:content:trigger:", .{ identifier, content, cocoa.nil });
    if (request.value == null) {
        params.err = error.NotificationCreateFailed;
        return;
    }
    center.msgSend(void, "addNotificationRequest:withCompletionHandler:", .{ request, cocoa.nil });
}

// --- osascript fallback ----------------------------------------------------------

extern var environ: [*:null]?[*:0]u8;
extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) ?*anyopaque;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: cocoa.DispatchFn) void;

fn notifyViaOsascript(options: NotificationOptions) !void {
    const gpa = std.heap.smp_allocator;
    const title = try gpa.dupeZ(u8, options.title);
    defer gpa.free(title);
    const body = try gpa.dupeZ(u8, options.body orelse "");
    defer gpa.free(body);
    const argv = [_:null]?[*:0]const u8{
        "/usr/bin/osascript",
        "-e",
        "on run argv",
        "-e",
        "display notification (item 2 of argv) with title (item 1 of argv)",
        "-e",
        "end run",
        // End of options: a title starting with '-' would otherwise be
        // parsed as another option (e.g. `-e <script>`).
        "--",
        title.ptr,
        body.ptr,
    };
    var pid: c.pid_t = undefined;
    const rc = c.posix_spawn(&pid, argv[0].?, null, null, &argv, @ptrCast(environ));
    if (rc != 0) return error.NotifyFailed;
    // Reap it off the calling thread (osascript returns quickly).
    const queue = dispatch_get_global_queue(0, 0) orelse return;
    dispatch_async_f(queue, @ptrFromInt(@as(usize, @intCast(pid))), &reap);
}

fn reap(ctx: ?*anyopaque) callconv(.c) void {
    const pid: c.pid_t = @intCast(@intFromPtr(ctx));
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    if (status != 0) log.warn("osascript notification exited with status {d}", .{status});
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    if (bundled()) {
        const ok = cocoa.objc.getClass("UNUserNotificationCenter") != null;
        return .{
            .module = "notification",
            .ok = ok,
            .detail = if (ok) "bundled app: UNUserNotificationCenter (asks for permission on first use)" else "UserNotifications framework missing",
        };
    }
    const ok = c.access("/usr/bin/osascript", 1) == 0; // X_OK
    return .{
        .module = "notification",
        .ok = ok,
        .detail = try std.fmt.allocPrint(gpa, "unbundled executable: notifications via osascript (shown as Script Editor){s}", .{if (ok) "" else "; /usr/bin/osascript missing"}),
    };
}

test {
    std.testing.refAllDecls(@This());
}
