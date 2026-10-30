//! Android: the template's OrielCamera.kt. `.camera` asks for CAMERA when
//! the manifest declares it, then starts the camera app
//! (`ACTION_IMAGE_CAPTURE`) writing into Oriel's capture provider
//! (`<app id>.oriel.capture`); `.library` opens the system photo picker
//! (`ACTION_PICK_IMAGES` on Android 13+, `ACTION_GET_CONTENT` before).
//! Kotlin decodes the photo (HEIC too), scales it and encodes it on a
//! thread of its own, and answers once through
//! `NativeLib.onCameraResult(request, status, width, height, bytes)`.
//!
//! The camera and the picker are Activities: waiting for them would freeze
//! the UI thread, so call this from an async command. On the UI thread it
//! returns error.MainThread.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const android = @import("../../platform/android/android.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const jni = @import("../../platform/android/jni.zig");

/// One capture at a time (the camera and the picker are modal anyway).
var busy: std.atomic.Value(bool) = .init(false);

/// OrielCamera.STATUS_*.
pub const Status = enum(i32) { ok = 0, cancelled = 1, unsupported = 2, permission_denied = 3, failed = 4, too_large = 5, _ };

const Result = struct {
    status: Status = .failed,
    width: u32 = 0,
    height: u32 = 0,
    /// heap.gpa
    data: ?[]u8 = null,
};

/// One capturePhoto call, answered once from any thread. `request` (its
/// address) lives on the waiting caller's stack.
const Request = android.AsyncRequest(Result);

/// The error for a status other than ok.
pub fn statusError(status: Status) common.Error {
    return switch (status) {
        .cancelled => error.Cancelled,
        .unsupported => error.Unsupported,
        .permission_denied => error.PermissionDenied,
        .too_large => error.TooLarge,
        else => error.CaptureFailed,
    };
}

pub fn capturePhoto(io: std.Io, arena: std.mem.Allocator, options: common.Options) common.Error!common.Photo {
    _ = io;
    if (ShellMod.isMainThread()) return error.MainThread;
    if (busy.swap(true, .acq_rel)) return error.Busy;
    defer busy.store(false, .release);

    var req: Request = .init(.{});
    const Ctx = struct {
        req: *Request,
        options: common.Options,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "capturePhoto", "(JIIII)Z", .{
                self.req.handle(),
                @as(i32, @intFromEnum(self.options.source)),
                @as(i32, @intCast(self.options.max_side)),
                @as(i32, @intFromEnum(self.options.format)),
                @as(i32, self.options.quality),
            }) orelse false;
        }
    };
    var ctx: Ctx = .{ .req = &req, .options = options };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return error.CaptureFailed;
    if (!ctx.ok) return error.Unsupported; // no Activity, or the module's Kotlin is missing
    req.wait();

    const data = req.result.data;
    defer if (data) |d| heap.gpa.free(d);
    if (req.result.status != .ok) return statusError(req.result.status);
    const bytes = data orelse return error.CaptureFailed;
    return .{
        .bytes = try arena.dupe(u8, bytes),
        .width = req.result.width,
        .height = req.result.height,
        .mime = options.format.mime(),
    };
}

/// `NativeLib.onCameraResult(request, status, width, height, bytes)`: any
/// thread, once per request.
fn onCameraResult(env: *jni.Env, _: jni.jclass, request: jni.jlong, status: jni.jint, width: jni.jint, height: jni.jint, data: jni.jobject) callconv(.c) void {
    const req = Request.fromHandle(request);
    var st: Status = @enumFromInt(status);
    var copy: ?[]u8 = null;
    if (st == .ok) {
        const len: usize = if (data == null) 0 else @intCast(@max(env.functions.GetArrayLength(env, data), 0));
        if (len == 0) {
            st = .failed;
        } else if (len > common.max_bytes) {
            st = .too_large;
        } else if (heap.gpa.alloc(u8, len)) |buf| {
            env.functions.GetByteArrayRegion(env, data, 0, @intCast(len), buf.ptr);
            copy = buf;
        } else |_| st = .failed;
    }
    req.complete(.{
        .status = st,
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .data = copy,
    });
}

comptime {
    @export(&onCameraResult, .{ .name = "Java_dev_oriel_NativeLib_onCameraResult" });
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "camera",
        .ok = true,
        .detail = "ACTION_IMAGE_CAPTURE into <app id>.oriel.capture, the system photo picker; scaled and encoded in Kotlin",
    };
}

test statusError {
    try std.testing.expectEqual(error.Cancelled, statusError(.cancelled));
    try std.testing.expectEqual(error.PermissionDenied, statusError(.permission_denied));
    try std.testing.expectEqual(error.CaptureFailed, statusError(@enumFromInt(42)));
}
