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

/// Logs go to stderr and to a file: `~/.local/share/<id>/app.log` (Linux),
/// `%LOCALAPPDATA%\<id>\app.log` (Windows), `~/Library/Logs/<id>/app.log`
/// (macOS). An app started from the desktop has no terminal: this is where
/// its logs are.
pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };

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
            .dev = app.build.dev != null,
        };
    }
};

pub fn main(init: std.process.Init) !u8 {
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        // What build.zig declares: the app id, the embedded frontend (or the
        // dev server), the icon, deep-link schemes (`oriel deep-link add`),
        // permissions (`oriel permission add`) and the isolation hook.
        .app = app.build,
        .window = .{ .title = "@@title@@", .width = 800, .height = 600 },
    });
}
