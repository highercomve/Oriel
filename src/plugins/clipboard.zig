//! System clipboard: text and PNG images.
//!
//! Linux backend: GdkClipboard on the main thread + Wayland ext-data-control on workers.
//! Windows backend: Win32 OpenClipboard/CF_UNICODETEXT/CF_DIB/PNG via main thread.
//! macOS and iOS backend: NSPasteboard (text, PNG/TIFF) / UIPasteboard via main thread.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
const std = @import("std");

const common = @import("clipboard/common.zig");

pub const TextCallback = impl.TextCallback;
pub const ImageCallback = impl.ImageCallback;

pub const readTextAsync = impl.readTextAsync;
pub const readImageAsync = impl.readImageAsync;
pub const readText = impl.readText;
pub const readImage = impl.readImage;
pub const writeText = impl.writeText;
pub const writeImage = impl.writeImage;
pub const check = impl.check;

const impl = switch (target.os) {
    .linux => @import("clipboard/linux.zig"),
    .windows => @import("clipboard/windows.zig"),
    .macos, .ios => @import("clipboard/apple.zig"),
    .android => @import("clipboard/android.zig"),
    .other => @compileError("clipboard is not supported on " ++ target.name),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
    _ = common;
}
