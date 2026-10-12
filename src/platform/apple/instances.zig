//! One instance per app class on Apple platforms: a class listed both as an
//! app extension (`AppOptions.extensions[].ios`, constructed on its worker
//! when it loads) and as a platform hook (`.ios.hooks` / `.macos.hooks`,
//! constructed on the main thread at launch) is constructed once, and both
//! get that object. Kept for the process's life (+1, never released).

const std = @import("std");
const objc = @import("objc.zig");
const extension_spec = @import("../../core/extension_spec.zig");
const hooks_spec = @import("hooks_spec.zig");

const Object = objc.Object;

/// Every extension and every hook a distinct class: the most there can be.
pub const max_instances = extension_spec.max_extensions + hooks_spec.max_hooks;

const Entry = struct { cls: *anyopaque, obj: Object };

var entries: [max_instances]Entry = undefined;
var count: usize = 0;
var mutex: std.c.pthread_mutex_t = .{};

/// The app's instance of `cls`: made with `[[cls alloc] init]` on first use
/// (any thread; the caller holds an autorelease pool), else the one made
/// before. Null when `init` returns nil or the table is full. The class's
/// `init` runs under a lock: it must not construct another hook or
/// extension.
pub fn of(cls: objc.Class) ?Object {
    _ = std.c.pthread_mutex_lock(&mutex); // only fails for invalid or deadlocking use
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    for (entries[0..count]) |e| if (e.cls == cls.value) return e.obj;
    if (count == max_instances) return null;
    const obj = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
    if (obj.value == null) return null;
    entries[count] = .{ .cls = cls.value, .obj = obj };
    count += 1;
    return obj;
}
