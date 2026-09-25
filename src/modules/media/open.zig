//! Media file opening facade selecting the Linux, Windows or macOS backend.

const builtin = @import("builtin");
pub const common = @import("common.zig");

pub const SymlinkPolicy = common.SymlinkPolicy;
pub const OpenError = common.OpenError;

pub const Root = impl.Root;
pub const Opened = impl.Opened;
pub const openRoot = impl.openRoot;
pub const closeRoot = impl.closeRoot;
pub const openInRoot = impl.openInRoot;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("open/linux.zig"),
    .windows => @import("open/windows.zig"),
    .macos => @import("open/macos.zig"),
    else => @compileError("media open is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
