//! The Java side of the Android backend: the `dev.oriel.OrielRuntime` class
//! (Kotlin, shipped in the Gradle template) and the JNI state to call it.
//!
//! Oriel's main thread is Android's main (UI) thread. Its `JNIEnv` is kept
//! from `NativeLib.start`, which Kotlin calls on that thread; Java is only
//! called from there (`env()` returns null anywhere else), so worker threads
//! never attach to the VM. Kotlin calls back into Zig through the `NativeLib`
//! natives in `exports.zig`.

const std = @import("std");
const jni = @import("jni.zig");

const log = std.log.scoped(.oriel);

pub var vm: ?*jni.Vm = null;
/// The UI thread's env (valid for that thread's lifetime).
var ui_env: ?*jni.Env = null;
var ui_tid: std.atomic.Value(i32) = .init(0);
/// Global reference to `dev.oriel.OrielRuntime`, from JNI_OnLoad (which runs
/// with the app's class loader; FindClass on other threads would not).
var runtime_class: jni.jclass = null;

pub const class_name = "dev/oriel/OrielRuntime";

/// JNI_OnLoad: keep the VM and the runtime class.
pub fn onLoad(the_vm: *jni.Vm) jni.jint {
    vm = the_vm;
    const env = the_vm.getEnv() orelse return -1;
    const local = env.functions.FindClass(env, class_name) orelse {
        _ = env.clearException();
        log.err("class {s} not found: is the Oriel runtime in the APK?", .{class_name});
        return jni.JNI_VERSION_1_6;
    };
    runtime_class = env.functions.NewGlobalRef(env, local);
    env.functions.DeleteLocalRef(env, local);
    return jni.JNI_VERSION_1_6;
}

/// Called on the UI thread (from `NativeLib.start`).
pub fn attachUiThread(env: *jni.Env) void {
    ui_env = env;
    ui_tid.store(gettid(), .release);
}

fn gettid() i32 {
    return @intCast(std.os.linux.gettid());
}

pub fn isMainThread() bool {
    const t = ui_tid.load(.acquire);
    return t != 0 and t == gettid();
}

/// The env for calls into Java: only on the UI thread.
pub fn mainEnv() ?*jni.Env {
    if (!isMainThread()) return null;
    return ui_env;
}

/// A static method of OrielRuntime, looked up once per (name, signature).
fn method(e: *jni.Env, comptime name: [:0]const u8, comptime sig: [:0]const u8) jni.jmethodID {
    // Zig dedups a type declared in a generic function by what it captures:
    // without `name` and `sig` in it, every call site shared one `id`, and
    // `showWindow(I)V` was called with the method ID `createWindow` cached.
    const Cache = struct {
        const key = .{ name, sig };
        var id: jni.jmethodID = null;
    };
    if (Cache.id == null) {
        const cls = runtime_class orelse return null;
        Cache.id = e.functions.GetStaticMethodID(e, cls, name, sig);
        if (Cache.id == null) {
            _ = e.clearException();
            log.err("OrielRuntime.{s}{s} not found: the Kotlin runtime doesn't match this Oriel", .{ name, sig });
        }
    }
    return Cache.id;
}

/// Argument conversion for `call`: Zig values to jvalues. Slices become
/// local `byte[]` (UTF-8 text), deleted after the call.
fn toJValue(e: *jni.Env, arg: anytype, locals: *[16]jni.jobject, n_locals: *usize) jni.jvalue {
    const T = @TypeOf(arg);
    if (T == jni.jobject) return .{ .l = arg };
    switch (@typeInfo(T)) {
        .bool => return .{ .z = @intFromBool(arg) },
        .int, .comptime_int => {
            if (T == i64 or T == u64) return .{ .j = @intCast(arg) };
            return .{ .i = @intCast(arg) };
        },
        .pointer => {
            const bytes: []const u8 = arg;
            const arr = e.newBytes(bytes);
            locals[n_locals.*] = arr;
            n_locals.* += 1;
            return .{ .l = arr };
        },
        .optional => {
            if (arg) |v| return toJValue(e, v, locals, n_locals);
            return .{ .l = null };
        },
        else => @compileError("OrielRuntime call: unsupported argument type " ++ @typeName(T)),
    }
}

pub const Ret = enum { void, boolean, int, long, object };

fn RetType(comptime ret: Ret) type {
    return switch (ret) {
        .void => void,
        .boolean => bool,
        .int => jni.jint,
        .long => jni.jlong,
        .object => jni.jobject,
    };
}

/// Call `OrielRuntime.<name>` (a `@JvmStatic` method) on the UI thread.
/// `args`: a tuple of bools, ints, `[]const u8` (passed as `byte[]`),
/// optional slices (null `byte[]`) and jobjects. Returns null when not on
/// the UI thread, the method is missing, or it threw (logged).
pub fn call(comptime ret: Ret, comptime name: [:0]const u8, comptime sig: [:0]const u8, args: anytype) ?RetType(ret) {
    const e = mainEnv() orelse {
        log.err("OrielRuntime.{s} called off the main thread", .{name});
        return null;
    };
    return callWith(e, ret, name, sig, args);
}

/// `call` with an explicit env (any thread with an attached env, e.g. a
/// native method's own env).
pub fn callWith(e: *jni.Env, comptime ret: Ret, comptime name: [:0]const u8, comptime sig: [:0]const u8, args: anytype) ?RetType(ret) {
    const cls = runtime_class orelse return null;
    const m = method(e, name, sig) orelse return null;
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    var values: [@max(fields.len, 1)]jni.jvalue = undefined;
    var locals: [16]jni.jobject = undefined;
    var n_locals: usize = 0;
    inline for (fields, 0..) |f, i| values[i] = toJValue(e, @field(args, f.name), &locals, &n_locals);
    defer for (locals[0..n_locals]) |l| if (l != null) e.functions.DeleteLocalRef(e, l);
    const f = e.functions;
    const result: RetType(ret) = switch (ret) {
        .void => f.CallStaticVoidMethodA(e, cls, m, &values),
        .boolean => f.CallStaticBooleanMethodA(e, cls, m, &values) != 0,
        .int => f.CallStaticIntMethodA(e, cls, m, &values),
        .long => f.CallStaticLongMethodA(e, cls, m, &values),
        .object => f.CallStaticObjectMethodA(e, cls, m, &values),
    };
    if (e.clearException()) {
        log.err("OrielRuntime.{s} threw (see the exception above)", .{name});
        if (ret == .object) if (result) |o| e.functions.DeleteLocalRef(e, o);
        return null;
    }
    return result;
}

/// Copy a `byte[]` result into `gpa` memory and delete the local ref.
pub fn takeBytes(e: *jni.Env, gpa: std.mem.Allocator, arr: jni.jobject) ?[]u8 {
    defer if (arr != null) e.functions.DeleteLocalRef(e, arr);
    return (e.bytesAlloc(gpa, arr) catch return null) orelse null;
}
