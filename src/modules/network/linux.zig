//! oriel.network on Linux. Multicast needs no lock. `info` (GNetworkMonitor
//! and getifaddrs) isn't written yet.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub fn setMulticast(on: bool) common.MulticastError!void {
    _ = on;
}

pub fn info(gpa: std.mem.Allocator) !common.Info {
    _ = gpa;
    return error.Unsupported;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "network", .ok = true, .detail = try gpa.dupe(u8, "multicast: nothing to hold; info: not implemented yet") };
}

// mDNS / DNS-SD (network/mdns.zig): not written yet.
// TODO: Avahi over D-Bus (org.freedesktop.Avahi: EntryGroup to register,
// ServiceBrowser + ServiceResolver to browse), through GIO already linked.
pub const mdns_backend = @import("mdns.zig").Unsupported;
