//! Photos from the camera or the photo library (docs/modules.md, "Camera").
//!
//!     const photo = try oriel.camera.capturePhoto(io, arena, .{
//!         .source = .camera, // or .library
//!         .max_side = 1600,
//!         .format = .jpeg,
//!         .quality = 85,
//!     });
//!     // photo.bytes, photo.width, photo.height, photo.mime
//!
//! On when the app declares `.permissions.camera` (or with `-Dcamera`).
//! Pages get the same as `oriel.camera.capturePhoto({ source, maxSide })`
//! (a data URL), and on Android `<input type="file" accept="image/*"
//! [capture]>` opens the camera or the system photo picker (the template's
//! OrielCamera.kt; WKWebView does this itself on iOS).
//!
//! Backends: Android, the camera app (`ACTION_IMAGE_CAPTURE` into Oriel's
//! capture provider) and the system photo picker, scaled and encoded in
//! Kotlin; iOS, UIImagePickerController (camera) and PHPickerViewController
//! (library); the desktop, the file dialog and zigimg (`.camera` is
//! error.Unsupported there, as on the iOS simulator).
//!
//! `capturePhoto` waits for the user: call it from an async command (on
//! phones it returns error.MainThread on the UI thread).

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const target = @import("../core/target.zig");
const oriel = @import("../oriel.zig");
pub const common = @import("camera/common.zig");

pub const Source = common.Source;
pub const Format = common.Format;
pub const Options = common.Options;
pub const Photo = common.Photo;
pub const Error = common.Error;
/// The largest encoded photo `capturePhoto` returns.
pub const max_bytes = common.max_bytes;

/// Take a photo (`.camera`) or pick one (`.library`), scaled to fit
/// `max_side` and encoded as `format`. `bytes` and `mime` are allocated in
/// `arena`. Blocks until the user is done: not on the main thread.
pub fn capturePhoto(io: std.Io, arena: std.mem.Allocator, options: Options) Error!Photo {
    try common.validate(options);
    const photo = try impl.capturePhoto(io, arena, options);
    if (photo.bytes.len > max_bytes) return error.TooLarge;
    return photo;
}

pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    return impl.check(gpa, ctx);
}

pub const impl = switch (target.os) {
    .linux, .windows, .macos => @import("camera/desktop.zig"),
    .android => @import("camera/android.zig"),
    .ios => @import("camera/ios.zig"),
    .other => @compileError("camera is not supported on " ++ target.name),
};

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@import("camera/page.zig"));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
