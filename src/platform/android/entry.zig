//! The app's entry point on Android. There is no `main()` process entry:
//! Kotlin loads `liboriel.so` and calls `NativeLib.start` on the UI thread,
//! which runs the app's `pub fn main` on a thread of its own, with a
//! `std.process.Init` built like `std.start` builds it. argv is the package
//! name followed by the launch intent's arguments (its data URI: a deep link).
//!
//! When `main` returns, Kotlin is told (`OrielRuntime.onExit`) and finishes
//! the app's Activities. The process may live on (Android caches it): a later
//! launch calls `start` again and the app runs anew.
//!
//! `oriel.addApp` generates the library's root file, which calls
//! `exportStart(app_root)`.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const builtin = @import("builtin");
const jni = @import("jni.zig");
const runtime = @import("runtime.zig");
const paths = @import("paths.zig");
const ShellMod = @import("Shell.zig");
const exports = @import("exports.zig");

const log = std.log.scoped(.oriel);

/// 0 = stopped, 1 = running (start → main returned).
var state: std.atomic.Value(u8) = .init(0);

/// `NativeLib.start` results.
const start_failed: jni.jint = 0;
const start_started: jni.jint = 1;
const start_already_running: jni.jint = 2;

pub fn exportStart(comptime root: type) void {
    const S = struct {
        fn start(env: *jni.Env, _: jni.jclass, files: jni.jobject, cache: jni.jobject, external: jni.jobject, args: jni.jobject) callconv(.c) jni.jint {
            if (state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return start_already_running;
            const gpa = heap.gpa;
            runtime.attachUiThread(env);
            ShellMod.attachLooper() catch |err| {
                log.err("could not attach to the main looper: {s}", .{@errorName(err)});
                state.store(0, .release);
                return start_failed;
            };
            {
                const f = (env.bytesAlloc(gpa, files) catch null) orelse &.{};
                defer if (f.len > 0) gpa.free(f);
                const c = (env.bytesAlloc(gpa, cache) catch null) orelse &.{};
                defer if (c.len > 0) gpa.free(c);
                const x = (env.bytesAlloc(gpa, external) catch null) orelse &.{};
                defer if (x.len > 0) gpa.free(x);
                paths.set(f, c, x);
            }
            var list = exports.argsAlloc(env, gpa, args) orelse {
                state.store(0, .release);
                return start_failed;
            };
            const argv = makeArgv(gpa, list.items) catch {
                exports.freeArgs(gpa, &list);
                state.store(0, .release);
                return start_failed;
            };
            exports.freeArgs(gpa, &list);
            const thread = std.Thread.spawn(.{ .stack_size = 8 * 1024 * 1024 }, runMain, .{argv}) catch |err| {
                log.err("could not start the app thread: {s}", .{@errorName(err)});
                freeArgv(gpa, argv);
                state.store(0, .release);
                return start_failed;
            };
            thread.detach();
            return start_started;
        }

        fn runMain(argv: [][*:0]u8) void {
            defer freeArgv(heap.gpa, argv);
            const code = callMain(argv);
            state.store(0, .release);
            ShellMod.notifyExited(code);
        }

        fn callMain(argv: [][*:0]u8) u8 {
            const args: std.process.Args.Vector = @ptrCast(argv);
            var env_count: usize = 0;
            while (std.c.environ[env_count] != null) : (env_count += 1) {}
            const environ: std.process.Environ.Block = .{ .slice = std.c.environ[0..env_count :null] };

            const fn_info = @typeInfo(@TypeOf(root.main)).@"fn";
            if (fn_info.params.len == 0) return wrapMain(root.main());
            if (fn_info.params[0].type.? == std.process.Init.Minimal) return wrapMain(root.main(.{
                .args = .{ .vector = args },
                .environ = .{ .block = environ },
            }));

            const gpa = heap.gpa;
            var arena_allocator = std.heap.ArenaAllocator.init(gpa);
            defer arena_allocator.deinit();
            var threaded: std.Io.Threaded = .init(gpa, .{
                .argv0 = .init(.{ .vector = args }),
                .environ = .{ .block = environ },
            });
            defer threaded.deinit();
            fixIoSignals();
            var environ_map = std.process.Environ.createMap(.{ .block = environ }, gpa) catch |err| {
                log.err("failed to parse environment variables: {s}", .{@errorName(err)});
                return 1;
            };
            defer environ_map.deinit();
            const preopens = std.process.Preopens.init(arena_allocator.allocator()) catch |err| {
                log.err("failed to init preopens: {s}", .{@errorName(err)});
                return 1;
            };
            return wrapMain(root.main(.{
                .minimal = .{
                    .args = .{ .vector = args },
                    .environ = .{ .block = environ },
                },
                .arena = &arena_allocator,
                .gpa = gpa,
                .io = threaded.io(),
                .environ_map = &environ_map,
                .preopens = preopens,
            }));
        }
    };
    @export(&S.start, .{ .name = "Java_dev_oriel_NativeLib_start" });
}

fn wrapMain(result: anytype) u8 {
    const T = @TypeOf(result);
    switch (T) {
        void => return 0,
        u8 => return result,
        else => {},
    }
    if (@typeInfo(T) != .error_union) @compileError("main must return void, !void, u8 or !u8");
    const value = result catch |err| {
        log.err("main failed: {s}", .{@errorName(err)});
        return 1;
    };
    return switch (@TypeOf(value)) {
        void => 0,
        u8 => value,
        else => @compileError("main must return void, !void, u8 or !u8"),
    };
}

/// argv for the app: the process name, then the intent's arguments.
fn makeArgv(gpa: std.mem.Allocator, args: []const []const u8) ![][*:0]u8 {
    const argv = try gpa.alloc([*:0]u8, args.len + 1);
    var made: usize = 0;
    errdefer {
        for (argv[0..made]) |a| gpa.free(std.mem.span(a));
        gpa.free(argv);
    }
    argv[0] = (try gpa.dupeZ(u8, processName())).ptr;
    made = 1;
    for (args, 1..) |a, i| {
        argv[i] = (try gpa.dupeZ(u8, a)).ptr;
        made += 1;
    }
    return argv;
}

fn freeArgv(gpa: std.mem.Allocator, argv: [][*:0]u8) void {
    for (argv) |a| gpa.free(std.mem.span(a));
    gpa.free(argv);
}

extern "c" fn getprogname() ?[*:0]const u8;

fn processName() []const u8 {
    return if (getprogname()) |p| std.mem.span(p) else "oriel";
}

/// The panic handler for Android apps: the message goes to logcat (stderr
/// goes nowhere), then the default handler aborts.
pub const panic = std.debug.FullPanic(panicLogcat);

fn panicLogcat(msg: []const u8, first_trace_addr: ?usize) noreturn {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrintZ(&buf, "panic: {s}", .{msg}) catch "panic";
    _ = __android_log_write(7, "Oriel", line.ptr); // ANDROID_LOG_FATAL
    std.debug.defaultPanic(msg, first_trace_addr);
}

extern "log" fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;

comptime {
    _ = builtin;
}

/// Install `Io.Threaded`'s SIGIO and SIGPIPE handlers again, with the raw
/// syscall. Zig 0.16's `std.c.Sigaction` has glibc's layout, but 64-bit
/// bionic's `struct sigaction` starts with `int sa_flags`: through bionic,
/// the handler pointer became the flags and the handler SIG_DFL. std.Io
/// cancels a blocking syscall with SIGIO (`HostName.connect` does, on
/// every connection), so the app was killed by "signal 29 (I/O possible)";
/// a write to a closed socket (SIGPIPE) killed it too. Neither signal is
/// ART's, so going around bionic and libsigchain is safe.
fn fixIoSignals() void {
    const linux = std.os.linux;
    const nop = struct {
        fn handler(_: linux.SIG) callconv(.c) void {}
    }.handler;
    const act: linux.Sigaction = .{ .handler = .{ .handler = nop }, .mask = linux.sigemptyset(), .flags = 0 };
    for ([_]linux.SIG{ .IO, .PIPE }) |sig| {
        if (linux.errno(linux.sigaction(sig, &act, null)) != .SUCCESS) log.warn("cannot handle signal {d}", .{@intFromEnum(sig)});
    }
}
