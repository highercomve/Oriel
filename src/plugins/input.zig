//! Synthetic keyboard input into other apps.
//!
//! Linux backend: zwp_virtual_keyboard_v1 (Wayland) + XTest (X11).
//! Windows backend: Win32 SendInput.
//! macOS backend: CGEvent (needs the Accessibility permission).

const builtin = @import("builtin");
pub const common = @import("input/common.zig");

pub const impl = switch (builtin.os.tag) {
    .linux => @import("input/linux.zig"),
    .windows => @import("input/windows.zig"),
    .macos => @import("input/macos.zig"),
    else => @compileError("input is not supported on " ++ @tagName(builtin.os.tag)),
};

pub const keyCombo = impl.keyCombo;
pub const typeText = impl.typeText;
pub const copy = impl.copy;
pub const paste = impl.paste;
pub const check = impl.check;

// Linux-only public helpers re-exported on Linux
pub const xkb = if (builtin.os.tag == .linux) impl.xkb else void;
pub const x11 = if (builtin.os.tag == .linux) impl.x11 else void;
pub const EVDEV = if (builtin.os.tag == .linux) impl.EVDEV else void;
pub const defaultKeymap = if (builtin.os.tag == .linux) impl.defaultKeymap else void;
pub const xtestAvailable = if (builtin.os.tag == .linux) impl.xtestAvailable else void;
pub const evdevForKey = if (builtin.os.tag == .linux) impl.evdevForKey else void;
pub const WaylandInput = if (builtin.os.tag == .linux) impl.WaylandInput else void;
pub const keyComboX11 = if (builtin.os.tag == .linux) impl.keyComboX11 else void;
pub const typeTextX11 = if (builtin.os.tag == .linux) impl.typeTextX11 else void;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
