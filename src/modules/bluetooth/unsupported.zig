//! Bluetooth LE on a platform without a backend yet: nothing to advertise.

const common = @import("common.zig");

pub fn capabilities() common.Capabilities {
    return .{};
}

pub fn advertise(_: common.Advertisement) common.Error!common.Handle {
    return error.Unsupported;
}

pub fn stop(_: common.Handle) void {}
