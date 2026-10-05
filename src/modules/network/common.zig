//! oriel.network's shared part: the types, the multicast lock's reference
//! count and the change handler. Each OS backend provides
//! `setMulticast(on: bool) !void` (called on 0 <-> 1 locks) and
//! `info(gpa) !Info`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const permissions = @import("../../core/permissions.zig");

/// The network the device is on.
pub const Transport = enum { wifi, ethernet, cellular, vpn, other, none };

pub const Info = struct {
    connected: bool,
    transport: Transport,
    /// The OS treats it as metered (cellular, a phone's hotspot).
    metered: bool,
    /// The device's LAN-scope addresses.
    addresses: []const std.Io.net.IpAddress,

    pub fn deinit(self: Info, gpa: Allocator) void {
        gpa.free(self.addresses);
    }
};

pub const MulticastError = error{
    /// The app doesn't declare `.permissions = .{ .local_network = "..." }`
    /// in build.zig (Android would refuse the lock).
    NotDeclared,
    /// This platform's backend isn't written yet.
    Unsupported,
    /// The OS refused.
    Failed,
};

/// A hold on the platform's multicast reception (Android drops multicast
/// packets, mDNS among them, unless an app holds a Wi-Fi multicast lock).
/// Released by `release`; the lock is taken while any hold exists.
pub const MulticastLock = struct {
    id: u32,

    pub fn release(self: MulticastLock) void {
        releaseMulticast(self.id);
    }
};

pub const ChangeHandler = *const fn (Info) void;

/// The OS call for the first lock taken and the last released: the
/// facade's backend, or a test's.
pub const SetMulticast = *const fn (on: bool) MulticastError!void;

/// The reference count behind `MulticastLock` (any thread).
pub const Locks = struct {
    busy: std.atomic.Value(bool) = .init(false),
    held: std.StaticBitSet(max_locks) = .initEmpty(),

    pub const max_locks = 64;

    fn lock(self: *Locks) void {
        while (self.busy.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *Locks) void {
        self.busy.store(false, .release);
    }

    pub fn acquire(self: *Locks, set: SetMulticast) MulticastError!MulticastLock {
        self.lock();
        defer self.unlock();
        const id = self.held.complement().findFirstSet() orelse return error.Failed;
        if (self.held.count() == 0) try set(true);
        self.held.set(id);
        return .{ .id = @intCast(id) };
    }

    /// Releasing an id twice (or one never handed out) does nothing.
    pub fn release(self: *Locks, id: u32, set: SetMulticast) void {
        self.lock();
        defer self.unlock();
        if (id >= max_locks or !self.held.isSet(id)) return;
        self.held.unset(id);
        if (self.held.count() == 0) set(false) catch {};
    }

    pub fn count(self: *Locks) usize {
        return self.held.count();
    }
};

var locks: Locks = .{};
var backend: ?SetMulticast = null;

/// Called by the facade with this OS's backend.
pub fn acquireMulticastWith(set: SetMulticast) MulticastError!MulticastLock {
    if (!localNetworkDeclared()) return error.NotDeclared;
    backend = set;
    return locks.acquire(set);
}

fn releaseMulticast(id: u32) void {
    const set = backend orelse return;
    locks.release(id, set);
}

/// Whether the app declares `local_network` (always true until the
/// permission kind exists).
pub fn localNetworkDeclared() bool {
    if (!@hasField(permissions.Declared, "local_network")) return true;
    return permissions.declared().local_network != null;
}

var change_handler: std.atomic.Value(?ChangeHandler) = .init(null);

/// Set (or clear) the handler for network changes; the page gets the
/// `network:changed` event with the new `Info`. No backend reports
/// changes yet.
pub fn onChange(handler: ?ChangeHandler) void {
    change_handler.store(handler, .release);
}

/// The handler `onChange` set, for backends.
pub fn changeHandler() ?ChangeHandler {
    return change_handler.load(.acquire);
}

const testing = std.testing;

const FakeBackend = struct {
    var on: bool = false;
    var calls: usize = 0;
    var fail = false;

    fn set(v: bool) MulticastError!void {
        if (fail) return error.Failed;
        on = v;
        calls += 1;
    }
};

test "Locks: the lock is held while any hold exists" {
    var l: Locks = .{};
    FakeBackend.on = false;
    FakeBackend.calls = 0;
    const a = try l.acquire(FakeBackend.set);
    const b = try l.acquire(FakeBackend.set);
    try testing.expect(FakeBackend.on);
    try testing.expectEqual(@as(usize, 1), FakeBackend.calls);
    l.release(a.id, FakeBackend.set);
    try testing.expect(FakeBackend.on);
    l.release(a.id, FakeBackend.set); // twice: nothing
    try testing.expectEqual(@as(usize, 1), l.count());
    l.release(b.id, FakeBackend.set);
    try testing.expect(!FakeBackend.on);
    try testing.expectEqual(@as(usize, 2), FakeBackend.calls);
}

test "Locks: a refused first lock isn't counted" {
    var l: Locks = .{};
    FakeBackend.fail = true;
    defer FakeBackend.fail = false;
    try testing.expectError(error.Failed, l.acquire(FakeBackend.set));
    try testing.expectEqual(@as(usize, 0), l.count());
}
