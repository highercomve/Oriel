//! Facts about the device an app shows or announces to others (a "This
//! computer" label, the name nearby devices see in a sharing app).
//!
//! `deviceName`: the name the user gave the device, as the platform shows it:
//! - Linux: /etc/machine-info PRETTY_HOSTNAME (GNOME's and KDE's "Device
//!   name"), else the host name.
//! - Windows: the computer's name (Settings > System > About).
//! - macOS: the computer name (System Settings > General > Sharing).
//! - iOS: UIDevice.name ("iPhone" since iOS 16 unless the app has the
//!   user-assigned-device-name entitlement).
//! - Android: Settings.Global "device_name" (Settings > About phone), else
//!   the Bluetooth name, else the model.

const std = @import("std");
const target = @import("target.zig");

/// The device's name, owned by the caller. Never empty: a generic name when
/// the platform has none.
pub fn deviceName(gpa: std.mem.Allocator) ![]u8 {
    const name = switch (target.os) {
        .linux => try linuxName(gpa),
        .windows => try windowsName(gpa),
        .macos => try appleName(gpa, "NSHost", "currentHost", "localizedName"),
        .ios => try appleName(gpa, "UIDevice", "currentDevice", "name"),
        .android => try androidName(gpa),
        .other => null,
    };
    if (name) |n| {
        if (std.mem.trim(u8, n, " \t\r\n").len > 0) return n;
        gpa.free(n);
    }
    return gpa.dupe(u8, "Device");
}

fn linuxName(gpa: std.mem.Allocator) !?[]u8 {
    var buf: [4096]u8 = undefined;
    if (readSmall("/etc/machine-info", &buf)) |text| {
        if (prettyHostname(text)) |v| if (v.len > 0) return try gpa.dupe(u8, v);
    }
    var host: [256]u8 = undefined;
    if (std.c.gethostname(&host, host.len) != 0) return null;
    return try gpa.dupe(u8, std.mem.sliceTo(&host, 0));
}

fn readSmall(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

/// PRETTY_HOSTNAME= from /etc/machine-info (shell-style, maybe quoted).
fn prettyHostname(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, l, "PRETTY_HOSTNAME=")) continue;
        var v = l["PRETTY_HOSTNAME=".len..];
        if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) v = v[1 .. v.len - 1];
        return v;
    }
    return null;
}

extern "kernel32" fn GetComputerNameExW(kind: c_int, buf: ?[*]u16, size: *u32) callconv(.winapi) c_int;

fn windowsName(gpa: std.mem.Allocator) !?[]u8 {
    if (target.os != .windows) return null;
    var buf: [256]u16 = undefined;
    var size: u32 = buf.len;
    // ComputerNamePhysicalDnsHostname: the name Settings shows.
    if (GetComputerNameExW(5, &buf, &size) == 0) return null;
    return try std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..size]);
}

fn appleName(gpa: std.mem.Allocator, comptime cls: [:0]const u8, comptime getter: [:0]const u8, comptime prop: [:0]const u8) !?[]u8 {
    if (target.os != .macos and target.os != .ios) return null;
    const h = if (target.os == .macos) @import("../platform/macos/cocoa.zig") else @import("../platform/ios/apple.zig");
    const pool = h.objc.AutoreleasePool.init();
    defer pool.deinit();
    const c = h.objc.getClass(cls) orelse return null;
    const obj = c.msgSend(h.Object, getter, .{});
    if (obj.value == null) return null;
    const text = h.utf8(obj.msgSend(h.Object, prop, .{})) orelse return null;
    return try gpa.dupe(u8, text);
}

fn androidName(gpa: std.mem.Allocator) !?[]u8 {
    if (target.os != .android) return null;
    const runtime = @import("../platform/android/runtime.zig");
    const ShellMod = @import("../platform/android/Shell.zig");
    const Ctx = struct {
        gpa: std.mem.Allocator,
        out: ?[]u8 = null,
        fn run(self: *@This()) void {
            const e = runtime.mainEnv() orelse return;
            const arr = runtime.call(.object, "deviceName", "()[B", .{}) orelse return;
            defer e.functions.DeleteLocalRef(e, arr);
            self.out = e.bytesAlloc(self.gpa, arr) catch null orelse null;
        }
    };
    var ctx: Ctx = .{ .gpa = gpa };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return null;
    return ctx.out;
}

test prettyHostname {
    try std.testing.expectEqualStrings("Sergio's laptop", prettyHostname("ICON_NAME=computer\nPRETTY_HOSTNAME=\"Sergio's laptop\"\n").?);
    try std.testing.expectEqualStrings("box", prettyHostname("PRETTY_HOSTNAME=box").?);
    try std.testing.expect(prettyHostname("CHASSIS=laptop\n") == null);
}

test deviceName {
    if (target.os != .linux) return;
    const n = try deviceName(std.testing.allocator);
    defer std.testing.allocator.free(n);
    try std.testing.expect(n.len > 0);
}
