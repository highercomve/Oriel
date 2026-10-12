//! The app's lifecycle, one API on every platform (`oriel.lifecycle`):
//! going to the background and back, memory pressure, sleep and wake, and
//! the end of the app. Backends turn their own signals into `Event`s
//! (the mappings are below, as pure functions); subscribers get them on
//! the main thread, in registration order, and the page gets them as
//! `lifecycle` events, queued until it listens (pending_events.zig).
//!
//! | Event | Android | iOS | macOS | Windows | Linux |
//! |---|---|---|---|---|---|
//! | background / foreground | started Activities reach 0 / leave 0 | didEnterBackground / willEnterForeground | - | - | - |
//! | memory_pressure | onTrimMemory (`fromAndroidTrim`) | memory warning: critical | dispatch memory-pressure source | low-memory resource notification: critical | GMemoryMonitor |
//! | suspend_ / resume_ | - | - | NSWorkspace sleep / wake | WM_POWERBROADCAST | logind PrepareForSleep |
//! | terminating | - | applicationWillTerminate | quit | quit, WM_ENDSESSION | quit, SIGTERM |

const std = @import("std");
const App = @import("App.zig");
const pending_events = @import("pending_events.zig");

const log = std.log.scoped(.lifecycle);

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

var table: Table(max_subscribers) = .{};

/// Add `handler` (any thread). Up to `max_subscribers`, Oriel's own modules
/// included; there is no unsubscribe.
pub fn subscribe(handler: Handler) error{TooManySubscribers}!void {
    return table.subscribe(handler);
}

/// What the page's `lifecycle` event carries: `{ type, level }`, `level`
/// set for memory_pressure only.
pub const PageEvent = struct {
    type: Kind,
    level: ?Pressure = null,

    pub const Kind = enum { background, foreground, memory_pressure, @"suspend", @"resume", terminating };

    pub fn of(event: Event) PageEvent {
        return switch (event) {
            .background => .{ .type = .background },
            .foreground => .{ .type = .foreground },
            .memory_pressure => |p| .{ .type = .memory_pressure, .level = p },
            .suspend_ => .{ .type = .@"suspend" },
            .resume_ => .{ .type = .@"resume" },
            .terminating => .{ .type = .terminating },
        };
    }
};

// Zig subscribers are called directly; only the page needs the queue.
fn toHandler(_: *const PageEvent) bool {
    return true;
}
const page = pending_events.Queue(PageEvent, "lifecycle", 8, toHandler);

var terminated = false;

/// A backend's event (main thread): the subscribers, then the page.
pub fn dispatch(event: Event) void {
    if (event == .terminating) {
        if (terminated) return;
        terminated = true;
    }
    switch (event) {
        .memory_pressure => |p| log.info("memory pressure ({s})", .{@tagName(p)}),
        else => log.info("{s}", .{event.name()}),
    }
    table.dispatch(event);
    page.deliver(.of(event));
}

/// internal.run, once the main loop has returned (main thread): `terminating`
/// for the subscribers if no backend sent it; the pages are gone.
pub fn terminateAfterLoop() void {
    if (terminated) return;
    terminated = true;
    log.info("terminating", .{});
    table.dispatch(.terminating);
}

/// `dispatch` from any thread.
pub fn post(event: Event) void {
    App.runOnMain(event, dispatch);
}

/// internal.run: a new run may terminate again (Android restarts the app's main
/// in the same process).
pub fn beginRun() void {
    terminated = false;
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

/// The subscriber list: a fixed table filled in order (lock-free, so any
/// thread may subscribe while the main thread dispatches).
pub fn Table(comptime capacity: usize) type {
    return struct {
        slots: [capacity]std.atomic.Value(?Handler) = @splat(.init(null)),
        reserved: std.atomic.Value(usize) = .init(0),

        const Self = @This();

        pub fn subscribe(self: *Self, handler: Handler) error{TooManySubscribers}!void {
            const i = self.reserved.fetchAdd(1, .monotonic);
            if (i >= capacity) {
                _ = self.reserved.fetchSub(1, .monotonic);
                return error.TooManySubscribers;
            }
            self.slots[i].store(handler, .release);
        }

        pub fn dispatch(self: *Self, event: Event) void {
            const n = @min(self.reserved.load(.acquire), capacity);
            // A slot reserved but not yet stored is skipped: that
            // subscriber starts with the next event.
            for (self.slots[0..n]) |*slot| if (slot.load(.acquire)) |h| h(event);
        }
    };
}

// ---------------------------------------------------------------------------
// The platforms' signals, as events (pure, so every mapping is tested on
// any host).

/// Android's `ComponentCallbacks2.onTrimMemory` level. RUNNING_LOW (10) is
/// moderate; RUNNING_CRITICAL (15), BACKGROUND (40), MODERATE (60) and
/// COMPLETE (80) are critical. RUNNING_MODERATE (5) is too early to act on,
/// and UI_HIDDEN (20) is `background`, which comes from the Activities.
pub fn fromAndroidTrim(level: i32) ?Event {
    return switch (level) {
        10 => .{ .memory_pressure = .moderate },
        15 => .{ .memory_pressure = .critical },
        else => if (level >= 40) .{ .memory_pressure = .critical } else null,
    };
}

/// macOS: `dispatch_source_get_data` of a DISPATCH_SOURCE_TYPE_MEMORYPRESSURE
/// source (DISPATCH_MEMORYPRESSURE_WARN 0x2, CRITICAL 0x4; NORMAL 0x1 is the
/// pressure going away: no event).
pub fn fromDispatchMemoryPressure(flags: usize) ?Event {
    if (flags & 0x4 != 0) return .{ .memory_pressure = .critical };
    if (flags & 0x2 != 0) return .{ .memory_pressure = .moderate };
    return null;
}

/// Windows: WM_POWERBROADCAST's wParam. PBT_APMSUSPEND (4) and
/// PBT_APMRESUMEAUTOMATIC (0x12), which every wake sends (PBT_APMRESUMESUSPEND
/// follows only when a user is present: not used, or wakes would come twice).
pub fn fromPowerBroadcast(wparam: usize) ?Event {
    return switch (wparam) {
        4 => .suspend_,
        0x12 => .resume_,
        else => null,
    };
}

/// Linux: GMemoryMonitor's low-memory-warning level (LOW 50, MEDIUM 100,
/// CRITICAL 255).
pub fn fromGioMemoryWarning(level: c_int) ?Event {
    if (level >= 255) return .{ .memory_pressure = .critical };
    if (level >= 50) return .{ .memory_pressure = .moderate };
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Seen = struct {
    var log_buf: [32]u8 = undefined;
    var n: usize = 0;

    fn reset() void {
        n = 0;
    }
    fn mark(c: u8) void {
        log_buf[n] = c;
        n += 1;
    }
    fn first(_: Event) void {
        mark('a');
    }
    fn second(_: Event) void {
        mark('b');
    }
    fn third(_: Event) void {
        mark('c');
    }
    fn got() []const u8 {
        return log_buf[0..n];
    }
};

test "Table: subscribers in registration order, every event" {
    Seen.reset();
    var t: Table(4) = .{};
    t.dispatch(.background); // nobody yet
    try t.subscribe(Seen.first);
    try t.subscribe(Seen.second);
    try t.subscribe(Seen.third);
    t.dispatch(.background);
    t.dispatch(.{ .memory_pressure = .critical });
    try testing.expectEqualStrings("abcabc", Seen.got());
}

test "Table: full at capacity, and stays usable" {
    Seen.reset();
    var t: Table(2) = .{};
    try t.subscribe(Seen.first);
    try t.subscribe(Seen.second);
    try testing.expectError(error.TooManySubscribers, t.subscribe(Seen.third));
    try testing.expectError(error.TooManySubscribers, t.subscribe(Seen.third));
    t.dispatch(.foreground);
    try testing.expectEqualStrings("ab", Seen.got());
    try testing.expectEqual(@as(usize, 2), t.reserved.load(.monotonic));
}

test "the global table holds 16" {
    var t: Table(max_subscribers) = .{};
    for (0..max_subscribers) |_| try t.subscribe(Seen.first);
    try testing.expectError(error.TooManySubscribers, t.subscribe(Seen.first));
}

test fromAndroidTrim {
    try testing.expectEqual(@as(?Event, null), fromAndroidTrim(5));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .moderate }), fromAndroidTrim(10));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromAndroidTrim(15));
    try testing.expectEqual(@as(?Event, null), fromAndroidTrim(20));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromAndroidTrim(40));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromAndroidTrim(60));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromAndroidTrim(80));
    try testing.expectEqual(@as(?Event, null), fromAndroidTrim(0));
}

test fromDispatchMemoryPressure {
    try testing.expectEqual(@as(?Event, null), fromDispatchMemoryPressure(0x1));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .moderate }), fromDispatchMemoryPressure(0x2));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromDispatchMemoryPressure(0x4));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromDispatchMemoryPressure(0x6));
}

test fromPowerBroadcast {
    try testing.expectEqual(@as(?Event, .suspend_), fromPowerBroadcast(4));
    try testing.expectEqual(@as(?Event, .resume_), fromPowerBroadcast(0x12));
    try testing.expectEqual(@as(?Event, null), fromPowerBroadcast(7)); // PBT_APMRESUMESUSPEND
    try testing.expectEqual(@as(?Event, null), fromPowerBroadcast(0xA)); // PBT_APMPOWERSTATUSCHANGE
}

test fromGioMemoryWarning {
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .moderate }), fromGioMemoryWarning(50));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .moderate }), fromGioMemoryWarning(100));
    try testing.expectEqual(@as(?Event, .{ .memory_pressure = .critical }), fromGioMemoryWarning(255));
    try testing.expectEqual(@as(?Event, null), fromGioMemoryWarning(0));
}

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

test "page payload and names" {
    try testing.expectEqualStrings("suspend", Event.name(.suspend_));
    try testing.expectEqualStrings("memory_pressure", Event.name(.{ .memory_pressure = .moderate }));
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(PageEvent.of(.{ .memory_pressure = .critical }), .{}, &w);
    try testing.expectEqualStrings("{\"type\":\"memory_pressure\",\"level\":\"critical\"}", w.buffered());
    w = .fixed(&buf);
    try std.json.Stringify.value(PageEvent.of(.resume_), .{}, &w);
    try testing.expectEqualStrings("{\"type\":\"resume\",\"level\":null}", w.buffered());
}
