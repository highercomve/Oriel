//! The Android backend of `oriel.extensions`: Kotlin classes implementing
//! `dev.oriel.OrielAppExtension`, constructed by the generated
//! `OrielExtensionsRegistry` and reached through `OrielRuntime`'s static
//! `extension*` methods. The workers attach to the VM once (daemon
//! threads), so a call is one JNI call on the worker that runs it.
//! Kotlin answers with `extensions.decodeStatusReply`'s format: exceptions
//! never cross JNI.

const std = @import("std");
const jni = @import("jni.zig");
const runtime = @import("runtime.zig");
const heap = @import("../../core/heap.zig");
const extensions = @import("../../core/extensions.zig");
const lifecycle = @import("../../core/lifecycle.zig");

const log = std.log.scoped(.extensions);

pub const impl: extensions.Impl = .{
    .call = call,
    .load = load,
    .lifecycle = onLifecycle,
    .thread_start = attach,
    .thread_end = detach,
};

/// The worker's env, from `attach`.
threadlocal var worker_env: ?*jni.Env = null;

fn attach() void {
    const vm = runtime.vm orelse return;
    var env: ?*jni.Env = null;
    if (vm.functions.AttachCurrentThreadAsDaemon(vm, &env, null) != jni.JNI_OK) {
        log.err("a worker couldn't attach to the VM", .{});
        return;
    }
    worker_env = env;
}

fn detach() void {
    const vm = runtime.vm orelse return;
    if (worker_env == null) return;
    _ = vm.functions.DetachCurrentThread(vm);
    worker_env = null;
}

fn load(ctx: *extensions.Context) anyerror!void {
    const env = worker_env orelse return error.Unavailable;
    const ok = runtime.callWith(env, .boolean, "extensionLoad", "([B)Z", .{ctx.name}) orelse return error.Unavailable;
    if (!ok) {
        log.err("{s}: not in the APK's extension registry (rebuild the Gradle project)", .{ctx.name});
        return error.Unavailable;
    }
}

fn call(ctx: *extensions.Context, method: []const u8, input: []const u8) anyerror![]const u8 {
    const env = worker_env orelse return error.Unavailable;
    // Every local reference of the call goes with the frame.
    if (env.functions.PushLocalFrame(env, 8) != 0) {
        _ = env.clearException();
        return error.OutOfMemory;
    }
    defer _ = env.functions.PopLocalFrame(env, null);
    const id: i64 = @bitCast(ctx.callId());
    const reply = runtime.callWith(env, .object, "extensionCall", "([B[B[BJ)[B", .{ ctx.name, method, input, id }) orelse {
        if (ctx.diagnostics()) |d| d.set("exception", "OrielRuntime.extensionCall threw (see logcat)");
        return error.ExtensionFailed;
    };
    const bytes = (try env.bytesAlloc(ctx.arena, reply)) orelse return error.Unavailable;
    return extensions.decodeStatusReply(ctx, bytes);
}

/// Main thread (a lifecycle subscriber).
fn onLifecycle(r: *extensions.Runner, event: lifecycle.Event) void {
    const level: ?[]const u8 = switch (event) {
        .memory_pressure => |p| @tagName(p),
        else => null,
    };
    runtime.call(.void, "extensionLifecycle", "([B[B[B)V", .{ r.name, event.name(), level }) orelse {};
}

/// `NativeLib.extensionCancelled(callId)`: OrielCall.isCancelled (any thread).
fn nativeCancelled(_: *jni.Env, _: jni.jclass, id: jni.jlong) callconv(.c) jni.jboolean {
    return @intFromBool(extensions.cancelledById(@bitCast(id)));
}

/// `NativeLib.onExtensionEvent(extension, event, data)`: an emit (any thread).
fn nativeEvent(env: *jni.Env, _: jni.jclass, name_arr: jni.jobject, event_arr: jni.jobject, data_arr: jni.jobject) callconv(.c) void {
    const gpa = heap.gpa;
    const name = (env.bytesAlloc(gpa, name_arr) catch return) orelse return;
    defer gpa.free(name);
    const event = (env.bytesAlloc(gpa, event_arr) catch return) orelse return;
    defer gpa.free(event);
    const data = (env.bytesAlloc(gpa, data_arr) catch return) orelse &.{};
    defer if (data.len > 0) gpa.free(data);
    extensions.emitByName(name, event, data);
}

comptime {
    @export(&nativeCancelled, .{ .name = "Java_dev_oriel_NativeLib_extensionCancelled" });
    @export(&nativeEvent, .{ .name = "Java_dev_oriel_NativeLib_onExtensionEvent" });
}
