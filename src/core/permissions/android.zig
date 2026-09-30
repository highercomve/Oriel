//! Android runtime permissions (`ContextCompat.checkSelfPermission`,
//! `ActivityCompat.requestPermissions`), through the Kotlin runtime:
//! - microphone: RECORD_AUDIO; camera: CAMERA; location: ACCESS_FINE_LOCATION.
//! - notifications: POST_NOTIFICATIONS (Android 13+; granted before).
//! - screen_capture, system_audio: MediaProjection asks the user every
//!   session, so they are always `prompt`.
//! - accessibility: an accessibility service the user enables in Settings;
//!   `granted` once it is on.
//! The manifest must declare them: `oriel android init` writes the
//! `<uses-permission>` entries from build.zig's `.permissions`.

const std = @import("std");
const common = @import("common.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const jni = @import("../../platform/android/jni.zig");

// OrielRuntime.permissionStatus results.
fn fromJava(v: i32) common.Status {
    return switch (v) {
        0 => .granted,
        1 => .denied,
        2 => .prompt,
        else => .unknown,
    };
}

fn statusNow(kind: *common.Kind) common.Status {
    return fromJava(runtime.call(.int, "permissionStatus", "(I)I", .{@as(i32, @intFromEnum(kind.*))}) orelse 3);
}

pub fn status(kind: common.Kind) common.Status {
    var k = kind;
    if (ShellMod.isMainThread()) return statusNow(&k);
    const Ctx = struct {
        kind: common.Kind,
        out: common.Status = .unknown,
        fn run(self: *@This()) void {
            var kk = self.kind;
            self.out = statusNow(&kk);
        }
    };
    var ctx: Ctx = .{ .kind = kind };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return .unknown;
    return ctx.out;
}

/// The callback of the pending request of each kind.
var pending: [std.enums.values(common.Kind).len]?*const fn (common.Kind, common.Status) void = @splat(null);

/// Show the system prompt; `done` runs (on the UI thread) with the answer.
pub fn request(kind: common.Kind, done: *const fn (common.Kind, common.Status) void) void {
    const Ctx = struct {
        kind: common.Kind,
        done: *const fn (common.Kind, common.Status) void,
        fn run(self: *@This()) void {
            pending[@intFromEnum(self.kind)] = self.done;
            const started = runtime.call(.boolean, "requestPermission", "(I)Z", .{@as(i32, @intFromEnum(self.kind))}) orelse false;
            if (!started) {
                pending[@intFromEnum(self.kind)] = null;
                var k = self.kind;
                self.done(self.kind, statusNow(&k));
            }
        }
    };
    var ctx: Ctx = .{ .kind = kind, .done = done };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch done(kind, .unknown);
}

/// The app's page in the system settings (Settings > Apps > <app>).
pub fn openSettings(kind: common.Kind) bool {
    const Ctx = struct {
        kind: common.Kind,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "openPermissionSettings", "(I)Z", .{@as(i32, @intFromEnum(self.kind))}) orelse false;
        }
    };
    var ctx: Ctx = .{ .kind = kind };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return false;
    return ctx.ok;
}

/// `NativeLib.onPermissionResult(kind, status)` (UI thread).
fn onPermissionResult(_: *jni.Env, _: jni.jclass, kind: jni.jint, st: jni.jint) callconv(.c) void {
    if (kind < 0 or kind >= pending.len) return;
    const k: common.Kind = @enumFromInt(kind);
    const cb = pending[@intCast(kind)] orelse return;
    pending[@intCast(kind)] = null;
    cb(k, fromJava(st));
}

comptime {
    @export(&onPermissionResult, .{ .name = "Java_dev_oriel_NativeLib_onPermissionResult" });
}
