//! Linux: nothing is gated at the OS level for a native (non-Flatpak) app.
//! The microphone (PulseAudio/PipeWire), input and notifications just work;
//! the camera, screen capture and location go through XDG portals, which ask
//! the user at the moment of use, so their status is `prompt`.

const common = @import("common.zig");

pub fn status(kind: common.Kind) common.Status {
    return switch (kind) {
        .microphone, .accessibility, .notifications, .system_audio => .granted,
        .camera, .screen_capture, .location => .prompt,
    };
}

/// Nothing to ask ahead of time: the result is the current status.
pub fn request(kind: common.Kind, done: *const fn (common.Kind, common.Status) void) void {
    done(kind, status(kind));
}

/// No standard settings page across desktops.
pub fn openSettings(kind: common.Kind) bool {
    _ = kind;
    return false;
}
