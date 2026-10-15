//! Bluetooth LE (shared by every backend): the advertisement, what each
//! platform's stack can send, the 31-byte legacy budget, the advertisement
//! state event (`bluetooth:advertise`) and the page's JSON.

const std = @import("std");
const internal = @import("../../core/internal.zig");
const Platform = @import("../../core/module_table.zig").Platform;

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
    /// Include the system's device (adapter) name; it counts against the
    /// budget.
    local_name: bool = false,
    /// Accept connections (the stack then adds the 3-byte Flags structure).
    connectable: bool = false,
    mode: Mode = .balanced,
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
    /// It can advertise without accepting connections. False on Apple,
    /// where `connectable = false` is best-effort: nothing is published to
    /// connect to.
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
    /// No BLE peripheral role here, or a field this platform can't send.
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

/// What each platform's stack can put in an advertisement, before asking
/// the adapter (`Capabilities` narrows it to the device). A backend's
/// `capabilities()` starts from this.
pub const Fields = struct {
    service_data: bool,
    local_name: bool,
    connectable: bool,
    non_connectable: bool,
};

pub fn fieldsOf(platform: Platform) Fields {
    return switch (platform) {
        .android, .linux => .{ .service_data = true, .local_name = true, .connectable = true, .non_connectable = true },
        // CBPeripheralManager takes only the local name and service UUIDs,
        // and is always connectable.
        .macos, .ios => .{ .service_data = false, .local_name = true, .connectable = true, .non_connectable = false },
        // BluetoothLEAdvertisementPublisher rejects LocalName (service data
        // goes in a raw 0x16 data section), and its legacy advertisements
        // can't be connected to.
        .windows => .{ .service_data = true, .local_name = false, .connectable = false, .non_connectable = true },
        .other => .{ .service_data = false, .local_name = false, .connectable = false, .non_connectable = false },
    };
}

/// A field the device can't send is error.Unsupported, never dropped.
/// `connectable = false` where only connectable advertising exists (Apple)
/// is best-effort, as `non_connectable = false` says.
pub fn validate(ad: Advertisement, caps: Capabilities) Error!void {
    if (!caps.advertise) return error.Unsupported;
    if (ad.service_data != null and !caps.service_data) return error.Unsupported;
    if (ad.local_name and !caps.local_name) return error.Unsupported;
    if (ad.connectable and !caps.connectable) return error.Unsupported;
    if (ad.service_uuids16.len == 0 and ad.service_data == null and !ad.local_name) return error.Unsupported;
}

/// The advertising payload's size in bytes: each AD structure is a length
/// byte, a type byte and its data. A connectable advertisement carries the
/// Flags structure (3 bytes) too (Android, and BlueZ's "peripheral" type);
/// `name_len` is the device name's length when `local_name` is set.
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

/// `stopped`: the platform ended it (the adapter went off, the system took
/// it back), not `stop`.
pub const State = enum { started, failed, stopped };

/// An advertisement started, failed or stopped after `advertise` returned
/// its handle (the platform answers later). Runs on the platform's thread
/// for it (the main thread on Android and Apple).
pub const StateHandler = *const fn (handle: Handle, state: State, err: ?Error) void;

var state_handler: std.atomic.Value(?StateHandler) = .init(null);

/// Set (or clear) the advertisement state handler. The page also gets a
/// `bluetooth:advertise` event with `{ id, state, error }`.
pub fn onAdvertiseState(handler: ?StateHandler) void {
    state_handler.store(handler, .release);
}

pub const event = "bluetooth:advertise";

/// A backend's report: to the handler and the page.
pub fn dispatchState(handle: Handle, state: State, err: ?Error) void {
    if (state_handler.load(.acquire)) |h| h(handle, state, err);
    internal.emit(event, StateEvent{ .id = handle, .state = state, .@"error" = if (err) |e| @errorName(e) else null });
}

pub const StateEvent = struct { id: Handle, state: State, @"error": ?[]const u8 };

pub const StateReport = struct { handle: Handle, state: State, code: i32 };

/// Android's "ble-advertise" system event: "handle\tstate\tcode".
pub fn parseState(data: []const u8) ?StateReport {
    var it = std.mem.splitScalar(u8, data, '\t');
    const handle = std.fmt.parseInt(Handle, it.next() orelse return null, 10) catch return null;
    const state = std.meta.stringToEnum(State, it.next() orelse return null) orelse return null;
    const code = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
    return .{ .handle = handle, .state = state, .code = code };
}

// ---------------------------------------------------------------------------
// The page: oriel.bluetooth.capabilities(), advertise(ad), stop(id)

/// `oriel.bluetooth.advertise({ serviceUuids16, serviceData: { uuid16,
/// data }, localName, connectable, mode, txPower })`; the bridge sends
/// `data` (a Uint8Array) as base64.
pub const PageAdvertisement = struct {
    serviceUuids16: []const u16 = &.{},
    serviceData: ?struct { uuid16: u16, data: []const u8 } = null,
    localName: bool = false,
    connectable: bool = false,
    mode: Mode = .balanced,
    txPower: TxPower = .medium,
};

/// The page's advertisement as an `Advertisement` (its data decoded in
/// `arena`); error.InvalidArgs for bad JSON or base64.
pub fn pageAdvertisement(arena: std.mem.Allocator, args: std.json.Value) !Advertisement {
    const a = std.json.parseFromValueLeaky(PageAdvertisement, arena, args, .{ .ignore_unknown_fields = true }) catch return error.InvalidArgs;
    var ad: Advertisement = .{
        .service_uuids16 = a.serviceUuids16,
        .local_name = a.localName,
        .connectable = a.connectable,
        .mode = a.mode,
        .tx_power = a.txPower,
    };
    if (a.serviceData) |sd| {
        const dec = std.base64.standard.Decoder;
        const len = dec.calcSizeForSlice(sd.data) catch return error.InvalidArgs;
        if (len > legacy_max) return error.TooLarge;
        const bytes = try arena.alloc(u8, len);
        dec.decode(bytes, sd.data) catch return error.InvalidArgs;
        ad.service_data = .{ .uuid16 = sd.uuid16, .data = bytes };
    }
    return ad;
}

/// `capabilities()` as the page sees it (camelCase).
pub const PageCapabilities = struct {
    advertise: bool,
    serviceData: bool,
    localName: bool,
    connectable: bool,
    nonConnectable: bool,
    extended: bool,
    maxBytes: u16,
    scan: bool,
    scanServiceData: bool,
    powered: bool,
};

pub fn pageCapabilities(c: Capabilities) PageCapabilities {
    return .{
        .advertise = c.advertise,
        .serviceData = c.service_data,
        .localName = c.local_name,
        .connectable = c.connectable,
        .nonConnectable = c.non_connectable,
        .extended = c.extended,
        .maxBytes = c.max_bytes,
        .scan = c.scan,
        .scanServiceData = c.scan_service_data,
        .powered = c.powered,
    };
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

/// `capabilities()` of a device with an adapter on, for `platform`.
fn deviceOn(platform: Platform) Capabilities {
    const f = fieldsOf(platform);
    return .{ .advertise = true, .service_data = f.service_data, .local_name = f.local_name, .connectable = f.connectable, .non_connectable = f.non_connectable, .max_bytes = legacy_max, .powered = true };
}

test "validate: the FE2C beacon on every platform" {
    const payload = [_]u8{0} ** 24;
    const beacon: Advertisement = .{ .service_data = .{ .uuid16 = 0xFE2C, .data = &payload } };
    try validate(beacon, deviceOn(.android));
    try validate(beacon, deviceOn(.linux));
    try validate(beacon, deviceOn(.windows));
    try std.testing.expectError(error.Unsupported, validate(beacon, deviceOn(.macos)));
    try std.testing.expectError(error.Unsupported, validate(beacon, deviceOn(.ios)));
    try std.testing.expectError(error.Unsupported, validate(beacon, deviceOn(.other)));
}

test "validate: names, connectable, and nothing to say" {
    const uuids = [_]u16{0x180F};
    const named: Advertisement = .{ .service_uuids16 = &uuids, .local_name = true };
    try validate(named, deviceOn(.ios));
    try std.testing.expectError(error.Unsupported, validate(named, deviceOn(.windows)));
    // Apple: connectable is what it does; non-connectable is best-effort.
    try validate(.{ .service_uuids16 = &uuids, .connectable = true }, deviceOn(.macos));
    try validate(.{ .service_uuids16 = &uuids }, deviceOn(.macos));
    try std.testing.expectError(error.Unsupported, validate(.{ .service_uuids16 = &uuids, .connectable = true }, deviceOn(.windows)));
    try validate(.{ .service_uuids16 = &uuids }, deviceOn(.windows));
    try std.testing.expectError(error.Unsupported, validate(.{}, deviceOn(.android)));
    try std.testing.expectError(error.Unsupported, validate(.{ .service_uuids16 = &uuids }, .{}));
}

test "parseState" {
    const r = parseState("7\tfailed\t3").?;
    try std.testing.expectEqual(@as(Handle, 7), r.handle);
    try std.testing.expectEqual(State.failed, r.state);
    try std.testing.expectEqual(@as(i32, 3), r.code);
    try std.testing.expectEqual(State.stopped, parseState("2\tstopped").?.state);
    try std.testing.expect(parseState("x\tstarted") == null);
}

test pageAdvertisement {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"serviceUuids16\":[6159],\"serviceData\":{\"uuid16\":65068,\"data\":\"AQID\"},\"localName\":true,\"mode\":\"low_latency\",\"extra\":1}";
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const ad = try pageAdvertisement(a, v);
    try std.testing.expectEqualSlices(u16, &.{0x180F}, ad.service_uuids16);
    try std.testing.expectEqual(@as(u16, 0xFE2C), ad.service_data.?.uuid16);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, ad.service_data.?.data);
    try std.testing.expect(ad.local_name and !ad.connectable);
    try std.testing.expectEqual(Mode.low_latency, ad.mode);
    try std.testing.expectEqual(TxPower.medium, ad.tx_power);
    const bad = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"serviceData\":{\"uuid16\":1,\"data\":\"!!\"}}", .{});
    try std.testing.expectError(error.InvalidArgs, pageAdvertisement(a, bad));
    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"mode\":\"warp\"}", .{});
    try std.testing.expectError(error.InvalidArgs, pageAdvertisement(a, wrong));
}
