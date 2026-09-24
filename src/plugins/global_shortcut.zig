//! System-wide global shortcuts plugin.
//!
//! Linux backend: XGrabKey (X11) + org.freedesktop.portal.GlobalShortcuts (Wayland).
//! Windows backend: Win32 RegisterHotKey + WM_HOTKEY message routing.

const builtin = @import("builtin");
pub const common = @import("global_shortcut/common.zig");

pub const Modifiers = common.Modifiers;
pub const Shortcut = common.Shortcut;
pub const ParsedTrigger = common.ParsedTrigger;
pub const Callback = common.Callback;
pub const parseTrigger = common.parseTrigger;
pub const vkFor = common.vkFor;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("global_shortcut/linux.zig"),
    .windows => @import("global_shortcut/windows.zig"),
    else => @compileError("global_shortcut is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const register = impl.register;
pub const unregister = impl.unregister;
pub const trigger = impl.trigger;
pub const deinit = impl.deinit;
pub const check = impl.check;

// Linux-only public helpers re-exported on Linux
pub const x11 = if (builtin.os.tag == .linux) impl.x11 else void;
pub const keysymFor = if (builtin.os.tag == .linux) impl.keysymFor else void;
pub const triggerToPortal = if (builtin.os.tag == .linux) impl.triggerToPortal else void;
pub const handlePath = if (builtin.os.tag == .linux) impl.handlePath else void;
pub const buildBindShortcutsParams = if (builtin.os.tag == .linux) impl.buildBindShortcutsParams else void;
pub const portalVersion = if (builtin.os.tag == .linux) impl.portalVersion else void;
pub const createSession = if (builtin.os.tag == .linux) impl.createSession else void;
pub const x11Available = if (builtin.os.tag == .linux) impl.x11Available else void;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
