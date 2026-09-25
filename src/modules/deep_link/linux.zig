//! Linux backend for deep links.
//!
//! Manages cold-start URL, open handler callback, and dispatch of incoming
//! URLs forwarded via GTK single-instance command-line handling.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const App = @import("../../core/App.zig");
pub const common = @import("common.zig");
pub const queue = @import("queue.zig");

var queue_state: queue.Queue = .{};
var declared_schemes: []const []const u8 = &.{};
var on_open_handler: ?*const fn (url: []const u8) void = null;

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
    return queue_state.current();
}

/// Record the cold-start launch URL.
pub fn setColdStartUrl(url: []const u8) void {
    const valid = common.validateUrl(url, declared_schemes) catch return;
    queue_state.setColdStartUrl(valid);
}

/// Query page readiness state.
pub fn isReady() bool {
    return queue_state.is_ready;
}

/// Set page readiness and flush any queued URLs.
pub fn setReady(ready: bool) void {
    queue_state.setReady(ready);
    if (ready) {
        while (queue_state.pop()) |u| {
            emitDirect(u);
        }
    }
}

/// Validate and deliver a deep link URL on the main thread.
/// Calls the registered `onOpen` handler, then broadcasts the `deep-link` event
/// to the webview windows, or queues it until the page listens (`setReady(true)`).
pub fn deliver(url: []const u8) void {
    // Only declared schemes (none declared: nothing is delivered).
    const valid_url = common.validateUrl(url, declared_schemes) catch return;

    if (on_open_handler) |handler| handler(valid_url);

    // The page's `deep-link` event waits until it listens (setReady).
    const queued = queue_state.push(valid_url) catch false;
    if (!queued) emitDirect(valid_url);
}

fn emitDirect(valid_url: []const u8) void {
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
    // Ready without flushing: queued links stay for the page, and current()
    // keeps the real latest URL.
    const prev_ready = queue_state.is_ready;
    const prev_latest = queue_state.latest;
    defer {
        declared_schemes = prev_schemes;
        on_open_handler = prev_handler;
        queue_state.is_ready = prev_ready;
        queue_state.latest = prev_latest;
    }

    declared_schemes = &test_schemes;
    queue_state.is_ready = true;

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
