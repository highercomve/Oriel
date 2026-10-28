//! Media scheme facade selecting the Linux (WebKitGTK), Windows (WebView2),
//! macOS (WKURLSchemeHandler) or Android (the WebView's request
//! interception, OrielMedia.kt) backend. `base_url`: where the page loads the
//! root's files (`app://app/media/` on desktop, the app's https origin on
//! Android).
//!
//! `setSource` serves bytes from the app's own code instead of a root, on
//! Android only (`error.Unsupported` elsewhere): desktop apps give the
//! source to `media_server.Server` (`Options.source`), whose http URL plays
//! in `<video>` everywhere.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const open = @import("media/open.zig");
pub const range = @import("media/range.zig");
/// Bytes the app serves itself (`setSource`).
pub const Source = @import("media/source.zig").Source;

pub const setRoot = impl.setRoot;
pub const clearRoot = impl.clearRoot;
/// Serve `source` at `<base_url><path>`, replacing the root while it's set.
/// Android only: elsewhere `error.Unsupported` (use `media_server` with
/// `Options.source`).
pub const setSource = if (@hasDecl(impl, "setSource")) impl.setSource else unsupported.setSource;
/// Stop serving the source: back to the root, or 404 if there is none.
pub const clearSource = if (@hasDecl(impl, "clearSource")) impl.clearSource else unsupported.clearSource;
pub const handle = if (@hasDecl(impl, "handle")) impl.handle else {};
pub const base_url: []const u8 = if (@hasDecl(impl, "base_url")) impl.base_url else "app://app/media/";

pub const impl = switch (target.os) {
    // -Dnative_ui draws pages without a WebView: there is no URI scheme to
    // serve, and WebKitGTK isn't linked (the HTTP media server still works).
    .linux => if (@import("build_options").native_ui) no_webview else @import("media_scheme/linux.zig"),
    .windows => @import("media_scheme/windows.zig"),
    .macos => @import("media_scheme/macos.zig"),
    .android => @import("media_scheme/android.zig"),
    .ios => @compileError("media_scheme is not available on iOS: the media server is not ported yet (see docs/ios.md)"),
    .other => @compileError("media_scheme is not supported on " ++ target.name),
};

/// Desktop backends: a source is served by `media_server`, not the scheme.
const unsupported = struct {
    pub fn setSource(_: Source) error{Unsupported}!void {
        return error.Unsupported;
    }
    pub fn clearSource() void {}
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
    _ = @import("media/source.zig");
}

test "media_scheme: setSource without a WebView path" {
    if (@hasDecl(impl, "setSource")) return error.SkipZigTest;
    const std = @import("std");
    var mem: @import("media/source.zig").TestMemory = .{ .data = "" };
    try std.testing.expectError(error.Unsupported, setSource(mem.source()));
    clearSource();
}
