//! System-wide global shortcuts plugin.
//!
//! Linux backend: XGrabKey (X11) + org.freedesktop.portal.GlobalShortcuts (Wayland).
//! Windows backend: Win32 RegisterHotKey + WM_HOTKEY message routing.
//! macOS backend: Carbon RegisterEventHotKey (no permission needed).
//! Android backend: in-app shortcuts (the app's focused window, a hardware
//! keyboard), listed in the system's Meta+/ helper: Android has no
//! system-wide hotkeys.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
const common = @import("global_shortcut/common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;

const impl = switch (target.os) {
    .linux => @import("global_shortcut/linux.zig"),
    .windows => @import("global_shortcut/windows.zig"),
    .macos => @import("global_shortcut/macos.zig"),
    .android => @import("global_shortcut/android.zig"),
    // No hotkeys of any kind: never built there (src/core/module_table.zig).
    .ios, .other => @compileError("global_shortcut is not available on " ++ target.name),
};

pub const register = impl.register;
pub const unregister = impl.unregister;
pub const trigger = impl.trigger;
pub const deinit = impl.deinit;
pub const check = impl.check;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
