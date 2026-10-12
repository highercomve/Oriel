//! Deep link delivery, the same on every platform. Each shell finds the
//! URLs its OS hands over and calls `deliver` on the main thread:
//! - Linux: GApplication command-line handling (a second launch forwards
//!   its arguments over D-Bus);
//! - Windows: the arguments, or a second launch's over `WM_COPYDATA`;
//! - macOS: `kAEGetURL` Apple Events from Launch Services (the bundle
//!   declares its schemes in Info.plist `CFBundleURLTypes`), or argv;
//! - iOS: the scene's URL contexts; Android: the Intent's data URL.
//!
//! A link goes to the app's `onOpen` handler and to the page's `deep-link`
//! event; each audience that isn't there yet (the launch link, before
//! `onOpen` is set or the page listens) gets it later, in order
//! (core/pending_events.zig, up to 16 each). `current` is the latest link.
//!
//! Internal: the shells, App.zig and ipc.zig import this file; apps use
//! `oriel.deep_link` (modules/deep_link.zig).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const pending_events = @import("../../core/pending_events.zig");
const common = @import("common.zig");

pub const validate = common.validate;

/// The page's event and its payload.
const Link = struct { url: []const u8 };

/// Main thread only (the shells, `deliver`, ipc's `deep_link:current`).
var declared_schemes: []const []const u8 = &.{};
var latest_buf: [common.max_url_len]u8 = undefined;
var latest_len: ?usize = null;

var on_open_handler: std.atomic.Value(?*const fn (url: []const u8) void) = .init(null);

const links = pending_events.Queue(Link, "deep-link", 16, toHandler);

fn toHandler(link: *const Link) bool {
    const handler = on_open_handler.load(.acquire) orelse return false;
    handler(link.url);
    return true;
}

/// The schemes the app declares (`AppOptions.url_schemes`): App.run, before
/// any shell delivers.
pub fn setDeclaredSchemes(schemes: []const []const u8) void {
    declared_schemes = schemes;
}

/// Set the handler for opened links (any thread; one, a later call
/// replaces it). Links that came before it (the launch link) reach it now.
pub fn onOpen(handler: *const fn (url: []const u8) void) void {
    on_open_handler.store(handler, .release);
    links.handlerSet();
}

/// The latest link: the one that launched the app, or the latest
/// delivered since.
pub fn current() ?[]const u8 {
    const len = latest_len orelse return null;
    return latest_buf[0..len];
}

fn setLatest(url: []const u8) void {
    @memcpy(latest_buf[0..url.len], url);
    latest_len = url.len;
}

/// Record the launch link for `current` before the window opens (it is
/// delivered once the app is set up).
pub fn setColdStartUrl(url: []const u8) void {
    setLatest(validate(url, declared_schemes) catch return);
}

/// Deliver `url` as if the OS had opened it (main thread): validated
/// against the declared schemes (dropped if invalid), then handed to the
/// `onOpen` handler and the page's `deep-link` event, or kept for them.
pub fn deliver(url: []const u8) void {
    // Only declared schemes (none declared: nothing is delivered).
    const valid = validate(url, declared_schemes) catch return;
    setLatest(valid);
    links.deliver(.{ .url = valid });
}

/// Module smoke check: URL validation, and a link through the queue to a
/// handler (a private queue: nothing reaches the app or the page).
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const test_schemes = [_][]const u8{ "oriel-smoke", "test-scheme" };

    _ = validate("oriel-smoke://path?k=v", &test_schemes) catch |err| {
        return .{ .module = "deep_link", .ok = false, .detail = @errorName(err) };
    };
    if (validate("disallowed://path", &test_schemes)) |_| {
        return .{ .module = "deep_link", .ok = false, .detail = "accepted disallowed scheme" };
    } else |_| {}
    if (validate("oriel-smoke://path\x00bad", &test_schemes)) |_| {
        return .{ .module = "deep_link", .ok = false, .detail = "accepted control char" };
    } else |_| {}

    const State = struct {
        var handler_on = false;
        var received: [64]u8 = undefined;
        var received_len: usize = 0;
        fn toHandler(link: *const Link) bool {
            if (!handler_on) return false;
            const n = @min(link.url.len, received.len);
            @memcpy(received[0..n], link.url[0..n]);
            received_len = n;
            return true;
        }
        fn emit(_: *const Link) void {}
    };
    State.handler_on = false;
    State.received_len = 0;
    var queue: pending_events.Pending(Link, 1) = .{ .gpa = gpa };
    defer queue.deinit();
    const test_url = "oriel-smoke://check/in-process";
    queue.deliver(.{ .url = try validate(test_url, &test_schemes) }, State.toHandler, true, State.emit);
    State.handler_on = true;
    queue.flushHandler(State.toHandler);
    if (!std.mem.eql(u8, State.received[0..State.received_len], test_url)) {
        return .{ .module = "deep_link", .ok = false, .detail = "a link before the handler didn't reach it once set" };
    }
    return .{ .module = "deep_link", .ok = true, .detail = "URL validation and delivery ok" };
}

test "current is the latest valid link" {
    const prev = declared_schemes;
    defer declared_schemes = prev;
    setDeclaredSchemes(&.{"myapp"});
    setColdStartUrl("myapp://cold");
    try std.testing.expectEqualStrings("myapp://cold", current().?);
    setColdStartUrl("other://x");
    try std.testing.expectEqualStrings("myapp://cold", current().?);
}
