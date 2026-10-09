//! Media scheme facade selecting the Linux (WebKitGTK), Windows (WebView2) or
//! macOS (WKURLSchemeHandler) backend.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const open = @import("media/open.zig");
pub const range = @import("media/range.zig");

pub const setRoot = impl.setRoot;
pub const clearRoot = impl.clearRoot;
pub const handle = if (@hasDecl(impl, "handle")) impl.handle else {};

pub const impl = switch (target.os) {
    // -Dnative_ui draws pages without a WebView: there is no URI scheme to
    // serve, and WebKitGTK isn't linked (the HTTP media server still works).
    .linux => if (@import("build_options").native_ui) no_webview else @import("media_scheme/linux.zig"),
    .windows => @import("media_scheme/windows.zig"),
    .macos => @import("media_scheme/macos.zig"),
    .android => @compileError("media_scheme is not available on Android: the media server is not ported yet (see docs/android.md)"),
    .ios => @compileError("media_scheme is not available on iOS: the media server is not ported yet (see docs/ios.md)"),
    .other => @compileError("media_scheme is not supported on " ++ target.name),
};

const no_webview = struct {
    pub fn setRoot(_: []const u8, _: open.SymlinkPolicy) !void {
        return error.NoWebView;
    }
    pub fn clearRoot() void {}
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
