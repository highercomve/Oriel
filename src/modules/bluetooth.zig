//! Bluetooth LE: advertising (a beacon others can see).
//!
//! Android backend: BluetoothLeAdvertiser (legacy advertising).
//! Other platforms: not yet (`advertise` returns error.Unsupported).
//!
//! ```zig
//! const h = try oriel.bluetooth.advertise(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = payload } });
//! defer oriel.bluetooth.stop(h);
//! ```

const target = @import("../core/target.zig");
pub const common = @import("bluetooth/common.zig");

pub const Handle = common.Handle;
pub const Advertisement = common.Advertisement;
pub const ServiceData = common.ServiceData;
pub const Mode = common.Mode;
pub const TxPower = common.TxPower;
pub const Capabilities = common.Capabilities;
pub const Error = common.Error;
pub const State = common.State;
pub const StateHandler = common.StateHandler;
pub const encodedSize = common.encodedSize;
pub const onAdvertiseState = common.onAdvertiseState;

pub const capabilities = impl.capabilities;
pub const advertise = impl.advertise;
pub const stop = impl.stop;

pub const impl = switch (target.os) {
    .android => @import("bluetooth/android.zig"),
    else => @import("bluetooth/unsupported.zig"),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
}
