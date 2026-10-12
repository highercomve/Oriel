//! Persistent settings store: small JSON files of key/value settings in
//! the app's config directory (`oriel.paths.appConfig`; on Android its
//! `<app id>` folder). Directories for the app's other files are
//! `oriel.paths`.
//!
//! Linux backend: GLib file I/O.
//! Windows backend: Win32 file I/O.
//! macOS, iOS and Android backend: libc file I/O.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const target = @import("../core/target.zig");

pub const Store = impl.Store;
pub const check = impl.check;

const impl = switch (target.os) {
    .linux => @import("store/linux.zig"),
    .windows => @import("store/windows.zig"),
    .macos => @import("store/macos.zig"),
    .android => @import("store/android.zig"),
    .ios => @import("store/macos.zig"),
    .other => @compileError("store is not supported on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(@import("store/common.zig"));
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
