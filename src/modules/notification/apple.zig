//! Click actions for UNUserNotificationCenter, shared by macOS and iOS.
//!
//! Buttons are a notification category (`UNNotificationCategory`) whose
//! identifier is derived from the buttons, registered once per distinct set.
//! The notification's own id travels in `userInfo` ("oriel.id"), so a
//! notification without one reports "" like on the other platforms. The
//! center's delegate (`didReceiveNotificationResponse:`) reports clicks;
//! `extra_methods` adds platform delegate methods (iOS: `willPresent`).
//!
//! `h` is the platform's Objective-C helper module (`cocoa` or `apple`) and
//! `complete` calls a `void (^)(void)` completion handler.

const std = @import("std");
const common = @import("common.zig");

pub fn Actions(comptime h: type, comptime complete: fn (h.id) void, comptime extra_methods: anytype) type {
    return struct {
        const Object = h.Object;

        var delegate: Object = h.nil; // main thread only
        var categories: Object = h.nil; // NSMutableSet, main thread only

        const id_key = "oriel.id";
        const default_action = "com.apple.UNNotificationDefaultActionIdentifier";

        /// Set the center's delegate once (main thread). It is weak: this one
        /// lives for the process.
        pub fn installDelegate(center: Object) void {
            if (delegate.value != null) return;
            delegate = h.new(h.defineClass("OrielNotificationDelegate", &.{"UNUserNotificationCenterDelegate"}, .{
                .{ "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:", didReceive },
            } ++ extra_methods));
            center.msgSend(void, "setDelegate:", .{delegate});
        }

        /// Put the id and the buttons on `content` (main thread, inside an
        /// autorelease pool).
        pub fn apply(center: Object, content: Object, options: common.NotificationOptions) !void {
            const key = h.nsString(id_key) orelse unreachable; // ASCII
            defer key.release();
            const value = h.nsString(options.id orelse "") orelse return error.InvalidUtf8;
            defer value.release();
            const info = h.class("NSDictionary").msgSend(Object, "dictionaryWithObject:forKey:", .{ value, key });
            content.msgSend(void, "setUserInfo:", .{info});

            if (options.actions.len == 0) return;
            var hasher = std.hash.Wyhash.init(0);
            for (options.actions) |a| {
                hasher.update(a.id);
                hasher.update("\x00");
                hasher.update(a.label);
                hasher.update("\x00");
            }
            var cat_buf: [32]u8 = undefined;
            const cat_text = std.fmt.bufPrint(&cat_buf, "oriel-{x:0>16}", .{hasher.final()}) catch unreachable; // fits
            const cat_id = h.nsString(cat_text) orelse unreachable; // ASCII
            defer cat_id.release();
            try register(center, cat_id, options.actions);
            content.msgSend(void, "setCategoryIdentifier:", .{cat_id});
        }

        fn register(center: Object, cat_id: Object, actions: []const common.Action) !void {
            if (categories.value == null) categories = h.new(h.class("NSMutableSet"));
            const UNNotificationAction = h.class("UNNotificationAction");
            var items: [16]h.id = undefined;
            const n = @min(actions.len, items.len);
            for (actions[0..n], 0..) |a, i| {
                const aid = h.nsString(a.id) orelse return error.InvalidUtf8;
                defer aid.release();
                const label = h.nsString(a.label) orelse return error.InvalidUtf8;
                defer label.release();
                items[i] = UNNotificationAction.msgSend(Object, "actionWithIdentifier:title:options:", .{ aid, label, @as(c_ulong, 0) }).value;
            }
            // Already registered: same id means the same buttons.
            const enumerator = categories.msgSend(Object, "objectEnumerator", .{});
            while (true) {
                const cat = enumerator.msgSend(Object, "nextObject", .{});
                if (cat.value == null) break;
                const existing = cat.msgSend(Object, "identifier", .{});
                if (h.isTrue(existing.msgSend(h.c.BOOL, "isEqualToString:", .{cat_id}))) return;
            }
            const array = h.class("NSArray").msgSend(Object, "arrayWithObjects:count:", .{ @as([*]h.id, &items), @as(c_ulong, n) });
            const empty = h.class("NSArray").msgSend(Object, "array", .{});
            const category = h.class("UNNotificationCategory").msgSend(Object, "categoryWithIdentifier:actions:intentIdentifiers:options:", .{ cat_id, array, empty, @as(c_ulong, 0) });
            if (category.value == null) return error.NotificationCreateFailed;
            categories.msgSend(void, "addObject:", .{category});
            center.msgSend(void, "setNotificationCategories:", .{categories});
        }

        fn didReceive(_: h.id, _: h.c.SEL, _: h.id, response_id: h.id, handler: h.id) callconv(.c) void {
            defer complete(handler);
            const response: Object = .{ .value = response_id };
            const action_obj = response.msgSend(Object, "actionIdentifier", .{});
            const action_text = h.utf8(action_obj) orelse return;
            const content = response.msgSend(Object, "notification", .{})
                .msgSend(Object, "request", .{})
                .msgSend(Object, "content", .{});
            const key = h.nsString(id_key) orelse unreachable; // ASCII
            defer key.release();
            const value = content.msgSend(Object, "userInfo", .{}).msgSend(Object, "objectForKey:", .{key});
            const id_text = if (value.value != null) h.utf8(value) orelse "" else "";
            if (std.mem.eql(u8, action_text, default_action)) {
                common.dispatch(id_text, null);
            } else if (!std.mem.startsWith(u8, action_text, "com.apple.")) {
                common.dispatch(id_text, action_text);
            }
        }
    };
}
