//! Media file opening facade selecting the Linux, Windows or macOS backend.

const builtin = @import("builtin");
const target = @import("../../core/target.zig");
pub const common = @import("common.zig");

pub const SymlinkPolicy = common.SymlinkPolicy;
pub const OpenError = common.OpenError;

pub const Root = impl.Root;
pub const Opened = impl.Opened;
pub const openRoot = impl.openRoot;
pub const closeRoot = impl.closeRoot;
pub const openInRoot = impl.openInRoot;

pub const impl = switch (target.os) {
    .linux => @import("open/linux.zig"),
    .windows => @import("open/windows.zig"),
    .macos => @import("open/macos.zig"),
    .android => @compileError("media open is not available on Android: the media server is not ported yet (see docs/android.md)"),
    .ios => @compileError("media open is not available on iOS: the media server is not ported yet (see docs/ios.md)"),
    .other => @compileError("media open is not supported on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
