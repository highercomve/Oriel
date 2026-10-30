//! Helpers over the Objective-C runtime (`objc.zig`) for the AppKit and
//! UIKit backends and the Apple modules: class lookup and definition,
//! NSString conversion, geometry, Grand Central Dispatch and blocks. No SDK
//! headers, so everything using it type-checks on any host.
//!
//! Memory rules (manual retain/release, no ARC): objects from `alloc`/`new`/
//! `copy` are owned (+1) and must be released once; anything else is
//! borrowed (autoreleased or owned by its container). Code that creates
//! autoreleased objects outside the run loop runs inside an
//! `objc.AutoreleasePool`.

const std = @import("std");
pub const objc = @import("objc.zig");

pub const c = objc.c;
pub const id = c.id;
pub const Object = objc.Object;
pub const Class = objc.Class;

pub const NSUTF8StringEncoding: c_ulong = 4;

pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CGSize = extern struct { width: f64, height: f64 };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };
/// AppKit's names for the same structs (typedefs of the CG ones on 64-bit).
pub const NSPoint = CGPoint;
pub const NSSize = CGSize;
pub const NSRect = CGRect;

/// The class `name`. Every class used here ships with the frameworks the
/// build links, so a missing one is a broken install.
pub fn class(name: [:0]const u8) Class {
    return objc.getClass(name) orelse std.debug.panic("Objective-C class {s} not found", .{name});
}

/// Objective-C BOOL from a Zig bool (BOOL is `bool` on arm64, `i8` on x86_64).
pub fn boolean(value: bool) c.BOOL {
    return if (c.BOOL == bool) value else @intFromBool(value);
}

pub fn isTrue(value: c.BOOL) bool {
    return if (c.BOOL == bool) value else value != 0;
}

pub const nil: Object = .{ .value = null };

/// A new NSString (+1, caller releases) with a copy of `bytes`, or null if
/// they are not valid UTF-8 (or out of memory).
pub fn nsString(bytes: []const u8) ?Object {
    const alloc = class("NSString").msgSend(Object, "alloc", .{});
    const str = alloc.msgSend(Object, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(c_ulong, bytes.len), NSUTF8StringEncoding });
    return if (str.value == null) null else str;
}

/// UTF-8 view of an NSString (null for nil). Borrowed: valid while `str` and
/// the current autorelease pool live.
pub fn utf8(str: Object) ?[:0]const u8 {
    if (str.value == null) return null;
    const p = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(p);
}

/// `url.absoluteString` of an NSURL as UTF-8 (borrowed, see `utf8`).
pub fn urlString(url: Object) ?[:0]const u8 {
    if (url.value == null) return null;
    return utf8(url.msgSend(Object, "absoluteString", .{}));
}

/// `+[NSURL URLWithString:]` (autoreleased), or nil.
pub fn nsUrl(text: []const u8) Object {
    const s = nsString(text) orelse return nil;
    defer s.release();
    return class("NSURL").msgSend(Object, "URLWithString:", .{s});
}

/// Adopt a protocol if the runtime knows it (protocols without metadata in a
/// loaded image aren't registered; the frameworks only check selectors).
pub fn addProtocol(cls: Class, name: [:0]const u8) void {
    if (objc.getProtocol(name)) |proto| _ = c.class_addProtocol(cls.value, proto.value);
}

/// Whether this process runs from an `.app` bundle with a bundle id (the
/// UserNotifications framework raises an exception otherwise).
pub fn bundled() bool {
    const bundle = class("NSBundle").msgSend(Object, "mainBundle", .{});
    if (bundle.value == null) return false;
    if (bundle.msgSend(Object, "bundleIdentifier", .{}).value == null) return false;
    const path = utf8(bundle.msgSend(Object, "bundlePath", .{})) orelse return false;
    return std.mem.endsWith(u8, path, ".app");
}

var class_counter: std.atomic.Value(u32) = .init(0);

/// Define and register an NSObject subclass named `<prefix><n>`: the
/// counter keeps names unique when several app configs are compiled into
/// one binary (e.g. the smoke app's GUI and auto-quit configs).
/// `methods` is a tuple of `.{ "selector:", fn }`. Classes are never
/// disposed: they live as long as the process.
pub fn defineClass(comptime prefix: []const u8, protocols: []const [:0]const u8, methods: anytype) Class {
    return defineSubclass(prefix, "NSObject", protocols, methods);
}

/// Like `defineClass`, with `superclass` (e.g. "NSWindow") instead of NSObject.
pub fn defineSubclass(comptime prefix: []const u8, comptime superclass: [:0]const u8, protocols: []const [:0]const u8, methods: anytype) Class {
    const n = class_counter.fetchAdd(1, .monotonic);
    // The runtime keeps using the name, so it must outlive the class: never freed.
    const name = std.fmt.allocPrintSentinel(std.heap.smp_allocator, "{s}{d}", .{ prefix, n }, 0) catch
        std.debug.panic("out of memory defining {s}", .{prefix});
    const cls = objc.allocateClassPair(class(superclass), name) orelse
        std.debug.panic("objc_allocateClassPair({s}) failed", .{name});
    for (protocols) |p| addProtocol(cls, p);
    inline for (methods) |m| {
        if (!cls.addMethod(m[0], m[1])) std.debug.panic("class_addMethod({s}) failed", .{m[0]});
    }
    objc.registerClassPair(cls);
    return cls;
}

/// `[[cls alloc] init]`: owned (+1).
pub fn new(cls: Class) Object {
    return cls.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
}

// ---------------------------------------------------------------------------
// Grand Central Dispatch (libSystem)
// ---------------------------------------------------------------------------

pub const DispatchFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;

extern var _dispatch_main_q: u8;
extern "c" fn dispatch_async_f(queue: *anyopaque, ctx: ?*anyopaque, work: DispatchFn) void;
extern "c" fn dispatch_after_f(when: u64, queue: *anyopaque, ctx: ?*anyopaque, work: DispatchFn) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;
extern "c" fn dispatch_release(object: *anyopaque) void;
extern "c" fn pthread_main_np() c_int;

const DISPATCH_TIME_NOW: u64 = 0;
const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);

fn mainQueue() *anyopaque {
    return @ptrCast(&_dispatch_main_q);
}

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

/// Run `work(ctx)` on the main thread's queue (serviced by the run loop).
pub fn asyncMain(ctx: ?*anyopaque, work: DispatchFn) void {
    dispatch_async_f(mainQueue(), ctx, work);
}

/// Run `work(ctx)` on the main queue after `ms` milliseconds.
pub fn afterMain(ms: u32, ctx: ?*anyopaque, work: DispatchFn) void {
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, @as(i64, ms) * std.time.ns_per_ms), mainQueue(), ctx, work);
}

extern var _dispatch_source_type_signal: u8;
extern "c" fn dispatch_source_create(kind: *const anyopaque, handle: usize, mask: usize, queue: ?*anyopaque) ?*anyopaque;
extern "c" fn dispatch_source_set_event_handler_f(source: *anyopaque, handler: ?DispatchFn) void;
extern "c" fn dispatch_source_cancel(source: *anyopaque) void;
extern "c" fn dispatch_resume(object: *anyopaque) void;

/// Run `handler(null)` on the main queue each time signal `sig` arrives.
/// The signal's default action must be disabled separately (SIG_IGN), or it
/// still runs. Null if the source can't be created; `cancelSource` it.
pub fn signalSource(sig: std.posix.SIG, handler: DispatchFn) ?*anyopaque {
    const source = dispatch_source_create(@ptrCast(&_dispatch_source_type_signal), @intFromEnum(sig), 0, mainQueue()) orelse return null;
    dispatch_source_set_event_handler_f(source, handler);
    dispatch_resume(source);
    return source;
}

extern var _dispatch_source_type_proc: u8;
const DISPATCH_PROC_EXIT: usize = 0x80000000;

/// Run `handler(null)` on the main queue when process `pid` exits. Null if
/// the source can't be created (e.g. no such process); `cancelSource` it.
pub fn processExitSource(pid: std.c.pid_t, handler: DispatchFn) ?*anyopaque {
    const source = dispatch_source_create(@ptrCast(&_dispatch_source_type_proc), @intCast(pid), DISPATCH_PROC_EXIT, mainQueue()) orelse return null;
    dispatch_source_set_event_handler_f(source, handler);
    dispatch_resume(source);
    return source;
}

extern var _dispatch_source_type_memorypressure: u8;
extern "c" fn dispatch_source_get_data(source: *anyopaque) usize;
const DISPATCH_MEMORYPRESSURE_WARN: usize = 0x2;
const DISPATCH_MEMORYPRESSURE_CRITICAL: usize = 0x4;

/// Run `handler(null)` on the main queue when the system's memory pressure
/// rises to warn or critical (`sourceData` says which). Null if the source
/// can't be created; `cancelSource` it.
pub fn memoryPressureSource(handler: DispatchFn) ?*anyopaque {
    const source = dispatch_source_create(@ptrCast(&_dispatch_source_type_memorypressure), 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, mainQueue()) orelse return null;
    dispatch_source_set_event_handler_f(source, handler);
    dispatch_resume(source);
    return source;
}

/// The pending data of `source` (in its event handler).
pub fn sourceData(source: *anyopaque) usize {
    return dispatch_source_get_data(source);
}

pub fn cancelSource(source: *anyopaque) void {
    dispatch_source_cancel(source);
    dispatch_release(source);
}

pub const Semaphore = struct {
    handle: *anyopaque,

    pub fn create() error{SemaphoreCreateFailed}!Semaphore {
        return .{ .handle = dispatch_semaphore_create(0) orelse return error.SemaphoreCreateFailed };
    }

    pub fn wait(self: Semaphore) void {
        _ = dispatch_semaphore_wait(self.handle, DISPATCH_TIME_FOREVER); // only times out with a finite timeout
    }

    pub fn signal(self: Semaphore) void {
        _ = dispatch_semaphore_signal(self.handle); // returns whether a waiter was woken
    }

    pub fn deinit(self: Semaphore) void {
        dispatch_release(self.handle);
    }
};

// ---------------------------------------------------------------------------
// Blocks (Clang block ABI): blocks.zig
// ---------------------------------------------------------------------------

const blocks = @import("blocks.zig");
pub const BlockLiteral = blocks.BlockLiteral;
pub const BlockDescriptor = blocks.BlockDescriptor;
pub const globalBlock = blocks.globalBlock;
pub const ContextBlock = blocks.ContextBlock;
pub const contextBlock = blocks.contextBlock;
pub const ManagedBlock = blocks.ManagedBlock;
pub const managedBlock = blocks.managedBlock;
pub const callBlock = blocks.callBlock;
pub const copyBlock = blocks.copyBlock;
pub const releaseBlock = blocks.releaseBlock;

test {
    std.testing.refAllDecls(@This());
}
