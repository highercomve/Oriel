//! JNI natives of `dev.oriel.NativeLib` (Kotlin), except `start`, which is
//! generic over the app and lives in `entry.zig`. Each forwards to the
//! app's handler (`handlers.zig`) and does nothing while no app runs.
//!
//! Text arrives as UTF-8 `byte[]` (see `jni.zig`).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const jni = @import("jni.zig");
const runtime = @import("runtime.zig");
const handlers = @import("handlers.zig");
const scheme = @import("scheme.zig");
const window = @import("window.zig");
const ShellMod = @import("Shell.zig");
const App = @import("../../core/App.zig");

const log = std.log.scoped(.oriel);

const Env = jni.Env;
const jclass = jni.jclass;
const jobject = jni.jobject;
const jint = jni.jint;
const jboolean = jni.jboolean;

fn id(v: jint) u32 {
    return @bitCast(v);
}

/// A `byte[]` argument, copied (caller frees with `gpa`); "" for null.
fn bytes(env: *Env, arr: jobject) ?[]u8 {
    const gpa = heap.gpa;
    return (env.bytesAlloc(gpa, arr) catch return null) orelse gpa.alloc(u8, 0) catch null;
}

fn JNI_OnLoad(vm: *jni.Vm, _: ?*anyopaque) callconv(.c) jint {
    importDebugEnv();
    return runtime.onLoad(vm);
}

/// An app can't be given environment variables on Android: the debug switches
/// (ORIEL_NUI_TRACE, ORIEL_NUI_MEM…) come from a system property instead,
/// `adb shell setprop debug.oriel.env "ORIEL_NUI_TRACE=1 ORIEL_NUI_MEM=1"`
/// (space-separated NAME=VALUE, read when the library loads).
fn importDebugEnv() void {
    var buf: [92]u8 = undefined; // PROP_VALUE_MAX
    const len = __system_property_get("debug.oriel.env", &buf);
    if (len <= 0) return;
    var words = std.mem.tokenizeScalar(u8, buf[0..@intCast(len)], ' ');
    while (words.next()) |w| {
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse continue;
        var name: [64]u8 = undefined;
        var value: [92]u8 = undefined;
        if (eq == 0 or eq >= name.len or w.len - eq - 1 >= value.len) continue;
        @memcpy(name[0..eq], w[0..eq]);
        name[eq] = 0;
        @memcpy(value[0 .. w.len - eq - 1], w[eq + 1 ..]);
        value[w.len - eq - 1] = 0;
        _ = setenv(name[0..eq :0], value[0 .. w.len - eq - 1 :0], 1);
    }
}

extern "c" fn __system_property_get(name: [*:0]const u8, value: [*]u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn onMessage(env: *Env, _: jclass, win: jint, data: jobject, origin: jobject) callconv(.c) void {
    const f = handlers.on_message orelse return;
    const gpa = heap.gpa;
    const d = bytes(env, data) orelse return;
    defer gpa.free(d);
    const o = bytes(env, origin) orelse return;
    defer gpa.free(o);
    f(id(win), d, o);
}

/// `shouldInterceptRequest` (a WebView IO thread): the encoded response
/// (`scheme.encode`), or null to let the WebView load the URL itself.
fn serve(env: *Env, _: jclass, win: jint, url: jobject) callconv(.c) jobject {
    const f = handlers.serve orelse return null;
    const gpa = heap.gpa;
    const u = bytes(env, url) orelse return null;
    defer gpa.free(u);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const response = f(arena, id(win), u) orelse return null;
    const encoded = scheme.encode(arena, response) catch return null;
    return env.newBytes(encoded);
}

fn navigation(env: *Env, _: jclass, win: jint, url: jobject, gesture: jboolean) callconv(.c) jboolean {
    const f = handlers.navigation orelse return 0;
    const gpa = heap.gpa;
    const u = bytes(env, url) orelse return 0;
    defer gpa.free(u);
    return @intFromBool(f(id(win), u, gesture != 0));
}

fn newWindow(env: *Env, _: jclass, win: jint, url: jobject, gesture: jboolean) callconv(.c) void {
    const f = handlers.new_window orelse return;
    const gpa = heap.gpa;
    const u = bytes(env, url) orelse return;
    defer gpa.free(u);
    f(id(win), u, gesture != 0);
}

/// The user closed the window (its Activity was finished: the caption's
/// close button, swiped away from Recents).
fn onCloseRequested(_: *Env, _: jclass, win: jint) callconv(.c) void {
    const w = window.getWindowById(id(win)) orelse return;
    if (!w.ready) {
        w.pending_close = true;
        return;
    }
    window.closeNow(w);
}

fn onLoadFailed(_: *Env, _: jclass, win: jint) callconv(.c) void {
    const f = handlers.load_failed orelse return;
    f(id(win));
}

fn allowMedia(env: *Env, _: jclass, win: jint, origin: jobject, kinds: jint) callconv(.c) jboolean {
    const f = handlers.allow_media orelse return 0;
    const gpa = heap.gpa;
    const o = bytes(env, origin) orelse return 0;
    defer gpa.free(o);
    return @intFromBool(f(id(win), o, @bitCast(kinds)));
}

/// A later launch intent (the launcher Activity again, a deep link) while
/// the app runs: its arguments, like a desktop app's second instance.
fn onNewIntent(env: *Env, _: jclass, args: jobject) callconv(.c) void {
    const f = handlers.on_new_intent orelse return;
    const gpa = heap.gpa;
    var list = argsAlloc(env, gpa, args) orelse return;
    defer freeArgs(gpa, &list);
    f(list.items);
}

fn isRunning(_: *Env, _: jclass) callconv(.c) jboolean {
    return @intFromBool(ShellMod.isRunning());
}

/// A `byte[][]` as owned strings.
pub fn argsAlloc(env: *Env, gpa: std.mem.Allocator, arr: jobject) ?std.ArrayList([]const u8) {
    var list: std.ArrayList([]const u8) = .empty;
    if (arr == null) return list;
    const n: usize = @intCast(@max(env.functions.GetArrayLength(env, arr), 0));
    for (0..n) |i| {
        const item = env.functions.GetObjectArrayElement(env, arr, @intCast(i));
        defer if (item != null) env.functions.DeleteLocalRef(env, item);
        const s = (env.bytesAlloc(gpa, item) catch null) orelse continue;
        list.append(gpa, s) catch {
            gpa.free(s);
            freeArgs(gpa, &list);
            return null;
        };
    }
    return list;
}

pub fn freeArgs(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| gpa.free(s);
    list.deinit(gpa);
}

comptime {
    const prefix = "Java_dev_oriel_NativeLib_";
    @export(&JNI_OnLoad, .{ .name = "JNI_OnLoad" });
    @export(&onMessage, .{ .name = prefix ++ "onMessage" });
    @export(&serve, .{ .name = prefix ++ "serve" });
    @export(&navigation, .{ .name = prefix ++ "navigation" });
    @export(&newWindow, .{ .name = prefix ++ "newWindow" });
    @export(&onCloseRequested, .{ .name = prefix ++ "onCloseRequested" });
    @export(&onLoadFailed, .{ .name = prefix ++ "onLoadFailed" });
    @export(&allowMedia, .{ .name = prefix ++ "allowMedia" });
    @export(&onNewIntent, .{ .name = prefix ++ "onNewIntent" });
    @export(&isRunning, .{ .name = prefix ++ "isRunning" });
    _ = App;
    _ = log;
}
