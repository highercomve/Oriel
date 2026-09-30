//! Synthetic keyboard input into other apps.
//!
//! Linux backend: zwp_virtual_keyboard_v1 (Wayland) + XTest (X11).
//! Windows backend: Win32 SendInput.
//! macOS backend: CGEvent (needs the Accessibility permission).

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("input/common.zig");

pub const impl = switch (target.os) {
    .linux => @import("input/linux.zig"),
    .windows => @import("input/windows.zig"),
    .macos => @import("input/macos.zig"),
    .android => @compileError("input is not available on Android: apps cannot type into other apps (use an input method: see docs/android.md)"),
    .ios => @compileError("input is not available on iOS: apps cannot type into other apps"),
    .other => @compileError("input is not supported on " ++ target.name),
};

pub const keyCombo = impl.keyCombo;
pub const typeText = impl.typeText;
pub const copy = impl.copy;
pub const paste = impl.paste;
pub const check = impl.check;

// Linux-only public helpers re-exported on Linux
pub const xkb = if (target.is_desktop_linux) impl.xkb else void;
pub const x11 = if (target.is_desktop_linux) impl.x11 else void;
pub const EVDEV = if (target.is_desktop_linux) impl.EVDEV else void;
pub const defaultKeymap = if (target.is_desktop_linux) impl.defaultKeymap else void;
pub const xtestAvailable = if (target.is_desktop_linux) impl.xtestAvailable else void;
pub const evdevForKey = if (target.is_desktop_linux) impl.evdevForKey else void;
pub const WaylandInput = if (target.is_desktop_linux) impl.WaylandInput else void;
pub const keyComboX11 = if (target.is_desktop_linux) impl.keyComboX11 else void;
pub const typeTextX11 = if (target.is_desktop_linux) impl.typeTextX11 else void;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
