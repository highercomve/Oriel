//! Notifications through `NotificationManagerCompat`, on the runtime's
//! "Oriel" channel. Android 13+ needs the notifications permission
//! (`.permissions = .{ .notifications = "..." }`, then
//! `permissions.request(.notifications)`); without it `notify` fails.
//! A notification with the same `id` replaces the previous one. A tap opens
//! the app and reports a click; buttons (at most 3) report theirs without
//! opening it and dismiss the notification. Clicks arrive while the app runs.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const heap = @import("../../core/heap.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

pub const NotificationOptions = common.NotificationOptions;

pub fn notify(options: NotificationOptions) !void {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(heap.gpa);
    for (options.actions) |a| try lines.print(heap.gpa, "{s}\t{s}\n", .{ a.id, a.label });
    const Ctx = struct {
        options: NotificationOptions,
        actions: ?[]const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "notify", "([B[B[B[B)Z", .{
                self.options.id,
                self.options.title,
                self.options.body,
                self.actions,
            }) orelse false;
        }
    };
    var ctx: Ctx = .{ .options = options, .actions = if (lines.items.len > 0) lines.items else null };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.NotificationFailed;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const Ctx = struct {
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "notificationsEnabled", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
    return .{
        .module = "notification",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "NotificationManager available; notifications {s}", .{if (ctx.ok) "enabled" else "disabled (permission not granted)"}),
    };
}
