//! Bluetooth's permission on macOS and iOS (`rt`: platform/macos/cocoa.zig
//! or platform/ios/apple.zig).
//!
//! - status: `CBManager.authorization` (macOS 10.15, iOS 13.1).
//! - request: a CBCentralManager (no power alert): creating one shows the
//!   system prompt while undecided; its first `centralManagerDidUpdateState:`
//!   comes once the user answers (or at once when decided), and the
//!   authorization then is the answer.
//!
//! CoreBluetooth is loaded when first asked (dlopen), not linked: the
//! permission is declarable without the bluetooth module, which links it.

const std = @import("std");
const common = @import("common.zig");

const Kind = common.Kind;
const Status = common.Status;
const Done = *const fn (Kind, Status) void;

// CBManagerAuthorization
const not_determined: isize = 0;
const restricted: isize = 1;
const denied: isize = 2;
const allowed_always: isize = 3;

const framework = "/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth";

pub fn Bluetooth(comptime rt: type) type {
    return struct {
        const Object = rt.Object;

        var loaded = std.atomic.Value(bool).init(false);

        fn load() bool {
            if (loaded.load(.acquire)) return true;
            if (std.c.dlopen(framework, .{ .LAZY = true }) == null) return false;
            loaded.store(true, .release);
            return true;
        }

        fn fromAuthorization(a: isize) Status {
            return switch (a) {
                allowed_always => .granted,
                denied, restricted => .denied,
                not_determined => .prompt,
                else => .unknown,
            };
        }

        /// The class property, or null without CoreBluetooth (or before
        /// macOS 10.15 / iOS 13.1).
        fn authorization() ?isize {
            if (!load()) return null;
            const cls = rt.objc.getClass("CBManager") orelse return null;
            if (!cls.respondsToSelector(rt.objc.sel("authorization"))) return null;
            return cls.msgSend(isize, "authorization", .{});
        }

        pub fn status() Status {
            return fromAuthorization(authorization() orelse return .unknown);
        }

        // Requests while the manager is up (main thread only).
        var waiters: [16]?Done = @splat(null);
        var manager: Object = rt.nil;
        var delegate_class: ?rt.Class = null;

        pub fn request(done: Done) void {
            const a = authorization() orelse return done(.bluetooth, .unknown);
            if (a != not_determined) return done(.bluetooth, fromAuthorization(a));
            // The manager and its callback live on the main queue.
            rt.asyncMain(@ptrCast(@constCast(done)), start);
        }

        fn start(ctx: ?*anyopaque) callconv(.c) void {
            const done: Done = @ptrCast(@alignCast(ctx.?));
            for (&waiters) |*w| {
                if (w.* == null) {
                    w.* = done;
                    break;
                }
            } else return done(.bluetooth, .unknown); // too many at once
            if (manager.value != null) return; // already asking
            const cls = rt.objc.getClass("CBCentralManager") orelse return finish(.unknown);
            if (delegate_class == null) delegate_class = rt.defineClass("OrielBluetoothPermission", &.{"CBCentralManagerDelegate"}, .{
                .{ "centralManagerDidUpdateState:", didUpdateState },
            });
            const delegate = rt.new(delegate_class.?);
            // CBCentralManagerOptionShowPowerAlertKey: no "turn Bluetooth on"
            // alert, only the permission's.
            const key = rt.nsString("kCBInitOptionShowPowerAlert") orelse return finish(.unknown);
            defer key.release();
            const options = rt.class("NSDictionary").msgSend(Object, "dictionaryWithObject:forKey:", .{
                rt.class("NSNumber").msgSend(Object, "numberWithBool:", .{rt.boolean(false)}), key,
            });
            // The manager keeps its delegate weakly: ours lives as long.
            manager = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithDelegate:queue:options:", .{ delegate, rt.nil, options });
            delegate_holder = delegate;
        }

        var delegate_holder: Object = rt.nil;

        fn didUpdateState(_: rt.id, _: rt.c.SEL, _: rt.id) callconv(.c) void {
            const a = authorization() orelse return finish(.unknown);
            // Still undecided: the prompt is up; another update follows.
            if (a == not_determined) return;
            finish(fromAuthorization(a));
        }

        fn finish(s: Status) void {
            if (manager.value != null) {
                manager.msgSend(void, "setDelegate:", .{rt.nil});
                manager.release();
                manager = rt.nil;
            }
            if (delegate_holder.value != null) {
                delegate_holder.release();
                delegate_holder = rt.nil;
            }
            for (&waiters) |*w| if (w.*) |done| {
                w.* = null;
                done(.bluetooth, s);
            };
        }
    };
}

