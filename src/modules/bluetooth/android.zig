//! Bluetooth LE advertising through Android's BluetoothLeAdvertiser
//! (OrielRuntime.bleAdvertise): legacy advertising, no timeout. Android
//! 12+ needs the bluetooth permission (`.permissions = .{ .bluetooth = "..." }`,
//! then `oriel.permissions.request(.bluetooth)`). The advertisement's
//! start, or its failure after `advertise` returned, comes as the
//! `bluetooth:advertise` state (common.onAdvertiseState and the event).

const std = @import("std");
const common = @import("common.zig");
const heap = @import("../../core/heap.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

const Advertisement = common.Advertisement;
const Capabilities = common.Capabilities;
const Handle = common.Handle;

pub fn capabilities() Capabilities {
    const Ctx = struct {
        bits: i32 = 0,
        fn run(self: *@This()) void {
            self.bits = runtime.call(.int, "bleCapabilities", "()I", .{}) orelse 0;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return .{};
    const b: u32 = @bitCast(ctx.bits);
    const can_advertise = b & 1 != 0;
    return .{
        .advertise = can_advertise,
        .service_data = can_advertise,
        .local_name = can_advertise,
        .connectable = can_advertise,
        .non_connectable = can_advertise,
        .extended = b & 4 != 0,
        .max_bytes = if (can_advertise) @intCast(b >> 16) else 0,
        .scan = false, // no scanning API yet
        .scan_service_data = false,
        .powered = b & 2 != 0,
    };
}

/// Start advertising `ad`: its handle. Android reports the start (or a
/// failure that comes after this returns) as the advertisement's state.
pub fn advertise(ad: Advertisement) common.Error!Handle {
    // The device name's length isn't known here: a named advertisement is
    // checked with no name, and Android refuses it (DATA_TOO_LARGE) if the
    // name doesn't fit.
    try common.checkSize(ad, 0, common.legacy_max);
    var uuids: [32]u8 = undefined;
    if (ad.service_uuids16.len > uuids.len / 2) return error.TooLarge;
    for (ad.service_uuids16, 0..) |u, i| std.mem.writeInt(u16, uuids[2 * i ..][0..2], u, .little);
    const flags: i32 = @as(i32, @intFromBool(ad.local_name)) | (@as(i32, @intFromBool(ad.connectable)) << 1) |
        (@as(i32, @intFromEnum(ad.mode)) << 2) | (@as(i32, @intFromEnum(ad.tx_power)) << 4);
    const Ctx = struct {
        uuids: []const u8,
        sd_uuid: i32,
        sd_data: ?[]const u8,
        flags: i32,
        out: i32 = -4,
        fn run(self: *@This()) void {
            self.out = runtime.call(.int, "bleAdvertise", "([BI[BI)I", .{ self.uuids, self.sd_uuid, self.sd_data, self.flags }) orelse -4;
        }
    };
    var ctx: Ctx = .{
        .uuids = uuids[0 .. 2 * ad.service_uuids16.len],
        .sd_uuid = if (ad.service_data) |sd| sd.uuid16 else -1,
        .sd_data = if (ad.service_data) |sd| sd.data else null,
        .flags = flags,
    };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return error.Failed;
    return switch (ctx.out) {
        -1 => error.Unsupported,
        -2 => error.PermissionDenied,
        -3 => error.AdapterOff,
        else => if (ctx.out > 0) @intCast(ctx.out) else error.Failed,
    };
}

pub fn stop(handle: Handle) void {
    const Ctx = struct {
        handle: Handle,
        fn run(self: *@This()) void {
            _ = runtime.call(.void, "bleStop", "(I)V", .{@as(i32, @intCast(self.handle))});
        }
    };
    var ctx: Ctx = .{ .handle = handle };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

/// AdvertiseCallback's error codes as Oriel's.
pub fn errorOf(code: i32) common.Error {
    return switch (code) {
        1 => error.TooLarge, // ADVERTISE_FAILED_DATA_TOO_LARGE
        5 => error.Unsupported, // ADVERTISE_FAILED_FEATURE_UNSUPPORTED
        else => error.Failed, // TOO_MANY_ADVERTISERS, ALREADY_STARTED, INTERNAL_ERROR
    };
}

/// The "ble-advertise" system event (OrielRuntime's AdvertiseCallback).
pub fn onSystemEvent(data: []const u8) void {
    const r = common.parseState(data) orelse return;
    common.dispatchState(r.handle, r.state, if (r.state == .failed) errorOf(r.code) else null);
}
