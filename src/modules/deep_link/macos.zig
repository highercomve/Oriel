//! macOS backend for deep links.
//!
//! Manages cold-start URL, open handler callback, and dispatch of incoming
//! URLs delivered by Launch Services as `kAEGetURL` Apple Events (see
//! src/platform/macos/Shell.zig); the bundle declares its schemes in
//! Info.plist `CFBundleURLTypes` (written by `zig build` / `oriel package`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const App = @import("../../core/App.zig");
pub const common = @import("common.zig");

var declared_schemes: []const []const u8 = &.{};
var on_open_handler: ?*const fn (url: []const u8) void = null;
var cold_start_buf: [common.max_url_len]u8 = undefined;
var cold_start_len: ?usize = null;

/// Configure declared URL schemes for the application.
pub fn setDeclaredSchemes(schemes: []const []const u8) void {
    declared_schemes = schemes;
}

/// Register a callback to be invoked on the main thread when a deep link URL is opened.
pub fn onOpen(handler: *const fn (url: []const u8) void) void {
    on_open_handler = handler;
}

/// Return the URL that launched the application (cold start), if any.
pub fn current() ?[]const u8 {
    if (cold_start_len) |len| {
        return cold_start_buf[0..len];
    }
    return null;
}

/// Record the cold-start launch URL.
pub fn setColdStartUrl(url: []const u8) void {
    if (url.len > cold_start_buf.len) return;
    @memcpy(cold_start_buf[0..url.len], url);
    cold_start_len = url.len;
}

/// Validate and deliver a deep link URL on the main thread.
/// Invokes the registered `onOpen` handler and broadcasts `deep-link` event to webview windows.
pub fn deliver(url: []const u8) void {
    const valid_url = if (declared_schemes.len > 0)
        common.validateUrl(url, declared_schemes) catch return
    else blk: {
        if (url.len > common.max_url_len) return;
        for (url) |c| {
            if (c < 0x20 or c == 0x7F) return;
        }
        _ = std.Uri.parse(url) catch return;
        break :blk url;
    };

    if (on_open_handler) |handler| {
        handler(valid_url);
    }

    App.emit("deep-link", .{ .url = valid_url });
}

/// Module smoke check for deep links: validates URLs and exercises in-process dispatch.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const test_schemes = [_][]const u8{ "oriel-smoke", "test-scheme" };

    // 1. Verify URL validation logic
    _ = common.validateUrl("oriel-smoke://path?k=v", &test_schemes) catch |err| {
        return .{ .module = "deep_link", .ok = false, .detail = @errorName(err) };
    };
    if (common.validateUrl("disallowed://path", &test_schemes)) |_| {
        return .{ .module = "deep_link", .ok = false, .detail = "accepted disallowed scheme" };
    } else |_| {}

    if (common.validateUrl("oriel-smoke://path\x00bad", &test_schemes)) |_| {
        return .{ .module = "deep_link", .ok = false, .detail = "accepted control char" };
    } else |_| {}

    // 2. Exercise in-process dispatch
    const prev_schemes = declared_schemes;
    const prev_handler = on_open_handler;
    defer {
        declared_schemes = prev_schemes;
        on_open_handler = prev_handler;
    }

    declared_schemes = &test_schemes;

    const State = struct {
        var received: ?[]const u8 = null;
        fn handle(u: []const u8) void {
            received = u;
        }
    };
    State.received = null;
    onOpen(&State.handle);

    const test_url = "oriel-smoke://check/in-process";
    deliver(test_url);

    if (State.received == null or !std.mem.eql(u8, State.received.?, test_url)) {
        return .{
            .module = "deep_link",
            .ok = false,
            .detail = "in-process dispatch did not invoke onOpen handler",
        };
    }

    return .{
        .module = "deep_link",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "URL validation and in-process dispatch ok", .{}),
    };
}
