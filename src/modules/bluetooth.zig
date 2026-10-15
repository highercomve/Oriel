//! Bluetooth LE advertising: a beacon nearby devices can see
//! (docs/bluetooth.md).
//!
//!     const caps = oriel.bluetooth.capabilities();
//!     if (caps.service_data) {
//!         const h = try oriel.bluetooth.advertise(.{ .service_data = .{ .uuid16 = 0xFE2C, .data = payload } });
//!         defer oriel.bluetooth.stop(h);
//!     }
//!
//! On when the app declares `.permissions.bluetooth` (or with
//! `-Dbluetooth`). The same API builds everywhere; what each platform's
//! stack can send differs, and `capabilities()` says so:
//!
//! - Android and ChromeOS: BluetoothLeAdvertiser, every field.
//! - Linux: BlueZ (`org.bluez.LEAdvertisement1` over the system bus),
//!   every field.
//! - macOS and iOS: CBPeripheralManager, service UUIDs and the device name
//!   only (no service data); always connectable, so `connectable = false`
//!   is best-effort there (`non_connectable` is false).
//! - Windows: BluetoothLEAdvertisementPublisher, service UUIDs and service
//!   data, no device name, never connectable.
//!
//! A field the device can't send is error.Unsupported, never dropped. A
//! start that fails after `advertise` returned (most stacks answer later)
//! comes as the advertisement's state: `onAdvertiseState`, and the page's
//! `bluetooth:advertise` event.

/// Built for this target (docs/modules.md, "Availability"): every platform
/// has the API; `capabilities().advertise` says whether this device can.
pub const available = true;

const std = @import("std");
const target = @import("../core/target.zig");
const oriel = @import("../oriel.zig");
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
/// Legacy advertising's 31-byte payload.
pub const legacy_max = common.legacy_max;

/// What this device can advertise now (the adapter's state included; the
/// permission is `oriel.permissions.status(.bluetooth)`).
pub fn capabilities() Capabilities {
    return impl.capabilities();
}

/// Start advertising `ad` until `stop`. error.Unsupported for a field this
/// device can't send (`capabilities()`), error.TooLarge past the 31-byte
/// legacy payload. A later start failure comes as the state `failed`.
pub fn advertise(ad: Advertisement) Error!Handle {
    try common.validate(ad, impl.capabilities());
    return impl.advertise(ad);
}

/// Stop an advertisement (a handle already stopped, or 0, is ignored).
pub fn stop(handle: Handle) void {
    if (handle == 0) return;
    impl.stop(handle);
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const c = capabilities();
    return .{
        .module = "bluetooth",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "{s}: advertise {}, powered {}, service data {}, local name {}, connectable {}, non-connectable {}, extended {}, {d} bytes", .{
            impl.backend, c.advertise, c.powered, c.service_data, c.local_name, c.connectable, c.non_connectable, c.extended, c.max_bytes,
        }),
    };
}

pub const impl = switch (target.os) {
    .android => @import("bluetooth/android.zig"),
    .linux => @import("bluetooth/linux.zig"),
    .macos, .ios => @import("bluetooth/apple.zig"),
    .windows => @import("bluetooth/windows.zig"),
    .other => @import("bluetooth/unsupported.zig"),
};

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
}
