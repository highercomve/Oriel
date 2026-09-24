//! System tray icon module for Oriel.
//!
//! Linux backend: StatusNotifierItem + com.canonical.dbusmenu over GDBus.
//! Windows backend: Win32 Shell_NotifyIconW + TrackPopupMenu.
//! macOS backend: not implemented yet (`Tray.create` returns error.NotSupported).

const builtin = @import("builtin");
pub const common = @import("tray/common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;
pub const Tray = impl.Tray;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("tray/linux.zig"),
    .windows => @import("tray/windows.zig"),
    .macos => @import("tray/macos.zig"),
    else => @compileError("tray is not supported on " ++ @tagName(builtin.os.tag)),
};

// Re-export Linux-specific watcher_name if on Linux
pub const watcher_name = if (@hasDecl(impl, "watcher_name")) impl.watcher_name else "";

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
