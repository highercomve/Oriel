//! Windows backend: not implemented yet (WASAPI loopback is the plan).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

pub fn listSources(_: std.mem.Allocator) ![]common.Source {
    return error.NotSupported;
}

pub const Stream = struct {
    pub fn open(_: ?[:0]const u8, _: [:0]const u8, _: u32) !Stream {
        return error.NotSupported;
    }
    pub fn read(_: *Stream, _: []f32) !void {
        return error.NotSupported;
    }
    pub fn close(_: *Stream) void {}
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "not implemented on Windows yet", .{}),
    };
}
