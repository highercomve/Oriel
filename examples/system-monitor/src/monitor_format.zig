//! The original web frontend formatters, shared by the Zig views/graphs.
const std = @import("std");
const builtin = @import("builtin");
pub fn bytes(buffer: []u8, amount: f64) ![]const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value = if (std.math.isFinite(amount)) @max(0, amount) else 0;
    var unit: usize = 0;
    while (value >= 1024 and unit < units.len - 1) : (unit += 1) value /= 1024;
    return if (value >= 10 or unit == 0) std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ @round(value), units[unit] }) else std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] });
}
pub fn rate(buffer: []u8, value: f64) ![]const u8 {
    var scratch: [40]u8 = undefined;
    return std.fmt.bufPrint(buffer, "{s}/s", .{try bytes(&scratch, value)});
}
pub fn uptime(buffer: []u8, seconds: u64) ![]const u8 {
    if (seconds >= 86400) return std.fmt.bufPrint(buffer, "{d}d {d}h {d}m", .{ seconds / 86400, seconds / 3600 % 24, seconds / 60 % 60 });
    if (seconds >= 3600) return std.fmt.bufPrint(buffer, "{d}h {d}m", .{ seconds / 3600, seconds / 60 % 60 });
    return std.fmt.bufPrint(buffer, "{d}m", .{seconds / 60});
}
extern "c" fn localtime_r(*const std.c.time_t, *anyopaque) ?*anyopaque;
extern "c" fn _localtime64_s(*anyopaque, *const i64) c_int;
extern "c" fn strftime([*]u8, usize, [*:0]const u8, *const anyopaque) usize;
pub fn clock(buffer: []u8, seconds: i64, pattern: [:0]const u8) []const u8 {
    var tm: [16]i64 = undefined;
    if (builtin.os.tag == .windows) {
        if (_localtime64_s(&tm, &seconds) != 0) return "--";
    } else {
        const time: std.c.time_t = @intCast(seconds);
        if (localtime_r(&time, &tm) == null) return "--";
    }
    const len = strftime(buffer.ptr, buffer.len, pattern.ptr, &tm);
    return if (len > 0) buffer[0..len] else "--";
}
test "formatting matches the original frontend units and precision" {
    var b: [40]u8 = undefined;
    try std.testing.expectEqualStrings("1.5 KB", try bytes(&b, 1536));
    try std.testing.expectEqualStrings("12 GB", try bytes(&b, 12 * 1073741824));
    try std.testing.expectEqualStrings("0 B/s", try rate(&b, 0));
    try std.testing.expectEqualStrings("3d 2h 1m", try uptime(&b, 3 * 86400 + 2 * 3600 + 60));
}
