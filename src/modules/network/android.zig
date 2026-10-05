//! oriel.network on Android.
//!
//! mDNS / DNS-SD (`mdns_backend`): the platform's NsdManager, driven by
//! OrielMdns.kt. NsdManager talks to the system's mDNS responder
//! (system_server / mdnsd), which does the multicast itself: the app needs
//! no WifiManager.MulticastLock, no CHANGE_WIFI_MULTICAST_STATE and no
//! NEARBY_WIFI_DEVICES (that one gates Wi-Fi Direct/Aware and scans, not
//! NSD); INTERNET, which every Oriel app has, is enough. Android 17's local
//! network protection (ACCESS_LOCAL_NETWORK, enforced from targetSdk 37)
//! will gate NSD too; the template targets 35.
//!
//! - register: NsdServiceInfo (TXT through setAttribute) + registerService;
//!   the final name (renamed on a conflict) comes from onServiceRegistered.
//! - browse: discoverServices(type, PROTOCOL_DNS_SD); each service found is
//!   resolved: on API 34+ with registerServiceInfoCallback (all addresses,
//!   and updates while it lives), before that with resolveService, one at a
//!   time (older Androids refuse concurrent resolves with
//!   FAILURE_ALREADY_ACTIVE: OrielMdns queues them and retries).
//!
//! Threads: Zig calls Kotlin on the UI thread (`runOnMainThread`), or
//! directly from inside an event handler (the `oriel-mdns` Java thread has
//! its own env). Kotlin answers register/browse from NsdManager's thread
//! (`NativeLib.onMdnsResult`) and delivers events from `oriel-mdns`
//! (`NativeLib.onMdnsEvent`), where the handlers run. Kotlin never waits on
//! Zig's locks or the UI thread, so blocking in `register` on any thread is
//! safe.
//!
//! The multicast lock (`setMulticast`, for apps doing raw multicast) and
//! `info` (ConnectivityManager) aren't written yet.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const mdns = @import("mdns.zig");
const heap = @import("../../core/heap.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const runtime = @import("../../platform/android/runtime.zig");
const jni = @import("../../platform/android/jni.zig");

const log = std.log.scoped(.mdns);

pub fn setMulticast(on: bool) common.MulticastError!void {
    _ = on;
    return error.Unsupported;
}

pub fn info(gpa: std.mem.Allocator) !common.Info {
    _ = gpa;
    return error.Unsupported;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "network", .ok = true, .detail = try gpa.dupe(u8, "mdns: NsdManager; multicast lock and info: not implemented yet") };
}

// ---------------------------------------------------------------------------
// mDNS
// ---------------------------------------------------------------------------

/// A one-shot answer from Kotlin for a thread blocked in register/browse.
const Waiter = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    done: bool = false,
    ok: bool = false,
    code: i32 = 0,
    name_buf: [mdns.max_name_bytes]u8 = undefined,
    name_len: u8 = 0,

    fn signal(self: *Waiter, ok: bool, code: i32, name: []const u8) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.ok = ok;
        self.code = code;
        const n = @min(name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], name[0..n]);
        self.name_len = @intCast(n);
        self.done = true;
        _ = std.c.pthread_cond_broadcast(&self.cond);
    }

    /// False on timeout.
    fn wait(self: *Waiter, timeout_ms: u32) bool {
        var deadline: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &deadline);
        const ns = @as(i64, deadline.nsec) + @as(i64, timeout_ms % 1000) * std.time.ns_per_ms;
        deadline.sec += @intCast(timeout_ms / 1000 + @as(u32, @intCast(@divFloor(ns, std.time.ns_per_s))));
        deadline.nsec = @intCast(@mod(ns, std.time.ns_per_s));
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (!self.done) {
            if (std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &deadline) == .TIMEDOUT) return self.done;
        }
        return true;
    }
};

const RegSlot = struct {
    id: u32 = 0,
    waiter: ?*Waiter = null,
};

const max_type = 24; // "_" + 15 + "._tcp"

const BrowseSlot = struct {
    id: u32 = 0,
    handler: mdns.Handler = undefined,
    ctx: ?*anyopaque = null,
    type_buf: [max_type]u8 = undefined,
    type_len: u8 = 0,
    waiter: ?*Waiter = null,
};

/// Guards the tables and `next_id`; never held while calling Kotlin or a
/// handler.
var table_mutex: ShellMod.Mutex = .{};
var regs: [mdns.max_handles]RegSlot = @splat(.{});
var browsers: [mdns.max_handles]BrowseSlot = @splat(.{});
var next_id: u32 = 1;

/// Held while a handler runs, so `stopBrowse` can wait one out.
var call_mutex: ShellMod.Mutex = .{};
/// The thread running a handler (0: none) and its env, for Kotlin calls
/// from inside the handler.
var deliver_tid: std.atomic.Value(i32) = .init(0);
var deliver_env: ?*jni.Env = null;

fn gettid() i32 {
    return @intCast(std.os.linux.gettid());
}

fn newId() u32 {
    const id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    return id;
}

fn findReg(id: u32) ?*RegSlot {
    if (id == 0) return null;
    for (&regs) |*s| if (s.id == id) return s;
    return null;
}

fn findBrowser(id: u32) ?*BrowseSlot {
    if (id == 0) return null;
    for (&browsers) |*s| if (s.id == id) return s;
    return null;
}

/// Call `OrielRuntime.<name>`: directly on the UI thread or inside a
/// handler, else through the UI thread. Null when the app isn't running or
/// the call failed.
fn kotlin(comptime ret: runtime.Ret, comptime name: [:0]const u8, comptime sig: [:0]const u8, args: anytype) ?RetOf(ret) {
    if (runtime.mainEnv() != null) return runtime.call(ret, name, sig, args);
    if (deliver_tid.load(.acquire) == gettid()) if (deliver_env) |e| return runtime.callWith(e, ret, name, sig, args);
    const Ctx = struct {
        args: @TypeOf(args),
        out: ?RetOf(ret) = null,
        fn run(self: *@This()) void {
            self.out = runtime.call(ret, name, sig, self.args);
        }
    };
    var ctx: Ctx = .{ .args = args };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return null;
    return ctx.out;
}

fn RetOf(comptime ret: runtime.Ret) type {
    return switch (ret) {
        .void => void,
        .boolean => bool,
        .int => jni.jint,
        .long => jni.jlong,
        .object => jni.jobject,
    };
}

/// NsdManager.FAILURE_* names, for the log.
fn failureName(code: i32) []const u8 {
    return switch (code) {
        0 => "FAILURE_INTERNAL_ERROR",
        3 => "FAILURE_ALREADY_ACTIVE",
        4 => "FAILURE_MAX_LIMIT",
        5 => "FAILURE_OPERATION_NOT_RUNNING",
        6 => "FAILURE_BAD_PARAMETERS",
        -1 => "invalid TXT value or service info",
        else => "unknown",
    };
}

pub const mdns_backend = struct {
    pub const supported = true;

    pub fn register(service: mdns.Service) mdns.Error!mdns.Registration {
        const txt = try mdns.encodeTxt(heap.gpa, service.txt);
        defer heap.gpa.free(txt);
        var waiter: Waiter = .{};
        const id = blk: {
            table_mutex.lock();
            defer table_mutex.unlock();
            for (&regs) |*s| if (s.id == 0) {
                s.* = .{ .id = newId(), .waiter = &waiter };
                break :blk s.id;
            };
            return error.TooMany;
        };
        const started = kotlin(.boolean, "mdnsRegister", "(I[B[BI[B)Z", .{ @as(i32, @bitCast(id)), service.name, service.type, @as(i32, service.port), @as([]const u8, txt) }) orelse false;
        const answered = started and waiter.wait(mdns.answer_timeout_ms);
        table_mutex.lock();
        if (findReg(id)) |s| s.waiter = null;
        table_mutex.unlock();
        if (!started or !answered or !waiter.ok) {
            if (started) {
                if (!answered) log.err("register {s}: no answer from NsdManager", .{service.type}) else log.err("register {s}: {s} ({d})", .{ service.type, failureName(waiter.code), waiter.code });
            }
            unregister(id);
            if (started and !answered) return error.Timeout;
            return if (started and waiter.code == -1) error.InvalidTxt else error.Failed;
        }
        var reg: mdns.Registration = .{ .id = id, .name_len = waiter.name_len };
        @memcpy(reg.name_buf[0..waiter.name_len], waiter.name_buf[0..waiter.name_len]);
        return reg;
    }

    pub fn unregister(id: u32) void {
        {
            table_mutex.lock();
            defer table_mutex.unlock();
            const s = findReg(id) orelse return;
            s.* = .{};
        }
        _ = kotlin(.void, "mdnsUnregister", "(I)V", .{@as(i32, @bitCast(id))});
    }

    pub fn browse(service_type: []const u8, handler: mdns.Handler, ctx: ?*anyopaque) mdns.Error!mdns.Browser {
        if (service_type.len > max_type) return error.InvalidServiceType;
        var waiter: Waiter = .{};
        const id = blk: {
            table_mutex.lock();
            defer table_mutex.unlock();
            for (&browsers) |*s| if (s.id == 0) {
                s.* = .{ .id = newId(), .handler = handler, .ctx = ctx, .waiter = &waiter, .type_len = @intCast(service_type.len) };
                @memcpy(s.type_buf[0..service_type.len], service_type);
                break :blk s.id;
            };
            return error.TooMany;
        };
        const started = kotlin(.boolean, "mdnsBrowse", "(I[B)Z", .{ @as(i32, @bitCast(id)), service_type }) orelse false;
        const answered = started and waiter.wait(mdns.answer_timeout_ms);
        table_mutex.lock();
        if (findBrowser(id)) |s| s.waiter = null;
        table_mutex.unlock();
        if (!started or !answered or !waiter.ok) {
            if (started) {
                if (!answered) log.err("browse {s}: no answer from NsdManager", .{service_type}) else log.err("browse {s}: {s} ({d})", .{ service_type, failureName(waiter.code), waiter.code });
            }
            stopBrowse(id);
            return if (started and !answered) error.Timeout else error.Failed;
        }
        return .{ .id = id };
    }

    pub fn stopBrowse(id: u32) void {
        {
            table_mutex.lock();
            defer table_mutex.unlock();
            const s = findBrowser(id) orelse return;
            s.* = .{};
        }
        // Wait out a handler running on another thread (deliver re-checks
        // the slot under call_mutex, so none starts after this).
        if (deliver_tid.load(.acquire) != gettid()) {
            call_mutex.lock();
            call_mutex.unlock();
        }
        _ = kotlin(.void, "mdnsStopBrowse", "(I)V", .{@as(i32, @bitCast(id))});
    }
};

/// NativeLib.onMdnsResult(kind, id, ok, code, name): the answer to
/// mdnsRegister (kind 0) or mdnsBrowse (kind 1). NsdManager's thread.
fn nativeResult(env: *jni.Env, _: jni.jclass, kind: jni.jint, id: jni.jint, ok: jni.jboolean, code: jni.jint, name_arr: jni.jobject) callconv(.c) void {
    var buf: [mdns.max_name_bytes]u8 = undefined;
    var name: []const u8 = &.{};
    if (name_arr != null) {
        const len: usize = @intCast(@max(env.functions.GetArrayLength(env, name_arr), 0));
        const n = @min(len, buf.len);
        if (n > 0) env.functions.GetByteArrayRegion(env, name_arr, 0, @intCast(n), &buf);
        name = buf[0..n];
    }
    table_mutex.lock();
    defer table_mutex.unlock();
    const waiter = if (kind == 0)
        (if (findReg(@bitCast(id))) |s| s.waiter else null)
    else
        (if (findBrowser(@bitCast(id))) |s| s.waiter else null);
    if (waiter) |w| w.signal(ok != 0, code, name);
}

/// NativeLib.onMdnsEvent(id, event): an event (the wire format of
/// mdns.zig) for browser `id`. The `oriel-mdns` thread.
fn nativeEvent(env: *jni.Env, _: jni.jclass, id_j: jni.jint, data: jni.jobject) callconv(.c) void {
    const id: u32 = @bitCast(id_j);
    const bytes = (env.bytesAlloc(heap.gpa, data) catch return) orelse return;
    defer heap.gpa.free(bytes);

    call_mutex.lock();
    defer call_mutex.unlock();
    var type_buf: [max_type]u8 = undefined;
    const handler, const ctx, const service_type = blk: {
        table_mutex.lock();
        defer table_mutex.unlock();
        const s = findBrowser(id) orelse return; // stopped
        @memcpy(type_buf[0..s.type_len], s.type_buf[0..s.type_len]);
        break :blk .{ s.handler, s.ctx, type_buf[0..s.type_len] };
    };
    var arena: std.heap.ArenaAllocator = .init(heap.gpa);
    defer arena.deinit();
    const event = mdns.decodeEvent(arena.allocator(), bytes, service_type) catch {
        log.err("malformed event from OrielMdns ({d} bytes)", .{bytes.len});
        return;
    };
    deliver_env = env;
    deliver_tid.store(gettid(), .release);
    defer {
        deliver_tid.store(0, .release);
        deliver_env = null;
    }
    handler(ctx, &event);
}

comptime {
    @export(&nativeResult, .{ .name = "Java_dev_oriel_NativeLib_onMdnsResult" });
    @export(&nativeEvent, .{ .name = "Java_dev_oriel_NativeLib_onMdnsEvent" });
}
