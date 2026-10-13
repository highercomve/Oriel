//! Platform hooks on iOS and macOS: the app's classes conforming to
//! `OrielPlatformHooks` (include/oriel_hooks.h), declared in build.zig with
//! `.ios.hooks` / `.macos.hooks` and listed in the generated
//! `oriel_apple_hooks` module (`classes`, in declaration order).
//!
//! `start` constructs them once at launch (main thread, before the first
//! scene or window) through `instances.of`, asks `respondsToSelector:` once
//! per method, and sends `registered:`. The shells and windows then call the
//! functions here at the matching points: notifications go to every hook
//! that implements the method, in order; interceptions stop at the first
//! hook that returns YES (it owns the request and its handler).
//!
//! Main thread only (UIKit, AppKit and WebKit call the delegates there), so
//! there is no locking. Blocks (decision handlers) are passed through as
//! received: a hook that keeps one copies it (ARC and Swift do).

const std = @import("std");
const builtin = @import("builtin");
const apple = @import("apple.zig");
const objc = apple.objc;
const instances = @import("instances.zig");
const spec = @import("hooks_spec.zig");
const declared = @import("oriel_apple_hooks");

const id = apple.id;
pub const Method = spec.Method;
const c = objc.c;
const Object = objc.Object;
const log = std.log.scoped(.hooks);

pub const platform: spec.Platform = if (builtin.os.tag == .ios) .ios else .macos;

comptime {
    if (declared.classes.len > spec.max_hooks) @compileError("more than 16 platform hooks");
}

const Hook = struct {
    obj: Object,
    responds: std.EnumSet(Method),
};

var hooks: [spec.max_hooks]Hook = undefined;
var hook_count: usize = 0;
var started = false;

/// The view controller in front (iOS) or the key window (macOS), for
/// `OrielHooksContext`; set by `start`.
pub const FrontFn = *const fn () id;
var front_fn: ?FrontFn = null;

/// Whether any hook is registered.
pub fn active() bool {
    return hook_count > 0;
}

/// Construct the declared hooks (once; later calls do nothing). `front`
/// answers the context's presentingViewController / keyWindow.
pub fn start(front: FrontFn) void {
    if (started) return;
    started = true;
    front_fn = front;
    if (declared.classes.len == 0) return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const ctx_cls = contextClass() orelse {
        log.err("could not define OrielHooksContext: platform hooks are off", .{});
        return;
    };
    for (declared.classes, 0..) |name, index| {
        const cls = objc.getClass(name) orelse {
            log.err("no Objective-C class {s} (is its source in .{s}.hooks[].sources or .swift_sources, or in an extension's? A Swift class needs @objc({s}))", .{ name, @tagName(platform), name });
            continue;
        };
        const obj = instances.of(cls) orelse {
            log.err("{s}: -init returned nil", .{name});
            continue;
        };
        var responds = std.EnumSet(Method).initEmpty();
        for (std.enums.values(Method)) |m| {
            const s = spec.selector(m, platform) orelse continue;
            if (cls.respondsToSelector(objc.sel(s))) responds.insert(m);
        }
        hooks[hook_count] = .{ .obj = obj, .responds = responds };
        hook_count += 1;
        if (!responds.contains(.registered)) continue;
        // Kept for the process's life: the hook may hold on to it.
        const context = newContext(ctx_cls, index) orelse {
            log.err("{s}: no memory for its context", .{name});
            continue;
        };
        obj.msgSend(void, "registered:", .{context});
    }
    log.debug("{d} platform hook(s) registered", .{hook_count});
}

/// Send `m` to every hook implementing it, in declaration order. `args`
/// are the method's arguments (raw ids, BOOLs, NSIntegers).
pub fn notify(comptime m: Method, args: anytype) void {
    comptime std.debug.assert(!m.intercepts());
    const s = comptime spec.selector(m, platform) orelse @compileError(@tagName(m) ++ " is not a hook on this platform");
    comptime std.debug.assert(args.len == spec.arityOn(m, platform));
    if (hook_count == 0) return;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    for (hooks[0..hook_count]) |h| {
        if (h.responds.contains(m)) h.obj.msgSend(void, s, args);
    }
}

/// Offer `m` to the hooks in declaration order: true when one returned YES
/// (it owns the request; nothing else may answer it).
pub fn intercept(comptime m: Method, args: anytype) bool {
    comptime std.debug.assert(m.intercepts());
    const s = comptime spec.selector(m, platform) orelse @compileError(@tagName(m) ++ " is not a hook on this platform");
    comptime std.debug.assert(args.len == spec.arityOn(m, platform));
    if (hook_count == 0) return false;
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    for (hooks[0..hook_count]) |h| {
        if (!h.responds.contains(m)) continue;
        if (apple.isTrue(h.obj.msgSend(c.BOOL, s, args))) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The calls with a window label (a WebView or an NSWindow): the label is
// remembered by object until it is destroyed.
// ---------------------------------------------------------------------------

/// Before a window's WKWebView is created.
pub fn webViewConfiguration(configuration: id, label: []const u8) void {
    if (hook_count == 0) return;
    const name = apple.nsString(label) orelse return;
    defer name.release();
    notify(.web_view_configuration, .{ configuration, name });
}

/// A window's WKWebView exists, with Oriel's delegates, before it loads.
pub fn webViewCreated(web_view: id, label: []const u8) void {
    created(.web_view_created, web_view, label);
}

/// A window's WKWebView is about to go (only for one `webViewCreated` saw).
pub fn webViewDestroyed(web_view: id) void {
    destroyed(.web_view_destroyed, web_view);
}

/// macOS: an Oriel NSWindow was created.
pub fn windowCreated(window: id, label: []const u8) void {
    if (platform == .macos) created(.window_created, window, label);
}

/// macOS: an Oriel NSWindow is closing.
pub fn windowWillClose(window: id) void {
    if (platform == .macos) destroyed(.window_will_close, window);
}

fn created(comptime m: Method, obj: id, label: []const u8) void {
    if (hook_count == 0 or obj == null) return;
    const name = apple.nsString(label) orelse return;
    defer name.release();
    track(obj, name);
    notify(m, .{ obj, name });
}

fn destroyed(comptime m: Method, obj: id) void {
    if (hook_count == 0 or obj == null) return;
    const name = untrack(obj) orelse return;
    defer name.release();
    notify(m, .{ obj, name });
}

const Tracked = struct { obj: id, label: Object };
var tracked: [spec.max_tracked]Tracked = undefined;
var tracked_count: usize = 0;

/// Remember `obj`'s label (retained).
fn track(obj: id, label: Object) void {
    for (tracked[0..tracked_count]) |*t| if (t.obj == obj) {
        // A new object at a freed one's address: the old entry is stale.
        t.label.release();
        t.label = label.retain();
        return;
    };
    if (tracked_count == tracked.len) {
        log.warn("more than {d} live windows: webViewDestroyed / windowWillClose won't reach the hooks for the newest", .{tracked.len});
        return;
    }
    tracked[tracked_count] = .{ .obj = obj, .label = label.retain() };
    tracked_count += 1;
}

/// Forget `obj`: its label (+1), or null when it wasn't tracked.
fn untrack(obj: id) ?Object {
    for (tracked[0..tracked_count], 0..) |t, i| {
        if (t.obj != obj) continue;
        tracked_count -= 1;
        tracked[i] = tracked[tracked_count];
        return t.label;
    }
    return null;
}

// ---------------------------------------------------------------------------
// OrielHooksContext
// ---------------------------------------------------------------------------

var context_class: ?objc.Class = null;

/// Define OrielHooksContext (main thread, once): `name` and the front
/// controller / window.
fn contextClass() ?objc.Class {
    if (context_class) |k| return k;
    if (objc.getClass("OrielHooksContext")) |existing| {
        context_class = existing;
        return existing;
    }
    const ns_object = objc.getClass("NSObject") orelse return null;
    const cls = objc.allocateClassPair(ns_object, "OrielHooksContext") orelse return null;
    if (!cls.addMethod("name", ctxName)) return null;
    if (!cls.addMethod("presentingViewController", ctxFront)) return null;
    if (!cls.addMethod("keyWindow", ctxFront)) return null;
    objc.registerClassPair(cls);
    context_class = cls;
    return cls;
}

/// A new (+1) context for hook `index` (its class name).
fn newContext(cls: objc.Class, index: usize) ?Object {
    const raw = c.class_createInstance(cls.value, @sizeOf(usize)) orelse return null;
    const slot: *usize = @ptrCast(@alignCast(c.object_getIndexedIvars(raw) orelse return null));
    slot.* = index;
    const obj = (Object{ .value = raw }).msgSend(Object, "init", .{});
    return if (obj.value == null) null else obj;
}

fn ctxName(self: c.id, _: c.SEL) callconv(.c) c.id {
    const slot: *const usize = @ptrCast(@alignCast(c.object_getIndexedIvars(self) orelse return null));
    if (slot.* >= declared.classes.len) return null;
    const s = apple.nsString(declared.classes[slot.*]) orelse return null;
    return s.msgSend(Object, "autorelease", .{}).value;
}

fn ctxFront(_: c.id, _: c.SEL) callconv(.c) c.id {
    const f = front_fn orelse return null;
    return f();
}

test {
    std.testing.refAllDecls(@This());
}
