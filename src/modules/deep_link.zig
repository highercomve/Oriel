//! Deep link URL scheme handling module for Oriel.
//!
//! Enables applications to register custom URL schemes (e.g. `myapp://...`)
//! and receive incoming links both at cold start and while running.
//!
//! Linux backend: GApplication command-line handling + XDG MIME handler.
//! Windows backend: Named mutex single-instance + WM_COPYDATA message forwarding.
//! macOS backend: Launch Services `kAEGetURL` Apple Events; schemes declared in Info.plist.

const builtin = @import("builtin");
pub const common = @import("deep_link/common.zig");

pub const queue = @import("deep_link/queue.zig");
pub const Queue = queue.Queue;

pub const validateUrl = common.validateUrl;
pub const validate = common.validateUrl;
pub const ValidationError = common.ValidationError;
pub const max_url_len = common.max_url_len;

pub const onOpen = impl.onOpen;
pub const current = impl.current;
pub const setColdStartUrl = impl.setColdStartUrl;
pub const deliver = impl.deliver;
pub const setDeclaredSchemes = impl.setDeclaredSchemes;
pub const setReady = impl.setReady;
pub const isReady = impl.isReady;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("deep_link/linux.zig"),
    .windows => @import("deep_link/windows.zig"),
    .macos => @import("deep_link/macos.zig"),
    else => @compileError("deep_link is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(queue);
}
