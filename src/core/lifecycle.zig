//! The app's lifecycle, one API on every platform (`oriel.lifecycle`):
//! going to the background and back, memory pressure, sleep and wake, and
//! the end of the app. Backends turn their own signals into `Event`s
//! (lifecycle/backend.zig, with the mappings as pure functions);
//! subscribers get them on the main thread, in registration order, and the
//! page gets them as `lifecycle` events, queued until it listens
//! (pending_events.zig).
//!
//! | Event | Android | iOS | macOS | Windows | Linux |
//! |---|---|---|---|---|---|
//! | background / foreground | started Activities reach 0 / leave 0 | didEnterBackground / willEnterForeground | - | - | - |
//! | memory_pressure | onTrimMemory (`fromAndroidTrim`) | memory warning: critical | dispatch memory-pressure source | low-memory resource notification: critical | GMemoryMonitor |
//! | suspend_ / resume_ | - | - | NSWorkspace sleep / wake | WM_POWERBROADCAST | logind PrepareForSleep |
//! | terminating | - | applicationWillTerminate | quit | quit, WM_ENDSESSION | quit, SIGTERM |

const std = @import("std");
const backend = @import("lifecycle/backend.zig");

pub const Pressure = enum {
    moderate,
    /// The process may be ended next.
    critical,
};

pub const Event = union(enum) {
    /// Every window left the screen (Android: the last Activity stopped; iOS:
    /// didEnterBackground; desktop: never). Free what is cheap to rebuild.
    background,
    foreground,
    /// The system wants memory back.
    memory_pressure: Pressure,
    /// The machine is about to sleep / just woke (desktop, best effort).
    suspend_,
    resume_,
    /// The app is ending (session end, terminate, quit): flush state, no
    /// new work. Sent at most once per run.
    terminating,

    /// The name the page and native extensions see: "background",
    /// "foreground", "memory_pressure", "suspend", "resume", "terminating".
    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .suspend_ => "suspend",
            .resume_ => "resume",
            else => @tagName(self),
        };
    }
};

/// Called on the main thread. Return quickly: iOS suspends the app soon
/// after `background` handlers return.
pub const Handler = *const fn (event: Event) void;

pub const max_subscribers = 16;

/// Add `handler` (any thread). Up to `max_subscribers`, Oriel's own modules
/// included; there is no unsubscribe.
pub fn subscribe(handler: Handler) error{TooManySubscribers}!void {
    return backend.table.subscribe(handler);
}

/// What a module frees its models on (chat, dictation, tts: their
/// `unload_on`). By default only critical memory pressure.
pub const UnloadOn = struct {
    background: bool = false,
    /// The lowest pressure that unloads; null never does.
    memory_pressure: ?Pressure = .critical,

    pub fn wants(self: UnloadOn, event: Event) bool {
        return switch (event) {
            .background => self.background,
            .memory_pressure => |p| if (self.memory_pressure) |min| @intFromEnum(p) >= @intFromEnum(min) else false,
            else => false,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test UnloadOn {
    const default: UnloadOn = .{};
    try testing.expect(default.wants(.{ .memory_pressure = .critical }));
    try testing.expect(!default.wants(.{ .memory_pressure = .moderate }));
    try testing.expect(!default.wants(.background));
    try testing.expect(!default.wants(.terminating));
    const eager: UnloadOn = .{ .background = true, .memory_pressure = .moderate };
    try testing.expect(eager.wants(.background));
    try testing.expect(eager.wants(.{ .memory_pressure = .moderate }));
    const never: UnloadOn = .{ .memory_pressure = null };
    try testing.expect(!never.wants(.{ .memory_pressure = .critical }));
}

test {
    testing.refAllDecls(backend);
}
