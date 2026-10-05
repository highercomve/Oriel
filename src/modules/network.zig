//! The device's network: a multicast lock and LAN information
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
//! - `info`: `error.Unsupported` everywhere; `onChange` never fires yet.

const std = @import("std");
const target = @import("../core/target.zig");
pub const common = @import("network/common.zig");

pub const Transport = common.Transport;
pub const Info = common.Info;
pub const MulticastLock = common.MulticastLock;
pub const MulticastError = common.MulticastError;
pub const ChangeHandler = common.ChangeHandler;

/// Hold the platform's multicast reception (any thread) until
/// `lock.release()`.
pub fn acquireMulticast() MulticastError!MulticastLock {
    return common.acquireMulticastWith(impl.setMulticast);
}

/// The network the device is on now. Free with `info.deinit(gpa)`.
pub fn info(gpa: std.mem.Allocator) !Info {
    return impl.info(gpa);
}

/// Set (or clear) the handler for network changes (main thread). The page
/// gets the `network:changed` event.
pub const onChange = common.onChange;

pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("network/linux.zig"),
    .windows => @import("network/windows.zig"),
    .macos, .ios => @import("network/apple.zig"),
    .android => @import("network/android.zig"),
    .other => @compileError("network is not supported on " ++ target.name),
};

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
