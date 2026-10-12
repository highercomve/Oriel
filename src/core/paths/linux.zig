//! oriel.paths on desktop Linux: the XDG base directories (through GLib,
//! which reads `$XDG_*_HOME` and falls back to the spec's defaults).

const std = @import("std");
const glib = @import("glib");
const Kind = @import("kind.zig").Kind;

/// `<XDG base for kind>/<name>`, created if missing. Caller frees.
pub fn appDir(gpa: std.mem.Allocator, kind: Kind, name: []const u8) ![]const u8 {
    const base = std.mem.span(switch (kind) {
        .data, .external => glib.getUserDataDir(),
        .cache => glib.getUserCacheDir(),
        .config => glib.getUserConfigDir(),
    });
    const path = try std.fs.path.join(gpa, &.{ base, name });
    errdefer gpa.free(path);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    if (glib.mkdirWithParents(path_z, 0o755) != 0) return error.CreateDirectoryFailed;
    return path;
}
