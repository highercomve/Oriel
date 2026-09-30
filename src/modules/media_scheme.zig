//! Media scheme facade selecting the Linux (WebKitGTK), Windows (WebView2) or
//! macOS (WKURLSchemeHandler) backend.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const open = @import("media/open.zig");
pub const range = @import("media/range.zig");

pub const setRoot = impl.setRoot;
pub const clearRoot = impl.clearRoot;
pub const handle = impl.handle;

pub const impl = switch (target.os) {
    .linux => @import("media_scheme/linux.zig"),
    .windows => @import("media_scheme/windows.zig"),
    .macos => @import("media_scheme/macos.zig"),
    .android => @compileError("media_scheme is not available on Android: the media server is not ported yet (see docs/android.md)"),
    .ios => @compileError("media_scheme is not available on iOS: the media server is not ported yet (see docs/ios.md)"),
    .other => @compileError("media_scheme is not supported on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
