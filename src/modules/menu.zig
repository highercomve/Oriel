//! Application menu bar module facade.

const builtin = @import("builtin");
pub const common = @import("menu/common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

const backend = switch (builtin.os.tag) {
    .linux => @import("menu/linux.zig"),
    .windows => @import("menu/windows.zig"),
    else => @compileError("Unsupported platform for menu module"),
};

pub const set = backend.set;
pub const check = backend.check;

test {
    _ = common;
    if (builtin.os.tag == .linux) {
        _ = @import("menu/linux.zig");
    } else if (builtin.os.tag == .windows) {
        _ = @import("menu/windows.zig");
    }
}
