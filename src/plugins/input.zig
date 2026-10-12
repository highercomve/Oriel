//! Synthetic keyboard input into other apps.
//!
//! Linux backend: zwp_virtual_keyboard_v1 (Wayland) + XTest (X11).
//! Windows backend: Win32 SendInput.
//! macOS backend: CGEvent (needs the Accessibility permission).
//! Phones don't let apps type into other apps: `oriel.input.available` is
//! false there.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
const common = @import("input/common.zig");

const impl = switch (target.os) {
    .linux => @import("input/linux.zig"),
    .windows => @import("input/windows.zig"),
    .macos => @import("input/macos.zig"),
    // Apps can't type into other apps: never built there
    // (src/core/module_table.zig; Android: use an input method).
    .android, .ios, .other => @compileError("input is not available on " ++ target.name),
};

pub const keyCombo = impl.keyCombo;
pub const typeText = impl.typeText;
pub const copy = impl.copy;
pub const paste = impl.paste;
pub const check = impl.check;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(impl);
}
