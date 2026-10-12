//! The device's network: a multicast lock and mDNS/DNS-SD
//! (docs/platform-capabilities-design.md, section 2).
//!
//!     const lock = try oriel.network.acquireMulticast(); // mDNS on Android
//!     defer lock.release();
//!
//! `acquireMulticast` needs `.permissions = .{ .local_network = "..." }` in
//! build.zig (declaring it also turns this module on). Locks are reference
//! counted: the platform's lock is held while any is.
//!
//! Backends (`network/<os>.zig`), so far:
//! - multicast: a no-op on Linux, Windows, macOS and iOS (nothing to hold;
//!   Apple's prompt and entitlement are the real gates); Android:
//!   `error.Unsupported` until its Wi-Fi MulticastLock lands.
//! - `mdns` (service registration and browsing, network/mdns.zig): Android
//!   (NsdManager) and Windows (dnsapi); `error.Unsupported` elsewhere for now.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const target = @import("../core/target.zig");
const common = @import("network/common.zig");

pub const MulticastLock = common.MulticastLock;
pub const MulticastError = common.MulticastError;

/// DNS-SD service registration and browsing through the platform's mDNS
/// responder: `mdns.register`, `mdns.browse`, `mdns.supported`.
pub const mdns = @import("network/mdns.zig");

/// Hold the platform's multicast reception (any thread) until
/// `lock.release()`.
pub fn acquireMulticast() MulticastError!MulticastLock {
    return common.acquireMulticastWith(impl.setMulticast);
}

pub const check = impl.check;

const impl = @import("network/backend.zig").os;

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
    std.testing.refAllDecls(mdns);
    std.testing.refAllDecls(@import("network/mdns_wire.zig"));
    std.testing.refAllDecls(@import("network/mdns_c.zig"));
}
