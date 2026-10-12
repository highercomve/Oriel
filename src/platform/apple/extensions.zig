//! The Objective-C backend of `oriel.extensions` (iOS): the app's class
//! conforming to `OrielAppExtension` (src/platform/ios/include/
//! oriel_extension.h), compiled from `.ios.sources` / `.ios.swift_sources`
//! and found by name with `objc_getClass` at load. Oriel defines the
//! `OrielExtensionContext` and `OrielCall` classes the protocol passes at
//! run time, so the header needs no implementation to link against.
//!
//! Calls run on the extension's worker thread, inside an autorelease pool.
//! Objective-C exceptions aren't caught: an implementation reports failure
//! with its `NSError **`.

const std = @import("std");
const objc = @import("objc.zig");
const instances = @import("instances.zig");
const extensions = @import("../../core/extensions.zig");
const lifecycle = @import("../../core/lifecycle.zig");

const log = std.log.scoped(.extensions);
const c = objc.c;
const Object = objc.Object;

pub const impl: extensions.Impl = .{ .call = call, .load = load, .lifecycle = onLifecycle };

const NSUTF8StringEncoding: c_ulong = 4;

/// The indexed ivars of OrielExtensionContext / OrielCall instances.
const Ivars = extern struct {
    index: usize,
    call_id: u64,
};

var classes_once = std.atomic.Value(u8).init(0); // 0 none, 1 defining, 2 ready
var context_class: ?objc.Class = null;
var call_class: ?objc.Class = null;

/// Define OrielExtensionContext and its subclass OrielCall (once, any thread).
fn defineClasses() bool {
    if (classes_once.load(.acquire) == 2) return context_class != null;
    if (classes_once.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) {
        // Another worker defines them; bounded spin (the definition is quick).
        for (0..1_000_000) |_| {
            if (classes_once.load(.acquire) == 2) break;
            std.atomic.spinLoopHint();
        }
        return context_class != null;
    }
    defer classes_once.store(2, .release);
    const ns_object = objc.getClass("NSObject") orelse return false;
    const ctx_cls = objc.allocateClassPair(ns_object, "OrielExtensionContext") orelse return false;
    if (!ctx_cls.addMethod("name", ctxName) or !ctx_cls.addMethod("emit:data:", ctxEmit)) return false;
    objc.registerClassPair(ctx_cls);
    const call_cls = objc.allocateClassPair(ctx_cls, "OrielCall") orelse return false;
    if (!call_cls.addMethod("cancelled", callCancelled)) return false;
    objc.registerClassPair(call_cls);
    context_class = ctx_cls;
    call_class = call_cls;
    return true;
}

fn ivars(self: c.id) *Ivars {
    return @ptrCast(@alignCast(c.object_getIndexedIvars(self).?));
}

/// A new (+1) context or call object.
fn newObject(cls: objc.Class, index: usize, call_id: u64) ?Object {
    const raw = c.class_createInstance(cls.value, @sizeOf(Ivars)) orelse return null;
    ivars(raw).* = .{ .index = index, .call_id = call_id };
    return (Object{ .value = raw }).msgSend(Object, "init", .{});
}

fn ctxName(self: c.id, _: c.SEL) callconv(.c) c.id {
    const r = runnerAt(ivars(self).index) orelse return null;
    const s = nsString(r.name) orelse return null;
    return s.msgSend(Object, "autorelease", .{}).value;
}

fn ctxEmit(self: c.id, _: c.SEL, name: c.id, data: c.id) callconv(.c) void {
    const r = runnerAt(ivars(self).index) orelse return;
    const event = utf8(.{ .value = name }) orelse return;
    extensions.emitByName(r.name, event, bytesOf(.{ .value = data }));
}

fn callCancelled(self: c.id, _: c.SEL) callconv(.c) c.BOOL {
    const v = extensions.cancelledById(ivars(self).call_id);
    return if (c.BOOL == bool) v else @intFromBool(v);
}

fn runnerAt(index: usize) ?*extensions.Runner {
    return extensions.runnerAt(index);
}

fn load(ctx: *extensions.Context) anyerror!void {
    if (!defineClasses()) return error.Unavailable;
    const name = try ctx.arena.dupeZ(u8, ctx.runner.class);
    const cls = objc.getClass(name) orelse {
        log.err("{s}: no Objective-C class {s} (is its source in .ios.sources or .ios.swift_sources?)", .{ ctx.name, name });
        return error.Unavailable;
    };
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    // Kept for the process's life; the same object when the class is also
    // a platform hook (.ios.hooks).
    const obj = instances.of(cls) orelse return error.Unavailable;
    ctx.runner.native = obj.value;
    if (obj.getClass()) |k| if (k.respondsToSelector(objc.sel("load:"))) {
        const context = newObject(context_class.?, ctx.runner.index, 0) orelse return;
        defer context.release();
        obj.msgSend(void, "load:", .{context});
    };
}

fn call(ctx: *extensions.Context, method: []const u8, input: []const u8) anyerror![]const u8 {
    const obj: Object = .{ .value = ctx.runner.native orelse return error.Unavailable };
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const m = nsString(method) orelse return error.InvalidMethod;
    defer m.release();
    const data = objc.getClass("NSData").?.msgSend(Object, "dataWithBytes:length:", .{ input.ptr, @as(c_ulong, input.len) });
    const call_obj = newObject(call_class.?, ctx.runner.index, ctx.callId()) orelse return error.OutOfMemory;
    defer call_obj.release();
    var err: c.id = null;
    const reply = obj.msgSend(Object, "callMethod:input:call:error:", .{ m, data, call_obj, &err });
    if (err != null and reply.value == null) {
        if (ctx.isCancelled()) return error.Cancelled;
        const e: Object = .{ .value = err };
        const domain = utf8(e.msgSend(Object, "domain", .{})) orelse "NSError";
        const code = e.msgSend(isize, "code", .{});
        const text = utf8(e.msgSend(Object, "localizedDescription", .{})) orelse "";
        var buf: [96]u8 = undefined;
        if (ctx.diagnostics()) |d| d.set(std.fmt.bufPrint(&buf, "{s}:{d}", .{ domain, code }) catch domain, text);
        return error.ExtensionFailed;
    }
    // nil without an error: an empty reply.
    if (reply.value == null) return "";
    return ctx.arena.dupe(u8, bytesOf(reply));
}

fn onLifecycle(r: *extensions.Runner, event: lifecycle.Event) void {
    const obj: Object = .{ .value = r.native orelse return };
    const k = obj.getClass() orelse return;
    if (!k.respondsToSelector(objc.sel("lifecycle:level:"))) return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const name = nsString(event.name()) orelse return;
    defer name.release();
    const level: ?Object = switch (event) {
        .memory_pressure => |p| nsString(@tagName(p)),
        else => null,
    };
    defer if (level) |l| l.release();
    obj.msgSend(void, "lifecycle:level:", .{ name, if (level) |l| l else Object{ .value = null } });
}

fn nsString(bytes: []const u8) ?Object {
    const alloc = (objc.getClass("NSString") orelse return null).msgSend(Object, "alloc", .{});
    const s = alloc.msgSend(Object, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(c_ulong, bytes.len), NSUTF8StringEncoding });
    return if (s.value == null) null else s;
}

fn utf8(s: Object) ?[]const u8 {
    if (s.value == null) return null;
    const p = s.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return null;
    return std.mem.span(p);
}

/// An NSData's bytes (borrowed).
fn bytesOf(data: Object) []const u8 {
    if (data.value == null) return "";
    const len = data.msgSend(c_ulong, "length", .{});
    if (len == 0) return "";
    const p = data.msgSend(?[*]const u8, "bytes", .{}) orelse return "";
    return p[0..len];
}
