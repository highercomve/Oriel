//! System-wide global shortcuts plugin.
//!
//! Linux backend: XGrabKey (X11) + org.freedesktop.portal.GlobalShortcuts (Wayland).
//! Windows backend: Win32 RegisterHotKey + WM_HOTKEY message routing.
//! macOS backend: Carbon RegisterEventHotKey (no permission needed).
//! Android backend: in-app shortcuts (the app's focused window, a hardware
//! keyboard), listed in the system's Meta+/ helper: Android has no
//! system-wide hotkeys.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("global_shortcut/common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

pub const impl = switch (target.os) {
    .linux => @import("global_shortcut/linux.zig"),
    .windows => @import("global_shortcut/windows.zig"),
    .macos => @import("global_shortcut/macos.zig"),
    .android => @import("global_shortcut/android.zig"),
    .ios => @compileError("global_shortcut is not available on iOS: apps get no system-wide hotkeys"),
    .other => @compileError("global_shortcut is not supported on " ++ target.name),
};

pub const register = impl.register;
pub const unregister = impl.unregister;
pub const trigger = impl.trigger;
pub const deinit = impl.deinit;
pub const check = impl.check;

// Linux-only public helpers re-exported on Linux
pub const x11 = if (target.is_desktop_linux) impl.x11 else void;
pub const keysymFor = if (target.is_desktop_linux) impl.keysymFor else void;
pub const triggerToPortal = if (target.is_desktop_linux) impl.triggerToPortal else void;
pub const handlePath = if (target.is_desktop_linux) impl.handlePath else void;
pub const buildBindShortcutsParams = if (target.is_desktop_linux) impl.buildBindShortcutsParams else void;
pub const portalVersion = if (target.is_desktop_linux) impl.portalVersion else void;
pub const createSession = if (target.is_desktop_linux) impl.createSession else void;
pub const x11Available = if (target.is_desktop_linux) impl.x11Available else void;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
