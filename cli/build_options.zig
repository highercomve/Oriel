//! Zig build options forwarded by the mobile CLI commands.
const std = @import("std");

pub fn isOption(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-D") and arg.len > 2;
}

fn name(arg: []const u8) []const u8 {
    return arg[0 .. std.mem.indexOfScalar(u8, arg, '=') orelse arg.len];
}

/// Explicit options replace defaults with the same name. Keep each user's
/// argument intact, including bare booleans, false values and paths with spaces.
pub fn append(gpa: std.mem.Allocator, argv: *std.ArrayList([]const u8), defaults: []const []const u8, forwarded: []const []const u8) !void {
    for (defaults) |arg| {
        const overridden = isOption(arg) and for (forwarded) |option| {
            if (std.mem.eql(u8, name(arg), name(option))) break true;
        } else false;
        if (!overridden) try argv.append(gpa, arg);
    }
    try argv.appendSlice(gpa, forwarded);
}

test "forward build options and replace defaults" {
    const gpa = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try append(gpa, &argv, &.{ "android-dev", "-Dtarget=aarch64-linux-android", "-Doptimize=ReleaseSafe" }, &.{ "-Dnative_ui", "-Dnative_dom=false", "-Doptimize=ReleaseFast", "-Dmodel_path=/tmp/my models" });
    const expected = [_][]const u8{ "android-dev", "-Dtarget=aarch64-linux-android", "-Dnative_ui", "-Dnative_dom=false", "-Doptimize=ReleaseFast", "-Dmodel_path=/tmp/my models" };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (expected, argv.items) |want, got| try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(!isOption("-D"));
    try std.testing.expect(!isOption("--apk"));
}
