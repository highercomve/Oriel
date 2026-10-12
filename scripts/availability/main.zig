const std = @import("std");
const oriel = @import("oriel");
const unguarded = @import("fixture_options").unguarded;

const phone = oriel.target.is_android or oriel.target.is_ios;

comptime {
    // Asked for everywhere; resolved per target (src/core/module_table.zig).
    std.debug.assert(oriel.tray.available == !phone);
    std.debug.assert(oriel.menu.available == !phone);
    std.debug.assert(oriel.input.available == !phone);
    std.debug.assert(oriel.global_shortcut.available == !oriel.target.is_ios);
    std.debug.assert(oriel.fs_watch.available == !oriel.target.is_ios);
    // Off: the stand-in, with the same answer.
    std.debug.assert(!oriel.sql.available);
    std.debug.assert(std.mem.indexOf(u8, oriel.features.js, "tray: " ++ (if (phone) "false" else "true")) != null);
}

pub fn main() !void {
    if (oriel.tray.available) {
        const t = try oriel.tray.Tray.create(std.heap.page_allocator, .{ .id = "x", .title = "x", .icon = .{ .png = "" } });
        t.deinit();
    }
    if (unguarded) _ = try oriel.tray.Tray.create(std.heap.page_allocator, .{ .id = "x", .title = "x", .icon = .{ .png = "" } });
}
