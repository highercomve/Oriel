//! oriel.network on Android. Not written yet: the multicast lock will be
//! one `WifiManager.MulticastLock` (OrielNetwork.kt) taken on the first
//! lock and released with the last; `info` reads ConnectivityManager.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub fn setMulticast(on: bool) common.MulticastError!void {
    _ = on;
    return error.Unsupported;
}

pub fn info(gpa: std.mem.Allocator) !common.Info {
    _ = gpa;
    return error.Unsupported;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "network", .ok = false, .detail = try gpa.dupe(u8, "not implemented yet on Android") };
}
