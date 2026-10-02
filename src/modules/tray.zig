//! System tray icon module for Oriel.
//!
//! Linux backend: StatusNotifierItem + com.canonical.dbusmenu over GDBus.
//! Windows backend: Win32 Shell_NotifyIconW + TrackPopupMenu.
//! macOS backend: NSStatusItem + NSMenu.
//! Android: a stub (no system tray).

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("tray/common.zig");

pub const MenuItem = common.MenuItem;
pub const Icon = common.Icon;
pub const Options = common.Options;
pub const Menu = common.Menu;
pub const Tray = impl.Tray;
pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("tray/linux.zig"),
    .windows => @import("tray/windows.zig"),
    .macos => @import("tray/macos.zig"),
    // No system tray: a stub with the same API (Tray.create fails), so the
    // same app source builds (use a notification: see docs/android.md).
    .android => @import("tray/android.zig"),
    .ios => @compileError("tray is not available on iOS: there is no system tray"),
    .other => @compileError("tray is not supported on " ++ target.name),
};

// Re-export Linux-specific watcher_name if on Linux
pub const watcher_name = if (@hasDecl(impl, "watcher_name")) impl.watcher_name else "";

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
