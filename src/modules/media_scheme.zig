//! Media scheme facade selecting Linux (WebKitGTK) or Windows (WebView2) backend.

const builtin = @import("builtin");
pub const open = @import("media/open.zig");
pub const range = @import("media/range.zig");

pub const setRoot = impl.setRoot;
pub const clearRoot = impl.clearRoot;
pub const handle = impl.handle;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("media_scheme/linux.zig"),
    .windows => @import("media_scheme/windows.zig"),
    else => @compileError("media_scheme is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
