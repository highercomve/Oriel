//! Media scheme facade selecting the Linux (WebKitGTK), Windows (WebView2) or
//! macOS (WKURLSchemeHandler) backend.

const builtin = @import("builtin");
pub const open = @import("media/open.zig");
pub const range = @import("media/range.zig");

pub const setRoot = impl.setRoot;
pub const clearRoot = impl.clearRoot;
pub const handle = impl.handle;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("media_scheme/linux.zig"),
    .windows => @import("media_scheme/windows.zig"),
    .macos => @import("media_scheme/macos.zig"),
    else => @compileError("media_scheme is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
