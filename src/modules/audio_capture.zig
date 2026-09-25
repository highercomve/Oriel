//! Audio capture: microphones and system audio ("monitor" sources), as mono
//! float samples at a fixed rate (16 kHz for whisper).
//!
//! Linux backend: libpulse (works on PipeWire through pipewire-pulse); the
//! sound server resamples and downmixes. Windows backend: WASAPI shared mode,
//! system audio through loopback on each output device; downmixed and
//! resampled here. macOS backend: CoreAudio + AudioQueue (system audio through
//! a loopback device such as BlackHole).

const builtin = @import("builtin");
pub const common = @import("audio_capture/common.zig");

pub const Source = common.Source;
pub const Stream = impl.Stream;
pub const listSources = impl.listSources;
pub const freeSources = common.freeSources;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("audio_capture/linux.zig"),
    .windows => @import("audio_capture/windows.zig"),
    .macos => @import("audio_capture/macos.zig"),
    else => @compileError("audio_capture is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
