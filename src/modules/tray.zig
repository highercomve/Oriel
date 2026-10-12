//! System tray icon module for Oriel.
//!
//! Linux backend: StatusNotifierItem + com.canonical.dbusmenu over GDBus.
//! Windows backend: Win32 Shell_NotifyIconW + TrackPopupMenu.
//! macOS backend: NSStatusItem + NSMenu.
//! Phones have no system tray: `oriel.tray.available` is false there.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
const common = @import("tray/common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;
pub const Tray = impl.Tray;
pub const check = impl.check;

const impl = switch (target.os) {
    .linux => @import("tray/linux.zig"),
    .windows => @import("tray/windows.zig"),
    .macos => @import("tray/macos.zig"),
    // No system tray: never built there (src/core/module_table.zig).
    .android, .ios, .other => @compileError("tray is not available on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
