//! `mkdir -p` for the POSIX targets (macOS, iOS, Android).

const std = @import("std");

/// Create `path` and its missing parents, mode 0755.
pub fn makePath(gpa: std.mem.Allocator, path: []const u8) !void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    var i: usize = 1;
    while (i <= z.len) : (i += 1) {
        if (i < z.len and z[i] != '/') continue;
        const saved = z[i];
        z[i] = 0;
        defer z[i] = saved;
        const rc = std.c.mkdir(z.ptr, 0o755);
        if (rc != 0) {
            switch (std.posix.errno(rc)) {
                .EXIST => {},
                else => return error.CreateDirectoryFailed,
            }
        }
    }
}
