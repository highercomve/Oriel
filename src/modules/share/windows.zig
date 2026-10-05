//! oriel.share on Windows. Not written yet: receiving through Send To
//! and "Open with" (a Share Target needs package identity: MSIX), sending
//! through DataTransferManager.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub fn send(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    _ = .{ item, anchor, done };
    return error.Unsupported;
}

pub fn capabilities() common.Capabilities {
    return .{};
}

pub fn open(handle: u32) common.OpenError!std.Io.File {
    _ = handle;
    return error.Unsupported;
}

pub fn release(id: u32) void {
    _ = id;
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "share", .ok = true, .detail = try gpa.dupe(u8, "receive and send: not implemented yet") };
}
