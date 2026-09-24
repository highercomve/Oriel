//! System clipboard: text and PNG images.
//!
//! Linux backend: GdkClipboard on the main thread + Wayland ext-data-control on workers.
//! Windows backend: Win32 OpenClipboard/CF_UNICODETEXT/CF_DIB/PNG via main thread.

const builtin = @import("builtin");
const std = @import("std");

pub const common = @import("clipboard/common.zig");

pub const TextCallback = impl.TextCallback;
pub const ImageCallback = impl.ImageCallback;

pub const readTextAsync = impl.readTextAsync;
pub const readImageAsync = impl.readImageAsync;
pub const readText = impl.readText;
pub const readImage = impl.readImage;
pub const writeText = impl.writeText;
pub const writeImage = impl.writeImage;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("clipboard/linux.zig"),
    .windows => @import("clipboard/windows.zig"),
    else => @compileError("clipboard is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
    _ = common;
}
