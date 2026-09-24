//! Small helpers over zig-objc for the AppKit / WebKit backend: class lookup,
//! NSString conversion, geometry structs, Grand Central Dispatch and blocks.
//!
//! Memory rules (manual retain/release, no ARC): objects from `alloc`/`new`/
//! `copy` are owned (+1) and must be released once; anything else is
//! borrowed (autoreleased or owned by its container). Code that creates
//! autoreleased objects outside the AppKit event loop runs inside an
//! `objc.AutoreleasePool`.

const std = @import("std");
pub const objc = @import("objc");

pub const c = objc.c;
pub const id = c.id;
pub const Object = objc.Object;
pub const Class = objc.Class;

pub const NSUTF8StringEncoding: c_ulong = 4;

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

/// The class `name`. Every class used here ships with AppKit, Foundation or
/// WebKit (linked by build.zig), so a missing one is a broken install.
pub fn class(name: [:0]const u8) Class {
    return objc.getClass(name) orelse std.debug.panic("Objective-C class {s} not found", .{name});
}

/// Objective-C BOOL from a Zig bool (BOOL is `bool` on arm64, `i8` on x86_64).
pub fn boolean(value: bool) c.BOOL {
    return switch (c.BOOL) {
        bool => value,
        else => @intFromBool(value),
    };
}

pub fn isTrue(value: c.BOOL) bool {
    return switch (c.BOOL) {
        bool => value,
        else => value != 0,
    };
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

/// `obj.absoluteString` of an NSURL as UTF-8 (borrowed, see `utf8`).
pub fn urlString(url: Object) ?[:0]const u8 {
    if (url.value == null) return null;
    return utf8(url.msgSend(Object, "absoluteString", .{}));
}

/// Adopt a protocol if the runtime knows it (protocols without metadata in a
/// loaded image aren't registered; AppKit/WebKit only check selectors).
pub fn addProtocol(cls: Class, name: [:0]const u8) void {
    if (objc.getProtocol(name)) |proto| _ = c.class_addProtocol(cls.value, proto.value);
}

var class_counter: std.atomic.Value(u32) = .init(0);

/// Define and register an NSObject subclass named `<prefix><n>`: the
/// counter keeps names unique when several app configs are compiled into
/// one binary (e.g. the smoke app's GUI and auto-quit configs).
/// `methods` is a tuple of `.{ "selector:", fn }`. Classes are never
/// disposed: they live as long as the process.
pub fn defineClass(comptime prefix: []const u8, protocols: []const [:0]const u8, methods: anytype) Class {
    const n = class_counter.fetchAdd(1, .monotonic);
    // The runtime keeps using the name, so it must outlive the class: never freed.
    const name = std.fmt.allocPrintSentinel(std.heap.smp_allocator, "{s}{d}", .{ prefix, n }, 0) catch
        std.debug.panic("out of memory defining {s}", .{prefix});
    const cls = objc.allocateClassPair(class("NSObject"), name) orelse
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

/// Run `work(ctx)` on the main thread's queue (serviced by the AppKit run loop).
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
// Blocks received from AppKit/WebKit (Clang block ABI)
// ---------------------------------------------------------------------------

/// The common header of every block literal; `invoke` takes the block
/// itself first, then the block's arguments.
pub const BlockLiteral = extern struct {
    isa: ?*anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const anyopaque,
};

extern "c" fn _Block_copy(block: ?*const anyopaque) ?*anyopaque;
extern "c" fn _Block_release(block: ?*const anyopaque) void;

/// Call a block received as an `id` with `args`; `Args` are the block's
/// parameter types (after the implicit block pointer).
pub fn callBlock(block: id, comptime Args: type, args: Args) void {
    const lit: *BlockLiteral = @ptrCast(@alignCast(block.?));
    const params = @typeInfo(Args).@"struct".fields;
    const Fn = switch (params.len) {
        1 => fn (*BlockLiteral, params[0].type) callconv(.c) void,
        2 => fn (*BlockLiteral, params[0].type, params[1].type) callconv(.c) void,
        else => @compileError("unsupported block arity"),
    };
    const f: *const Fn = @ptrCast(@alignCast(lit.invoke));
    @call(.auto, f, .{lit} ++ args);
}

/// Keep a block received as an argument past the call (+1; `releaseBlock`
/// it). Null only when out of memory.
pub fn copyBlock(block: id) id {
    return @ptrCast(@alignCast(_Block_copy(block)));
}

pub fn releaseBlock(block: id) void {
    _Block_release(block);
}

test {
    std.testing.refAllDecls(@This());
}
