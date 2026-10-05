//! oriel.network on macOS and iOS. Multicast needs no lock: the local
//! network prompt (and on iOS the multicast entitlement) are the gates.
//! `info` (nw_path_monitor and getifaddrs) isn't written yet.

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
