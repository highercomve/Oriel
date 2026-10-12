//! oriel.network on Windows. Multicast needs no lock.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub fn setMulticast(on: bool) common.MulticastError!void {
    _ = on;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "network", .ok = true, .detail = try gpa.dupe(u8, "multicast: nothing to hold") };
}

// mDNS / DNS-SD (network/mdns.zig): dnsapi's DnsService* (mdns_windows.zig).
pub const mdns_backend = @import("mdns_windows.zig").backend;

test {
    std.testing.refAllDecls(@import("mdns_windows.zig"));
}
