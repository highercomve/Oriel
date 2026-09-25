//! @@title@@: an Oriel app.
//!
//! The page calls the functions in `Commands` with `invoke()` and receives
//! `Events` with `listen()`. Both are typed on the JavaScript side too:
//! `zig build types` (also run by `oriel dev` and `oriel build`) generates
//! them from these structs.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");

/// Events pushed from Zig to the page.
pub const Events = struct {
    greeted: struct { count: u32 },
};
const events = oriel.App.events(Events);

var greet_count: std.atomic.Value(u32) = .init(0);

pub const Commands = struct {
    /// `invoke("greet", { name })`: returns a greeting and emits `greeted`.
    /// Errors reject the promise on the page with the error name.
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        const name = std.mem.trim(u8, args.name, " \t\r\n");
        if (name.len == 0) return error.EmptyName;
        const count = greet_count.fetchAdd(1, .monotonic) + 1;
        events.emit(.greeted, .{ .count = count });
        return std.fmt.allocPrint(gpa, "Hello, {s}! Greetings from Zig.", .{name});
    }

    /// `invoke("app_info")`: how the Zig side was built.
    pub fn app_info(_: std.mem.Allocator) struct { zig: []const u8, mode: []const u8, dev: bool } {
        return .{
            .zig = builtin.zig_version_string,
            .mode = @tagName(builtin.mode),
            .dev = app.dev != null,
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "@@app_id@@",
        .title = "@@title@@",
        .width = 800,
        .height = 600,
        .assets = app.assets, // the embedded frontend (empty in dev builds)
        .dev = app.dev, // dev-server settings (null in production builds)
        // URL schemes this app accepts deep links for (`oriel deep-link add`);
        // links with any other scheme are dropped.
        .deep_link_schemes = app.url_schemes,
        // OS permissions declared in build.zig (`oriel permission add`).
        .permissions = app.permissions,
    });
}
