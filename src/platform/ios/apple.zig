//! Helpers over the Objective-C runtime for the UIKit / WebKit backend:
//! class lookup and definition, NSString conversion, geometry, Grand Central
//! Dispatch and blocks. The iOS counterpart of `platform/macos/cocoa.zig`,
//! over `platform/apple/objc.zig` (no SDK headers needed to type-check).
//!
//! Memory rules (manual retain/release): objects from `alloc`/`new`/`copy`
//! are owned (+1) and released once; anything else is borrowed.

const std = @import("std");
pub const objc = @import("../apple/objc.zig");

pub const c = objc.c;
pub const id = c.id;
pub const Object = objc.Object;
pub const Class = objc.Class;

pub const NSUTF8StringEncoding: c_ulong = 4;

pub const CGPoint = extern struct { x: f64, y: f64 };
pub const CGSize = extern struct { width: f64, height: f64 };
pub const CGRect = extern struct { origin: CGPoint, size: CGSize };

pub fn class(name: [:0]const u8) Class {
    return objc.getClass(name) orelse std.debug.panic("Objective-C class {s} not found", .{name});
}

pub fn boolean(value: bool) c.BOOL {
    return if (c.BOOL == bool) value else @intFromBool(value);
}

pub fn isTrue(value: c.BOOL) bool {
    return if (c.BOOL == bool) value else value != 0;
}

pub const nil: Object = .{ .value = null };

/// A new NSString (+1) with a copy of `bytes`, or null if not UTF-8.
pub fn nsString(bytes: []const u8) ?Object {
    const alloc = class("NSString").msgSend(Object, "alloc", .{});
    const str = alloc.msgSend(Object, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(c_ulong, bytes.len), NSUTF8StringEncoding });
    return if (str.value == null) null else str;
}

/// UTF-8 view of an NSString (borrowed: valid while `str` and the pool live).
pub fn utf8(str: Object) ?[:0]const u8 {
    if (str.value == null) return null;
    const p = str.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(p);
}

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

pub fn addProtocol(cls: Class, name: [:0]const u8) void {
    if (objc.getProtocol(name)) |proto| _ = c.class_addProtocol(cls.value, proto.value);
}

var class_counter: std.atomic.Value(u32) = .init(0);

/// Define and register an NSObject subclass named `<prefix><n>`;
/// `methods` is a tuple of `.{ "selector:", fn }`.
pub fn defineClass(comptime prefix: []const u8, protocols: []const [:0]const u8, methods: anytype) Class {
    return defineSubclass(prefix, "NSObject", protocols, methods);
}

pub fn defineSubclass(comptime prefix: []const u8, comptime superclass: [:0]const u8, protocols: []const [:0]const u8, methods: anytype) Class {
    const n = class_counter.fetchAdd(1, .monotonic);
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

fn mainQueue() *anyopaque {
    return @ptrCast(&_dispatch_main_q);
}

pub fn isMainThread() bool {
    return pthread_main_np() != 0;
}

pub fn asyncMain(ctx: ?*anyopaque, work: DispatchFn) void {
    dispatch_async_f(mainQueue(), ctx, work);
}

pub fn afterMain(ms: u32, ctx: ?*anyopaque, work: DispatchFn) void {
    dispatch_after_f(dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms), mainQueue(), ctx, work);
}

pub const Semaphore = struct {
    handle: *anyopaque,

    pub fn create() error{SemaphoreCreateFailed}!Semaphore {
        return .{ .handle = dispatch_semaphore_create(0) orelse return error.SemaphoreCreateFailed };
    }

    pub fn wait(self: Semaphore) void {
        _ = dispatch_semaphore_wait(self.handle, ~@as(u64, 0));
    }

    pub fn signal(self: Semaphore) void {
        _ = dispatch_semaphore_signal(self.handle);
    }

    pub fn deinit(self: Semaphore) void {
        dispatch_release(self.handle);
    }
};

// ---------------------------------------------------------------------------
// Blocks (Clang block ABI): ../apple/blocks.zig
// ---------------------------------------------------------------------------

const blocks = @import("../apple/blocks.zig");
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
