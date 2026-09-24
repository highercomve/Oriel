//! App data paths and persistent settings store.
//!
//! Linux backend: XDG base directories via GLib + JSON store.
//! Windows backend: Known folders (Roaming/Local AppData) + Win32 JSON store.

const builtin = @import("builtin");
pub const common = @import("store/common.zig");

pub const configDir = impl.configDir;
pub const dataDir = impl.dataDir;
pub const cacheDir = impl.cacheDir;
pub const Store = impl.Store;
pub const check = impl.check;

pub const impl = switch (builtin.os.tag) {
    .linux => @import("store/linux.zig"),
    .windows => @import("store/windows.zig"),
    else => @compileError("store is not supported on " ++ @tagName(builtin.os.tag)),
};

test {
    const std = @import("std");
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
}
