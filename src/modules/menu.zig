//! Application menu bar module facade.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("menu/common.zig");

pub const MenuItem = common.MenuItem;
pub const ActionCallback = common.ActionCallback;

const backend = switch (target.os) {
    .linux => @import("menu/linux.zig"),
    .windows => @import("menu/windows.zig"),
    .macos => @import("menu/macos.zig"),
    // No menu bar: never built there (src/core/module_table.zig).
    .android, .ios, .other => @compileError("menu is not available on " ++ target.name),
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
