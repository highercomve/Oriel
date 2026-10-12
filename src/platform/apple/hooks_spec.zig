//! The pure parts of Apple platform hooks (`.ios.hooks`, `.macos.hooks`;
//! include/oriel_hooks.h): the methods and their selectors per platform,
//! the caps, and the declaration rules build.zig checks. No Objective-C
//! here, so it is tested on any host (`zig build test`) and imported by
//! build.zig.

const std = @import("std");

/// Hooks per platform (`.ios.hooks`, `.macos.hooks`).
pub const max_hooks = 16;
/// Source files per hook, each kind (`sources`, `swift_sources`).
pub const max_sources = 64;
/// Frameworks per hook.
pub const max_frameworks = 32;
/// Live WebViews and windows whose labels the dispatcher remembers (for
/// webViewDestroyed / windowWillClose).
pub const max_tracked = 256;

pub const Platform = enum { ios, macos };

/// Every method of the OrielPlatformHooks protocol.
pub const Method = enum(u8) {
    registered,
    web_view_configuration,
    web_view_created,
    web_view_destroyed,
    decide_policy,
    media_capture,
    open_url,
    continue_user_activity,
    did_register_push,
    did_fail_push,
    did_finish_launching,
    scene_will_connect,
    scene_did_disconnect,
    scene_did_become_active,
    scene_will_resign_active,
    scene_will_enter_foreground,
    scene_did_enter_background,
    window_created,
    window_will_close,
    should_handle_reopen,

    /// Interceptions return BOOL (YES: the hook owns it); the others
    /// return void.
    pub fn intercepts(m: Method) bool {
        return switch (m) {
            .decide_policy, .media_capture, .open_url, .continue_user_activity, .should_handle_reopen => true,
            else => false,
        };
    }

    /// The method's arguments (the selector's colons).
    pub fn arity(m: Method) u8 {
        return switch (m) {
            .registered, .open_url, .continue_user_activity, .did_register_push, .did_fail_push => 1,
            .scene_did_disconnect, .scene_did_become_active, .scene_will_resign_active => 1,
            .scene_will_enter_foreground, .scene_did_enter_background => 1,
            .web_view_configuration, .web_view_created, .web_view_destroyed => 2,
            .scene_will_connect, .window_created, .window_will_close, .should_handle_reopen => 2,
            .decide_policy => 3,
            .media_capture => 5,
            .did_finish_launching => 1,
        };
    }
};

/// The selector of `m` on `platform`, or null where the protocol doesn't
/// declare it (scenes are iOS only, windows macOS only).
pub fn selector(m: Method, platform: Platform) ?[:0]const u8 {
    return switch (m) {
        .registered => "registered:",
        .web_view_configuration => "webViewConfiguration:window:",
        .web_view_created => "webViewCreated:window:",
        .web_view_destroyed => "webViewDestroyed:window:",
        .decide_policy => "webView:handleNavigationAction:decisionHandler:",
        .media_capture => "webView:handleMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        .open_url => "openURL:",
        .continue_user_activity => "continueUserActivity:",
        .did_register_push => "didRegisterForRemoteNotificationsWithDeviceToken:",
        .did_fail_push => "didFailToRegisterForRemoteNotificationsWithError:",
        .did_finish_launching => switch (platform) {
            .ios => "applicationDidFinishLaunching:options:",
            .macos => "applicationDidFinishLaunching:",
        },
        .scene_will_connect => ios(platform, "sceneWillConnect:options:"),
        .scene_did_disconnect => ios(platform, "sceneDidDisconnect:"),
        .scene_did_become_active => ios(platform, "sceneDidBecomeActive:"),
        .scene_will_resign_active => ios(platform, "sceneWillResignActive:"),
        .scene_will_enter_foreground => ios(platform, "sceneWillEnterForeground:"),
        .scene_did_enter_background => ios(platform, "sceneDidEnterBackground:"),
        .window_created => macos(platform, "windowCreated:label:"),
        .window_will_close => macos(platform, "windowWillClose:label:"),
        .should_handle_reopen => macos(platform, "applicationShouldHandleReopen:hasVisibleWindows:"),
    };
}

fn ios(platform: Platform, s: [:0]const u8) ?[:0]const u8 {
    return if (platform == .ios) s else null;
}

fn macos(platform: Platform, s: [:0]const u8) ?[:0]const u8 {
    return if (platform == .macos) s else null;
}

/// The arguments `selector(m, platform)` takes (`.did_finish_launching`
/// has options on iOS).
pub fn arityOn(m: Method, platform: Platform) u8 {
    if (m == .did_finish_launching and platform == .ios) return 2;
    return m.arity();
}

// ---------------------------------------------------------------------------
// Declarations (build.zig)
// ---------------------------------------------------------------------------

/// What build.zig needs of one `.ios.hooks` / `.macos.hooks` entry.
pub const Declared = struct {
    class: []const u8,
    sources: usize = 0,
    swift_sources: usize = 0,
    frameworks: []const []const u8 = &.{},
};

pub const Problem = union(enum) {
    too_many,
    invalid_class: []const u8,
    duplicate_class: []const u8,
    too_many_sources: []const u8,
    too_many_frameworks: []const u8,
    invalid_framework: struct { class: []const u8, name: []const u8 },
};

/// The first rule `list` breaks, or null. Declaration order is kept as is:
/// it is the order hooks are constructed and asked in.
pub fn check(list: []const Declared) ?Problem {
    if (list.len > max_hooks) return .too_many;
    for (list, 0..) |h, i| {
        if (!validClass(h.class)) return .{ .invalid_class = h.class };
        for (list[0..i]) |prev| if (std.mem.eql(u8, prev.class, h.class)) return .{ .duplicate_class = h.class };
        if (h.sources > max_sources or h.swift_sources > max_sources) return .{ .too_many_sources = h.class };
        if (h.frameworks.len > max_frameworks) return .{ .too_many_frameworks = h.class };
        for (h.frameworks) |f| if (!validFramework(f)) return .{ .invalid_framework = .{ .class = h.class, .name = f } };
    }
    return null;
}

/// An Objective-C class name: [A-Za-z_][A-Za-z0-9_]*, up to 128 bytes.
pub fn validClass(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    for (name, 0..) |ch, i| {
        const alpha = std.ascii.isAlphabetic(ch) or ch == '_';
        if (!(alpha or (i > 0 and std.ascii.isDigit(ch)))) return false;
    }
    return true;
}

/// An SDK framework's name ("SafariServices"): [A-Za-z0-9_], up to 64.
pub fn validFramework(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

/// Swift module names for hooks' sources: "OrielHooks_<Class>".
pub fn swiftModuleName(buf: []u8, class: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "OrielHooks_{s}", .{class}) catch null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn colons(s: []const u8) usize {
    return std.mem.count(u8, s, ":");
}

test "selectors: one per method and platform, colons match the arity" {
    for ([_]Platform{ .ios, .macos }) |p| {
        var seen: [@typeInfo(Method).@"enum".fields.len]?[:0]const u8 = @splat(null);
        for (std.enums.values(Method), 0..) |m, i| {
            const s = selector(m, p) orelse continue;
            try std.testing.expectEqual(@as(usize, arityOn(m, p)), colons(s));
            for (seen[0..i]) |prev| if (prev) |q| try std.testing.expect(!std.mem.eql(u8, q, s));
            seen[i] = s;
        }
    }
}

test "selectors: scenes on iOS only, windows on macOS only" {
    try std.testing.expect(selector(.scene_will_connect, .macos) == null);
    try std.testing.expect(selector(.scene_did_enter_background, .macos) == null);
    try std.testing.expect(selector(.window_created, .ios) == null);
    try std.testing.expect(selector(.should_handle_reopen, .ios) == null);
    try std.testing.expectEqualStrings("applicationDidFinishLaunching:options:", selector(.did_finish_launching, .ios).?);
    try std.testing.expectEqualStrings("applicationDidFinishLaunching:", selector(.did_finish_launching, .macos).?);
    // Shared methods have the same selector on both.
    for ([_]Method{ .registered, .web_view_created, .decide_policy, .media_capture, .open_url, .continue_user_activity, .did_register_push }) |m|
        try std.testing.expectEqualStrings(selector(m, .ios).?, selector(m, .macos).?);
}

test "interceptions" {
    try std.testing.expect(Method.decide_policy.intercepts());
    try std.testing.expect(Method.open_url.intercepts());
    try std.testing.expect(Method.should_handle_reopen.intercepts());
    try std.testing.expect(!Method.web_view_created.intercepts());
    try std.testing.expect(!Method.registered.intercepts());
}

test check {
    try std.testing.expect(check(&.{}) == null);
    try std.testing.expect(check(&.{ .{ .class = "AppHooks", .sources = 1 }, .{ .class = "Push_2", .swift_sources = 2, .frameworks = &.{"UserNotifications"} } }) == null);
    try std.testing.expect(check(&.{.{ .class = "1Bad" }}).? == .invalid_class);
    try std.testing.expect(check(&.{.{ .class = "My.Hooks" }}).? == .invalid_class);
    try std.testing.expectEqualStrings("A", check(&.{ .{ .class = "A" }, .{ .class = "B" }, .{ .class = "A" } }).?.duplicate_class);
    try std.testing.expectEqualStrings("Safari Services", check(&.{.{ .class = "A", .frameworks = &.{"Safari Services"} }}).?.invalid_framework.name);
    try std.testing.expect(check(&.{.{ .class = "A", .sources = max_sources + 1 }}).? == .too_many_sources);
    const many: [max_hooks + 1]Declared = @splat(.{ .class = "A" });
    try std.testing.expect(check(&many).? == .too_many);
    const full: [max_hooks]Declared = blk: {
        var out: [max_hooks]Declared = undefined;
        const names = [_][]const u8{ "H0", "H1", "H2", "H3", "H4", "H5", "H6", "H7", "H8", "H9", "H10", "H11", "H12", "H13", "H14", "H15" };
        for (&out, names) |*o, n| o.* = .{ .class = n };
        break :blk out;
    };
    try std.testing.expect(check(&full) == null);
}

test swiftModuleName {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("OrielHooks_MyHooks", swiftModuleName(&buf, "MyHooks").?);
    var small: [4]u8 = undefined;
    try std.testing.expect(swiftModuleName(&small, "MyHooks") == null);
}
