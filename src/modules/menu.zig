//! Application menu bar module facade.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("menu/common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

const backend = switch (target.os) {
    .linux => @import("menu/linux.zig"),
    .windows => @import("menu/windows.zig"),
    .macos => @import("menu/macos.zig"),
    .android => @compileError("menu is not available on Android: apps have no menu bar (see docs/android.md)"),
    .ios => @compileError("menu is not available on iOS: apps have no menu bar"),
    .other => @compileError("Unsupported platform for menu module"),
};

pub const set = backend.set;
pub const check = backend.check;

test {
    _ = common;
    if (target.is_desktop_linux) {
        _ = @import("menu/linux.zig");
    } else if (builtin.os.tag == .windows) {
        _ = @import("menu/windows.zig");
    } else if (builtin.os.tag == .macos) {
        _ = @import("menu/macos.zig");
    }
}
