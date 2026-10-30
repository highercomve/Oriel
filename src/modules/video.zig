//! A native video player over the app's window (docs/video.md).
//!
//!     try oriel.video.play(null, .{ .url = url, .title = "Beach, 2019" });
//!     oriel.video.close();
//!
//! The player covers the whole window with its own controls (play, seek,
//! volume) and a close button; closing it (that button, Esc, Android's
//! back) shows the page again. It plays what the platform plays, not only
//! what the WebView's `<video>` accepts: MPEG-TS from camcorders
//! (.mts/.m2ts), WMV/ASF, ProRes, and on GPUs where the WebView's video is
//! slow.
//!
//! - Linux: GtkVideo on a GtkMediaFile (GStreamer), with graphics offload
//!   (GTK 4.14+). URLs: `http(s)://` (the media server's) and `file://`.
//! - Android: MediaPlayer on a SurfaceView with a MediaController
//!   (OrielVideo.kt). URLs: `http(s)://`, `file://`, `content://` and the
//!   app's media URLs (`media_scheme.base_url`), read from the media
//!   source or the root as OrielMedia serves them.
//!
//! Elsewhere (Windows, macOS, iOS) and with `-Dnative_ui`,
//! `oriel.video.available` is false.
//!
//! The page: `oriel.video.play({ url, title })` and `oriel.video.close()`;
//! the events `video:closed`, `video:ended`, `video:error` (`{ url,
//! message }`) and, on Android, `video:audio-unsupported` (it plays
//! without sound) go to every window.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const target = @import("../core/target.zig");
const App = @import("../core/App.zig");
const common = @import("video/common.zig");

pub const Options = common.Options;
pub const Error = common.Error;

/// Show the player over `window` (null: the focused window, else "main")
/// and start playing `options.url`. Returns once the player is shown; a
/// player already showing plays the new URL instead (no `video:closed`).
/// Later failures come as `video:error`, the end as `video:ended`. Any
/// thread (it waits for the main thread); a `window` pointer is only safe
/// to use as `App.getWindow` says.
pub fn play(window: ?*App.Window, options: Options) Error!void {
    return impl.play(window, options);
}

/// Stop and close the player, if one is showing (`video:closed`). Any thread.
pub fn close() void {
    impl.close();
}

const impl = switch (target.os) {
    .linux => @import("video/linux.zig"),
    .android => @import("video/android.zig"),
    else => @compileError("video is not available on " ++ target.name),
};

test {
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@import("video/page.zig"));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
