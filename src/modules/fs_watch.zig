//! File-system watching: Linux (inotify), Windows (ReadDirectoryChangesW),
//! macOS (FSEvents).

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const builtin = @import("builtin");
const target = @import("../core/target.zig");
const std = @import("std");

pub const common = @import("fs_watch/common.zig");

pub const buffer_align = impl.buffer_align;
pub const Event = common.Event;
pub const Watcher = impl.Watcher;
pub const check = impl.check;

pub const impl = switch (target.os) {
    .linux => @import("fs_watch/linux.zig"),
    .windows => @import("fs_watch/windows.zig"),
    .macos => @import("fs_watch/macos.zig"),
    .android => @import("fs_watch/linux.zig"),
    // Not ported yet: never built there (src/core/module_table.zig).
    .ios, .other => @compileError("fs_watch is not available on " ++ target.name),
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(impl);
    _ = common;
}
