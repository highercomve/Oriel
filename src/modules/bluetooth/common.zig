//! Bluetooth LE (shared by every backend): the advertisement, what a
//! device can do, the 31-byte legacy budget, and the advertisement state
//! event (`bluetooth:advertise`).

const std = @import("std");
const App = @import("../../core/App.zig");

/// An advertisement, from `advertise`; 0 is never one.
pub const Handle = u32;

pub const Mode = enum { low_latency, balanced, low_power };
pub const TxPower = enum { high, medium, low, ultra_low };

/// Service data under a 16-bit service UUID.
pub const ServiceData = struct { uuid16: u16, data: []const u8 };

pub const Advertisement = struct {
    /// 16-bit service UUIDs to list.
    service_uuids16: []const u16 = &.{},
    service_data: ?ServiceData = null,
    /// Include the device's name (it counts against the budget).
    local_name: bool = false,
    /// Accept connections (the stack then adds the 3-byte Flags structure).
    connectable: bool = false,
    mode: Mode = .low_latency,
    tx_power: TxPower = .medium,
};

/// What this device can do now (availability: the permission is separate,
/// `oriel.permissions.status(.bluetooth)`).
pub const Capabilities = struct {
    /// It can advertise (a peripheral role exists).
    advertise: bool = false,
    service_data: bool = false,
    local_name: bool = false,
    connectable: bool = false,
    non_connectable: bool = false,
    /// Extended advertising (more than 31 bytes).
    extended: bool = false,
    /// The most advertising data bytes (31 for legacy advertising).
    max_bytes: u16 = 0,
    scan: bool = false,
    scan_service_data: bool = false,
    /// The adapter is on.
    powered: bool = false,
};

pub const Error = error{
    /// No BLE peripheral role on this device or platform.
    Unsupported,
    /// The bluetooth permission isn't granted (`oriel.permissions.request(.bluetooth)`).
    PermissionDenied,
    /// Bluetooth is off.
    AdapterOff,
    /// The advertisement doesn't fit the 31-byte legacy payload.
    TooLarge,
    /// The platform refused it.
    Failed,
};

/// Legacy advertising's payload: 31 bytes of AD structures.
pub const legacy_max: usize = 31;

/// The advertising payload's size in bytes: each AD structure is a length
/// byte, a type byte and its data. A connectable advertisement carries the
/// Flags structure (3 bytes) too; `name_len` is the device name's length
/// when `local_name` is set.
pub fn encodedSize(ad: Advertisement, name_len: usize) usize {
    var n: usize = 0;
    if (ad.connectable) n += 3;
    if (ad.service_uuids16.len > 0) n += 2 + 2 * ad.service_uuids16.len;
    if (ad.service_data) |sd| n += 2 + 2 + sd.data.len;
    if (ad.local_name) n += 2 + name_len;
    return n;
}

/// error.TooLarge when `ad` doesn't fit `max` bytes.
pub fn checkSize(ad: Advertisement, name_len: usize, max: usize) Error!void {
    if (encodedSize(ad, name_len) > max) return error.TooLarge;
}

pub const State = enum { started, failed };

/// An advertisement started, or failed after `advertise` returned its
/// handle (the platform answers later). Runs on the main thread.
pub const StateHandler = *const fn (handle: Handle, state: State, err: ?Error) void;

var state_handler: std.atomic.Value(?StateHandler) = .init(null);

/// Set (or clear) the advertisement state handler. The page also gets a
/// `bluetooth:advertise` event with `{ handle, state, error }`.
pub fn onAdvertiseState(handler: ?StateHandler) void {
    state_handler.store(handler, .release);
}

/// A backend's report: to the handler and the page.
pub fn dispatchState(handle: Handle, state: State, err: ?Error) void {
    if (state_handler.load(.acquire)) |h| h(handle, state, err);
    App.emit("bluetooth:advertise", .{ .handle = handle, .state = @tagName(state), .@"error" = if (err) |e| @errorName(e) else null });
}

pub const StateReport = struct { handle: Handle, state: State, code: i32 };

/// Android's "ble-advertise" system event: "handle\tstate\tcode".
pub fn parseState(data: []const u8) ?StateReport {
    var it = std.mem.splitScalar(u8, data, '\t');
    const handle = std.fmt.parseInt(Handle, it.next() orelse return null, 10) catch return null;
    const state = std.meta.stringToEnum(State, it.next() orelse return null) orelse return null;
    const code = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    return .{ .handle = handle, .state = state, .code = code };
}

test "encodedSize: GhostShare's Quick Share wake-up beacon fits legacy advertising" {
    // Service data under 0xFE2C, 24 bytes: 1 + 1 + 2 + 24 = 28.
    const payload = [_]u8{0} ** 24;
    const ad: Advertisement = .{ .service_data = .{ .uuid16 = 0xFE2C, .data = &payload } };
    try std.testing.expectEqual(@as(usize, 28), encodedSize(ad, 0));
    try checkSize(ad, 0, legacy_max);
    // Connectable: the Flags structure too, 31, still fits.
    try std.testing.expectEqual(@as(usize, 31), encodedSize(.{ .service_data = ad.service_data, .connectable = true }, 0));
}

test "encodedSize: uuids, a name, and too large" {
    const uuids = [_]u16{ 0x180F, 0x181C };
    try std.testing.expectEqual(@as(usize, 6), encodedSize(.{ .service_uuids16 = &uuids }, 0));
    try std.testing.expectEqual(@as(usize, 6 + 2 + 10), encodedSize(.{ .service_uuids16 = &uuids, .local_name = true }, 10));
    const big = [_]u8{0} ** 28;
    try std.testing.expectError(error.TooLarge, checkSize(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = &big } }, 0, legacy_max));
}

test "parseState" {
    const r = parseState("7\tfailed\t3").?;
    try std.testing.expectEqual(@as(Handle, 7), r.handle);
    try std.testing.expectEqual(State.failed, r.state);
    try std.testing.expectEqual(@as(i32, 3), r.code);
    try std.testing.expect(parseState("x\tstarted") == null);
}
