//! App data paths and persistent settings store.
//!
//! Linux backend: XDG base directories via GLib + JSON store.
//! Windows backend: Known folders (Roaming/Local AppData) + Win32 JSON store.
//! macOS backend: ~/Library/Application Support and Caches + libc JSON store.

const builtin = @import("builtin");
const target = @import("../core/target.zig");
pub const common = @import("store/common.zig");

pub const configDir = impl.configDir;
pub const dataDir = impl.dataDir;
pub const cacheDir = impl.cacheDir;
pub const Store = impl.Store;
pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("store/linux.zig"),
    .windows => @import("store/windows.zig"),
    .macos => @import("store/macos.zig"),
    .android => @import("store/android.zig"),
    .ios => @import("store/macos.zig"),
    .other => @compileError("store is not supported on " ++ target.name),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
